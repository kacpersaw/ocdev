## Port of the upstream create-config checks, with human/JSON route parity.
## Only compiled fixtures are on PATH; launch always fails without a container.
import std/[os, json, strutils, unittest, posix]
import test_support

disableParamFiltering()
doAssert paramCount() == 2, "Usage: test_create_config <ocdev binary> <fake Incus binary>"
let binary = absolutePath(paramStr(1))
let fakeBinary = absolutePath(paramStr(2))
let settings = %*{"base_image": "images:ubuntu/26.04", "default_base_source": "my-base/stable"}

type Fixture = ref object
  sandbox: Sandbox
  config, calls: string

proc newFixture(): Fixture =
  let s = newSandbox("ocdev-create-config-", fakeBinary)
  s.env["PATH"] = s.home
  s.env["TMPDIR"] = s.home
  copyFile(fakeBinary, s.home / "groups")
  setFilePermissions(s.home / "groups", {fpUserRead, fpUserWrite, fpUserExec})
  result = Fixture(sandbox: s, config: s.home / ".ocdev/config.json", calls: s.home / "calls")
  s.env["CALLS"] = result.calls

proc configure(f: Fixture; value: JsonNode) =
  if pathExists(f.config): removeFile(f.config)
  if not value.isNil:
    createDir(f.config.parentDir)
    writeFile(f.config, if value.kind == JString: value.getStr else: $value)

proc invoke(f: Fixture; jsonMode: bool; args: seq[string] = @[];
            configError = false): seq[seq[string]] =
  if pathExists(f.calls): removeFile(f.calls)
  let r = f.sandbox.run(binary, @["create", "--name=check"] & args &
    (if jsonMode: @["--json"] else: @[]), timeoutMs = 10000)
  checkpoint("create " & $args & " json=" & $jsonMode & " stderr: " & r.error)
  check r.code != 0 # every successful selection reaches a deliberately failed backend
  if jsonMode:
    check r.output == ""
    check "private-backend-sentinel" notin r.error
    check f.sandbox.home notin r.error
    check "config.json" notin r.error
    let error = parseJson(r.error)
    check error.kind == JObject
    check error.len == 1
    check error.hasKey("error")
    check error["error"]["code"].getStr == "recipe.create.failed"
    check error["error"]["operationId"].getStr.len > 0
    check error["error"]["message"].getStr ==
      "Command failed. Validate inputs and inspect operation history for recorded failures."
    for key, _ in error["error"]:
      check key in ["code", "message", "operationId"]
  elif configError:
    check "config.json" in r.error
  if fileExists(f.calls):
    for line in readFile(f.calls).splitLines():
      if line.len > 0:
        let call = parseJson(line).to(seq[string])
        require call.len > 0
        check call[0] in ["list", "info", "profile", "launch"]
        result.add(call)

proc withoutList(calls: seq[seq[string]]): seq[seq[string]] =
  # Permit the allocator's new read-only probes, not extra mutations.
  for call in calls:
    if call[0] != "list": result.add(call)

proc checkLaunch(calls: seq[seq[string]]; image: string) =
  var launches: seq[seq[string]]
  for call in calls:
    if call[0] == "launch": launches.add(call)
  check launches == @[@["launch", image, "ocdev-check", "--profile", "default", "--profile", "ocdev"]]

suite "Create config with compiled fake Incus":
  setup:
    let f = newFixture()
  teardown:
    f.sandbox.close()

  test "global source defaults clone on human and JSON routes":
    for jsonMode in [false, true]:
      f.configure(settings)
      check withoutList(f.invoke(jsonMode)) == @[@["info", "ocdev-my-base"]]

  test "both explicit source flags override global defaults":
    for jsonMode in [false, true]:
      for flag in ["--from", "--from-snapshot"]:
        f.configure(settings)
        check withoutList(f.invoke(jsonMode, @[flag, "explicit-base/point"])) ==
          @[@["info", "ocdev-explicit-base"]]

  test "fresh bare and explicit true select the configured image":
    for jsonMode in [false, true]:
      for flag in ["--fresh", "--fresh=true"]:
        f.configure(settings)
        checkLaunch(f.invoke(jsonMode, @[flag]), "images:ubuntu/26.04")

  test "explicit fresh false retains global and explicit clone precedence":
    for jsonMode in [false, true]:
      f.configure(settings)
      check withoutList(f.invoke(jsonMode, @["--fresh=false"])) == @[@["info", "ocdev-my-base"]]
      for flag in ["--from", "--from-snapshot"]:
        check withoutList(f.invoke(jsonMode, @["--fresh=false", flag, "explicit-base/point"])) ==
          @[@["info", "ocdev-explicit-base"]]

  test "missing and empty config defaults select the original image":
    for jsonMode in [false, true]:
      for value in [JsonNode(nil), newJObject(), %*{"default_base_source": ""}]:
        f.configure(value)
        checkLaunch(f.invoke(jsonMode), "images:ubuntu/25.10")

  test "shell-looking image is one literal argument and cannot inject":
    let marker = f.sandbox.home / "injected"
    let image = "images:ubuntu/26.04; : > " & marker
    for jsonMode in [false, true]:
      f.configure(%*{"base_image": image})
      checkLaunch(f.invoke(jsonMode), image)
      check not pathExists(marker)

  test "malformed or invalid config fails before Incus with route-specific errors":
    for jsonMode in [false, true]:
      for invalid in ["not json", "[]", "{\"base_image\":42}", "{\"base_image\":\"--help\"}"]:
        f.configure(%invalid)
        check f.invoke(jsonMode, configError = true).len == 0

  test "invalid default source and conflicting flags never contact Incus":
    for jsonMode in [false, true]:
      f.configure(%*{"default_base_source": "bad/source/extra"})
      check f.invoke(jsonMode).len == 0
      f.configure(settings)
      for flag in ["--from", "--from-snapshot"]:
        for fresh in ["--fresh", "--fresh=true"]:
          check f.invoke(jsonMode, @[fresh, flag, "explicit-base/point"]).len == 0
      check f.invoke(jsonMode, @["--from", "base/one", "--from-snapshot", "base/two"]).len == 0

  test "FIFO config is rejected promptly without contacting Incus":
    for jsonMode in [false, true]:
      f.configure(nil)
      createDir(f.config.parentDir)
      require mkfifo(f.config.cstring, Mode(0o600)) == 0
      try:
        check f.invoke(jsonMode, configError = true).len == 0
        check not pathExists(f.calls)
      finally:
        doAssert unlink(f.config.cstring) == 0
