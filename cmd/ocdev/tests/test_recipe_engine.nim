## Integration tests against the compiled engine and isolated fake Incus.
import std/[unittest, os, json, strutils, strtabs, sequtils]
import test_support

disableParamFiltering()
let binaries = commandLineParams()
if binaries.len != 2:
  quit("usage: test_recipe_engine HARNESS FAKE_INCUS", 2)
let harness = absolutePath(binaries[0])
let fake = absolutePath(binaries[1])

proc task(command: string): JsonNode =
  %*{"kind": "command", "cwd": "/home/dev", "command": command, "args": []}

proc call(s: Sandbox, args: seq[string], ok = true): JsonNode =
  let resultRun = s.run(harness, args)
  check resultRun.code == (if ok: 0 else: 1)
  if ok:
    check resultRun.error == ""
    return parseJson(resultRun.output)
  check resultRun.output == ""
  check "SECRET_SENTINEL" notin resultRun.error
  return %resultRun.error

proc trace(s: Sandbox): seq[JsonNode] =
  for line in readFile(s.home / "trace").splitLines():
    if line.len > 0: result.add(parseJson(line))

proc create(s: Sandbox): JsonNode =
  s.call(@["create", s.home / "recipe.json", "false"])

proc project(s: Sandbox, mode = "0600"): string =
  result = s.home / "project.json"
  writeJson(result, %*{"schemaVersion": 1, "id": "fixture", "recipePath": s.home / "recipe.json",
    "seedFiles": [{"id": "config", "source": "seed", "destination": "/home/dev/config",
      "mode": mode, "required": true}]})

proc seedTemps(s: Sandbox): seq[string] =
  for path in walkPattern(s.home / "guest" / ".ocdev-seed-*"): result.add(path)

proc entries(path: string): seq[string] =
  for kind, child in walkDir(path): result.add(child)

