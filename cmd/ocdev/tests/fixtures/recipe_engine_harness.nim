import std/[os, json]
import recipe_engine, recipe_exec
proc clone(name, snapshot: string): int =
  writeFile(getEnv("FAKE_STATE"), $(%*[{"name": "ocdev-" & name,
    "status": "Running", "config": {"volatile.uuid": "fixture-uuid"}}]))
  0
proc remove(name: string): int =
  writeFile(getEnv("FAKE_STATE"), "[]")
  0
try:
  let a = commandLineParams()
  var r: JsonNode
  case a[0]
  of "timeout":
    let e = execute(@["incus", "exec", "SLEEP"], timeoutMs = 50)
    r = %*{"exitCode": e.code}
  of "create": r = createEnvironment("demo", a[1], "", a[2] == "true", clone)
  of "project": r = createEnvironment("demo", "", a[1], a[2] == "true", clone)
  of "setup": r = setupEnvironment("demo", a[1] == "true", a[2] == "true")
  of "inspect": r = inspectEnvironment("demo")
  of "tasks": r = taskList("demo")
  of "task": r = taskRun("demo", a[1], parseJson(a[2]))
  of "runs": r = runsList("demo")
  of "show": r = runShow(a[1])
  of "services": r = services("demo", a[1], a[2], 5)
  of "delete": r = deleteEnvironment("demo", a[1] == "true", remove)
  else: quit(3)
  echo $r
except EngineError as e:
  stderr.writeLine($( %*{"code": e.code, "operationId": e.operationId, "error": e.msg}))
  quit(1)
except CatchableError as e:
  stderr.writeLine(e.msg)
  quit(1)
