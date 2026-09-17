## Black-box JSON listing contracts. Only the supplied compiled fake is on PATH.
import std/[os, json, unittest, strutils, algorithm]
import test_support

# Binary arguments are fixture inputs, not unittest name filters.
disableParamFiltering()
let args = commandLineParams()
if args.len != 2:
  quit("Usage: test-list-json <built ocdev binary> <built fake Incus>", 2)
let binary = absolutePath(args[0])
let fake = absolutePath(args[1])

proc responseRaw(s: Sandbox; data: string; code = 0; error = "") =
  writeFile(s.home / "response", data)
  writeFile(s.home / "exit", $code)
  writeFile(s.home / "stderr", error)

proc response(s: Sandbox; data: JsonNode; code = 0; error = "") =
  responseRaw(s, $data, code, error)

proc runList(s: Sandbox; args: seq[string] = @[]): RunResult =
  run(s, binary, @["list"] & args, timeoutMs = 10000)

proc assertFailure(r: RunResult) =
  check r.code != 0
  check r.output == ""
  check r.error.len > 0
  check "private-sentinel" notin r.error

proc calls(s: Sandbox): seq[JsonNode] =
  for line in readFile(s.home / "calls").splitLines():
    if line.len > 0: result.add(parseJson(line))

suite "list JSON with compiled fake Incus":
  setup:
    let s = newSandbox("ocdev-list-", fake)
    s.env["FAKE_ROOT"] = s.home
    s.env["PATH"] = s.home
    copyFile(s.home / "incus", s.home / "groups")
    setFilePermissions(s.home / "groups", {fpUserRead, fpUserWrite, fpUserExec})
    response(s, newJArray())
  teardown:
    close(s)

  test "projection and prefix and ports":
    let state = s.home / ".ocdev"
    createDir(state)
    let ports = state / "ports"
    writeFile(ports, "demo-ocdev-copy:2210\nstopped:2220\n")
    let before = readFile(ports)
    response(s, %*[
      {"name": "ocdev-demo-ocdev-copy", "status": "Running",
       "config": {"volatile.uuid": "dummy-uuid", "user.private": "private-sentinel"},
       "expanded_config": {"user.private": "private-sentinel"}},
      {"name": "ocdev-stopped", "status": "Stopped", "config": {}},
      {"name": "other-ocdev-demo", "status": "Running"}])
    let r = runList(s, @["--json"])
    checkpoint r.error
    check r.code == 0
    check r.error == ""
    check parseJson(r.output) == %*[
      {"name": "demo-ocdev-copy", "instance": "ocdev-demo-ocdev-copy",
       "status": "Running", "uuid": "dummy-uuid", "ssh_port": 2210},
      {"name": "stopped", "instance": "ocdev-stopped", "status": "Stopped",
       "uuid": nil, "ssh_port": 2220}]
    check readFile(ports) == before
    var children: seq[string]
    for kind, path in walkDir(state): children.add(extractFilename(path))
    children.sort()
    check children == @["ports"]
    check calls(s) == @[%*["list", "--format=json", "ocdev-"]]

  test "missing UUID and allocation never initialize state":
    for config in [newJNull(), newJObject(), %*{"volatile.uuid": ""},
                   %*{"volatile.uuid": nil}]:
      response(s, %*[{"name": "ocdev-demo", "status": "Frozen", "config": config}])
      let r = runList(s, @["--json"])
      checkpoint r.error
      check r.code == 0
      check parseJson(r.output) == %*[{"name": "demo", "instance": "ocdev-demo",
        "status": "Frozen", "uuid": nil, "ssh_port": nil}]
      check not pathExists(s.home / ".ocdev")
    response(s, %*[{"name": "ocdev-demo", "status": "Running"}])
    check parseJson(runList(s, @["--json"]).output)[0]["uuid"].kind == JNull

  test "unavailable allocations are null":
    let state = s.home / ".ocdev"
    createDir(state)
    response(s, %*[{"name": "ocdev-demo", "status": "Running"}])
    for allocation in ["other:2200\n", "demo:invalid\n", "demo:0\n", "demo:-1\n"]:
      writeFile(state / "ports", allocation)
      let r = runList(s, @["--json"])
      checkpoint r.error
      check r.code == 0
      check parseJson(r.output)[0]["ssh_port"].kind == JNull

  test "empty success":
    let r = runList(s, @["--json"])
    checkpoint r.error
    check r.code == 0
    check r.output == "[]\n"
    check r.error == ""
    check not pathExists(s.home / ".ocdev")

  test "nonmatching instances are empty":
    response(s, %*[{"name": "unrelated", "status": "Running"}])
    check runList(s, @["--json"]).output == "[]\n"

  test "query failure is not empty success":
    for output in ["[]", "No container found"]:
      responseRaw(s, output, code = 1, error = "query failed private-sentinel\n")
      assertFailure(runList(s, @["--json"]))

  test "warning does not corrupt JSON":
    response(s, newJArray(), error = "warning from Incus\n")
    let r = runList(s, @["--json"])
    checkpoint r.error
    check r.code == 0
    check r.output == "[]\n"
    check r.error == ""

  test "malformed metadata never emits partial JSON":
    for bad in ["", "not json private-sentinel", "{}", "null", "[42]",
      $(%*[{"name": "ocdev-good", "status": "Running"}, {"name": "ocdev-bad", "status": 12}]),
      $(%*[{"status": "Running"}]),
      $(%*[{"name": "ocdev-demo", "status": "Running", "config": []}]),
      $(%*[{"name": "ocdev-demo", "status": "Running", "config": {"volatile.uuid": 12}}])]:
      responseRaw(s, bad)
      assertFailure(runList(s, @["--json"]))

  test "prerequisite failures":
    writeFile(s.home / "groups-output", "users")
    assertFailure(runList(s, @["--json"]))
    check not pathExists(s.home / "calls")
    removeFile(s.home / "incus")
    assertFailure(runList(s, @["--json"]))
    check not pathExists(s.home / ".ocdev")

  test "default table unchanged":
    responseRaw(s, "ocdev-demo,RUNNING\n")
    let r = runList(s)
    checkpoint r.error
    check r.code == 0
    check r.error == ""
    check r.output == "NAME".alignLeft(20) & " " & "STATUS".alignLeft(10) & " SSH PORT\n" &
      "demo".alignLeft(20) & " " & "RUNNING".alignLeft(10) & " N/A\n"
    check calls(s) == @[%*["list", "--format=csv", "-c", "n,s", "ocdev-"]]