suite "recipe engine integration":
  setup:
    let s = newSandbox("ocdev-engine-test-", fake)
    s.env["FAKE_STATE"] = s.home / "state"
    s.env["FAKE_TRACE"] = s.home / "trace"
    for key in ["BAD_LIST", "MISSING_SNAPSHOT", "DRIVER", "EXEC_SEEDS", "BAD_SERVICES"]:
      s.env.del(key)
    writeFile(s.home / "state", "[]")
    var recipe = %*{"schemaVersion": 1, "id": "generic", "name": "Generic",
      "source": {"snapshot": "base/ready"},
      "tasks": {"prepare": task("prepare"), "check": task("check")},
      "hooks": {"afterCreate": ["prepare", "check"], "beforeDelete": ["check"]}}
    let path = s.home / "recipe.json"
    writeJson(path, recipe)
  teardown:
    s.close()

  test "dry run queries without writes and storage rejection":
    check s.call(@["create", path, "true"])["dryRun"].getBool
    check not pathExists(s.home / ".ocdev")
    check s.trace().anyIt(%"/1.0/instances/ocdev-base/snapshots/ready" in it["args"].elems)
    s.env["DRIVER"] = "dir"
    discard s.call(@["create", path, "true"], false)
    check not pathExists(s.home / ".ocdev")

  test "order pinning private state and explicit rerun":
    let created = s.create()
    check created["setupStatus"].getStr == "complete"
    check created["servicesReady"].getStr == "unknown"
    var commands: seq[string]
    for event in s.trace():
      if event["args"][0].getStr == "exec": commands.add(event["args"].elems[^1].getStr)
    check commands == @["prepare", "check"]
    recipe["tasks"]["check"]["command"] = %"FAIL"
    writeJson(path, recipe)
    discard s.call(@["task", "check", "{}"])
    discard s.call(@["setup", "false", "false"], false)
    discard s.call(@["setup", "false", "true"])
    for file in walkDirRec(s.home / ".ocdev"):
      if file.endsWith(".json"):
        check getFilePermissions(file) == {fpUserRead, fpUserWrite}
    check "SECRET_SENTINEL" notin $s.call(@["runs"])

  test "typed inputs stdin and secret non disclosure":
    recipe["tasks"]["check"]["inputs"] = %*{
      "key": {"type": "string", "secret": true},
      "options": {"type": "stringList", "choices": ["one", "two"]}}
    writeJson(path, recipe)
    discard s.create()
    let value = "SECRET_SENTINEL; $(touch " & s.home / "not-executed" & ")"
    discard s.call(@["task", "check", $(%*{"key": value, "options": ["one"]})])
    let execution = s.trace().filterIt(it["args"][0].getStr == "exec")[^1]
    check parseJson(execution["input"].getStr)["key"].getStr == value
    check value notin $execution["args"]
    check not pathExists(s.home / "not-executed")
    discard s.call(@["task", "check", "{\"key\":17}"], false)
    discard s.call(@["task", "check", "{\"options\":[\"invalid\"]}"], false)
    check "SECRET_SENTINEL" notin $s.call(@["runs"])

  test "failed hook is recorded and retained":
    recipe["tasks"]["check"]["command"] = %"FAIL"
    writeJson(path, recipe)
    let error = parseJson(s.call(@["create", path, "false"], false).getStr)
    let operation = s.call(@["show", error["operationId"].getStr])
    check operation["status"].getStr == "failed"
    check operation["steps"].elems[^1]["exitCode"].getInt == 7
    check s.call(@["inspect"])["setupStatus"].getStr == "failed"
    discard s.call(@["delete", "false"], false)
    check readJson(s.home / "state").len > 0

  test "seed preflight delivery and reread":
    let projectPath = s.project()
    discard s.call(@["project", projectPath, "false"], false)
    check readFile(s.home / "state") == "[]"
    writeFile(s.home / "seed", "dummy-first")
    discard s.call(@["project", projectPath, "false"])
    writeFile(s.home / "seed", "dummy-second")
    discard s.call(@["setup", "false", "true"])
    let deliveries = s.trace().filterIt(%"ocdev-seed" in it["args"].elems)
    check deliveries.mapIt(it["input"].getStr) == @["dummy-first", "dummy-second"]
    let pinned = readFile(s.home / ".ocdev/environments/demo.json")
    check "dummy-first" notin pinned
    check "dummy-second" notin pinned

  test "uuid mismatch and malformed backend fail closed":
    discard s.create()
    var state = readJson(s.home / "state")
    state[0]["config"]["volatile.uuid"] = %"replacement"
    writeJson(s.home / "state", state)
    check not s.call(@["inspect"])["identityMatches"].getBool
    discard s.call(@["task", "check", "{}"], false)
    discard s.call(@["delete", "false"], false)
    s.env["BAD_LIST"] = "1"
    discard s.call(@["inspect"], false)

  test "services projection logs and delete preview":
    recipe["processCompose"] = %*{"cwd": "/home/dev", "file": "process-compose.yaml",
      "services": ["api"], "autostart": true}
    writeJson(path, recipe)
    discard s.create()
    check s.call(@["services", "list", ""]) == %*[{"name": "api", "status": "Running", "ready": "unknown"}]
    let logs = s.call(@["services", "logs", "api"])
    check logs["truncated"].getBool
    check "SECRET_SENTINEL" notin logs["logs"].getStr
    s.env["BAD_SERVICES"] = "1"
    discard s.call(@["services", "list", ""], false)
    check s.call(@["delete", "true"])["ownedResources"] == %*["ocdev-demo"]
    discard s.call(@["delete", "false"])
    check readJson(s.home / "state") == newJArray()
    check not pathExists(s.home / ".ocdev/environments/demo.json")

  test "bounded host timeout and cross process lock":
    check s.call(@["timeout"])["exitCode"].getInt == 124
    discard s.create()
    let fd = acquireLock(s.home / ".ocdev/environments/demo.lock")
    try:
      check "already running" in s.call(@["task", "check", "{}"], false).getStr
    finally: releaseLock(fd)
    discard s.call(@["task", "check", "{}"])

  test "missing instance reconciles metadata without hooks":
    discard s.create()
    writeFile(s.home / "state", "[]")
    let before = s.trace().len
    check s.call(@["delete", "true"])["metadataOnly"].getBool
    check s.call(@["delete", "false"])["metadataOnly"].getBool
    check not pathExists(s.home / ".ocdev/environments/demo.json")
    check not s.trace()[before .. ^1].anyIt(it["args"][0].getStr == "exec")
    discard s.create()

  test "unrelated large fleet does not break target":
    var items = newJArray()
    for i in 0 ..< 20:
      items.add(%*{"name": "unrelated-" & $i, "status": "Running", "config": {"extra": repeat('x', 4096)}})
    writeJson(s.home / "state", items)
    discard s.call(@["create", path, "true"])
    check not pathExists(s.home / ".ocdev")

  test "unsatisfiable hooks rejected before clone":
    recipe["tasks"]["check"]["inputs"] = %*{"key": {"type": "string", "required": true, "secret": true}}
    writeJson(path, recipe)
    discard s.call(@["create", path, "true"], false)
    check not pathExists(s.home / ".ocdev")
    discard s.call(@["create", path, "false"], false)
    check readJson(s.home / "state") == newJArray()

  test "readonly seeds are atomic and rerunnable":
    s.env["EXEC_SEEDS"] = "1"
    writeFile(s.home / "seed", "first")
    let projectPath = s.project("0400")
    discard s.call(@["project", projectPath, "false"])
    let destination = s.home / "guest/config"
    check readFile(destination) == "first"
    check getFilePermissions(destination) == {fpUserRead}
    writeFile(s.home / "seed", "second")
    discard s.call(@["setup", "false", "true"])
    check readFile(destination) == "second"
    writeFile(s.home / "cat", "#!/bin/sh\nexit 1\n")
    setFilePermissions(s.home / "cat", {fpUserRead, fpUserWrite, fpUserExec})
    discard s.call(@["setup", "false", "true"], false)
    check readFile(destination) == "second"
    check s.seedTemps().len == 0

  test "seed directory rejected and symlink replaced":
    s.env["EXEC_SEEDS"] = "1"
    writeFile(s.home / "seed", "replacement")
    let projectPath = s.project()
    let destination = s.home / "guest/config"
    createDir(destination)
    discard s.call(@["project", projectPath, "false"], false)
    check dirExists(destination)
    check entries(destination).len == 0
    check s.seedTemps().len == 0
    removeDir(destination)
    let target = s.home / "other-directory"
    createDir(target)
    createSymlink(target, destination)
    discard s.call(@["setup", "false", "true"])
    check not symlinkExists(destination)
    check readFile(destination) == "replacement"
    check entries(target).len == 0

  test "stale operation is inspectable as interrupted":
    let created = s.create()
    let operationPath = s.home / ".ocdev/runs" / (created["operationId"].getStr & ".json")
    var operation = readJson(operationPath)
    operation["status"] = %"running"
    operation["steps"].elems[^1]["status"] = %"running"
    writeJson(operationPath, operation)
    let shown = s.call(@["show", created["operationId"].getStr])
    check shown["status"].getStr == "interrupted"
    check shown["steps"].elems[^1]["status"].getStr == "interrupted"
