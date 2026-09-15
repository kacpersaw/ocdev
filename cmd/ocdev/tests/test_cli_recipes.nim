## Black-box CLI tests; only the compiled fixture is on PATH.
import std/[os, json, strutils, unittest]
import test_support

disableParamFiltering()
doAssert paramCount() == 2, "Usage: test_cli_recipes <ocdev binary> <fake Incus binary>"
let binary = absolutePath(paramStr(1))
let fakeBinary = absolutePath(paramStr(2))

type Fixture = ref object
  sandbox: Sandbox
  state, recipe: string
  definition: JsonNode

proc persist(f: Fixture) = writeJson(f.recipe, f.definition)

proc newFixture(): Fixture =
  let s = newSandbox("ocdev-cli-", fakeBinary)
  result = Fixture(sandbox: s, state: s.home / "backend.json", recipe: s.home / "recipe.json")
  s.env["PATH"] = s.home
  s.env["FAKE_ROOT"] = s.home
  copyFile(fakeBinary, s.home / "groups")
  setFilePermissions(s.home / "groups", {fpUserRead, fpUserWrite, fpUserExec})
  writeJson(result.state, %*{"ocdev-base": {"name": "ocdev-base", "status": "Running",
    "config": {"volatile.uuid": "base-uuid"}, "expanded_devices": {
      "ssh-proxy": {"type": "proxy", "listen": "tcp:0.0.0.0:2200", "connect": "tcp:127.0.0.1:22"}}}})
  result.definition = %*{"schemaVersion": 1, "id": "demo", "name": "Demo",
    "source": {"snapshot": "base/ready"},
    "tasks": {"test": {"kind": "command", "cwd": "/home/dev", "command": "check", "args": []}},
    "hooks": {"afterCreate": ["test"], "beforeDelete": ["test"]}}
  result.persist()

proc cli(f: Fixture; args: seq[string]; ok = true; jsonMode = true): JsonNode =
  let r = f.sandbox.run(binary, args & (if jsonMode: @["--json"] else: @[]))
  checkpoint("CLI " & $args & ": " & r.error)
  check (r.code == 0) == ok
  if not ok:
    check r.output == ""
    check "private-sentinel" notin r.error
    return if jsonMode: parseJson(r.error) else: %r.error
  check r.error == ""
  return if jsonMode: parseJson(r.output) else: %r.output

proc create(f: Fixture; name = "demo"): JsonNode =
  f.cli(@["create", name, "--recipe", f.recipe])

suite "Compiled CLI recipes":
  setup:
    let f = newFixture()
    let s = f.sandbox
  teardown:
    s.close()

  test "full recipe CLI JSON and legacy routes":
    discard f.cli(@["recipe", "validate", f.recipe])
    discard f.cli(@["recipe", "add", f.recipe])
    check f.cli(@["recipe", "list"]).len == 1
    discard f.cli(@["recipe", "show", "demo"])
    let row = f.create()
    check row["setupStatus"].getStr == "complete"
    check row.hasKey("operationId")
    check f.cli(@["inspect", "demo"])["identityMatches"].getBool
    check f.cli(@["task", "list", "demo"]).len == 1
    let task = f.cli(@["task", "run", "demo", "test"])
    check "task-output" in f.cli(@["runs", "logs", task["operationId"].getStr])["logs"].getStr
    discard f.cli(@["runs", "show", task["operationId"].getStr])
    discard f.cli(@["setup", "demo", "--rerun"])
    discard f.cli(@["bind", "demo", "3000:8080"])
    check f.cli(@["bindings"])[0]["host_port"].getInt == 8080
    discard f.cli(@["bind", "demo", "--list"])
    discard f.cli(@["unbind", "demo", "8080"])
    discard f.cli(@["stop", "demo"])
    discard f.cli(@["start", "demo"])
    check f.cli(@["ssh", "demo"])["ssh_port"].kind == JInt
    discard f.cli(@["ports"])
    discard f.cli(@["doctor"])
    discard f.cli(@["delete", "demo", "--dry-run"])
    discard f.cli(@["delete", "demo"])
    check not readJson(f.state).hasKey("ocdev-demo")
    check readJson(f.state).hasKey("ocdev-base")
    check f.cli(@["runs", "list", "demo"]).len > 2

  test "dry run has no local side effects":
    discard f.cli(@["create", "demo", "--recipe", f.recipe, "--dry-run"])
    check not pathExists(s.home / ".ocdev")
    for line in readFile(s.home / "calls").splitLines():
      if line.len > 0:
        check parseJson(line)[0].getStr in ["list", "query"]

  test "failure has operation ID and named delete runs hooks":
    f.definition["tasks"]["test"]["command"] = %"FAIL"
    f.persist()
    let error = f.cli(@["create", "demo", "--recipe", f.recipe], ok = false)
    let runId = error["error"]["operationId"].getStr
    check f.cli(@["runs", "show", runId])["status"].getStr == "failed"
    for spelling in [@["--name", "demo"], @["-n", "demo"], @["--name=demo"], @["-n=demo"]]:
      discard f.cli(@["delete"] & spelling, ok = false, jsonMode = false)
      check readJson(f.state).hasKey("ocdev-demo")
    for command in ["del", "dEL", "de-lete"]:
      discard f.cli(@[command, "demo"], ok = false, jsonMode = false)
      check readJson(f.state).hasKey("ocdev-demo")

  test "failed clone can be retried and reservation released":
    s.env["FAIL_COPY"] = "1"
    discard f.cli(@["create", "demo", "--recipe", f.recipe], ok = false)
    check not pathExists(s.home / ".ocdev/environments/demo.json")
    check "demo:" notin readFile(s.home / ".ocdev/ports")
    s.env.del("FAIL_COPY")
    discard f.create()

  test "concurrent plain clones have unique reserved blocks":
    var children: seq[Child]
    for name in ["one", "two"]:
      children.add(s.start(binary, @["create", name, "--from", "base/ready", "--json"]))
    var rows: seq[JsonNode]
    for child in children:
      let r = child.finish()
      checkpoint(r.error)
      check r.code == 0
      rows.add(parseJson(r.output))
    check rows[0]["ssh_port"] != rows[1]["ssh_port"]
    let allocations = readFile(s.home / ".ocdev/ports")
    var allocationLines = allocations.splitLines()
    # Count allocation records, not the delimiter's trailing empty element.
    if allocations.endsWith("\n"): allocationLines.setLen(allocationLines.len - 1)
    check allocationLines.len == 2
    for row in rows:
      check row["ssh_port"].getInt != 2200

  test "legacy hook failure is nonzero and keeps container":
    let script = s.home / "script with spaces.sh"
    writeFile(script, "exit 7")
    s.env["FAIL_HOOK"] = "1"
    discard f.cli(@["create", "demo", "--from", "base/ready", "--post-create", script], ok = false)
    check readJson(f.state).hasKey("ocdev-demo")
    check "demo:" in readFile(s.home / ".ocdev/ports")

  test "unknown options invalid inputs and shell rejected":
    for args in [@["recipe", "list", "--surprise", "yes"],
                 @["create", "demo", "--recipe", f.recipe, "--from", "base/ready"],
                 @["shell", "demo"], @["services", "logs", "demo", "api", "--tail", "1001"],
                 @["delete", "../not-a-name"]]:
      discard f.cli(args, ok = false)
    check not pathExists(s.home / ".ocdev")

  test "backend outage after create keeps port reservation":
    s.env["FAIL_FINAL_INFO"] = "1"
    let row = f.cli(@["create", "demo", "--from", "base/ready"])
    check row["ssh_port"].getInt > 0
    check "demo:" in readFile(s.home / ".ocdev/ports")

  test "missing UUID and empty allocations are valid":
    let data = readJson(f.state)
    data["ocdev-base"]["config"] = newJObject()
    writeJson(f.state, data)
    check f.cli(@["inspect", "base"])["uuid"].kind == JNull
    check f.cli(@["ssh", "base"])["ssh_port"].kind == JNull
    discard f.cli(@["delete", "base", "--dry-run"])
    createDir(s.home / ".ocdev")
    writeFile(s.home / ".ocdev/ports", "")
    check f.cli(@["ports"]) == newJArray()
    check f.cli(@["doctor"])["ok"].getBool

  test "human and JSON mutations honor recipe lock":
    discard f.create()
    let fd = acquireLock(s.home / ".ocdev/environments/demo.lock")
    try:
      for jsonMode in [false, true]:
        for command in ["stop", "sto", "sTO", "s-top"]:
          discard f.cli(@[command, "--name", "demo"], ok = false, jsonMode = jsonMode)
        discard f.cli(@["bind", "demo", "8080"], ok = false, jsonMode = jsonMode)
        discard f.cli(@["--", "sto", "--name", "demo"], ok = false, jsonMode = jsonMode)
        discard f.cli(@["--help=false", "stop", "demo"], ok = false, jsonMode = jsonMode)
    finally:
      releaseLock(fd)
    check readJson(f.state)["ocdev-demo"]["status"].getStr == "Running"

  test "empty JSON reads do not initialize":
    check f.cli(@["recipe", "list"]) == newJArray()
    check f.cli(@["runs", "list", "demo"]) == newJArray()
    check not pathExists(s.home / ".ocdev")
