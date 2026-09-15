## Isolated Incus protocol fixture. Never invokes a real Incus executable.
import std/[os, json, strutils, osproc, streams]

let args = commandLineParams()
if args.len == 0: quit(9)
let data = if args[0] == "exec": stdin.readAll() else: ""
let trace = open(getEnv("FAKE_TRACE"), fmAppend)
trace.writeLine($(%*{"args": args, "input": data}))
trace.close()
case args[0]
of "list":
  if getEnv("BAD_LIST") != "": echo "invalid"
  else:
    let items = parseJson(readFile(getEnv("FAKE_STATE")))
    var selected = newJArray()
    for item in items:
      if args.len <= 2 or item["name"].getStr == args[2].strip(chars = {'^', '$'}):
        selected.add(item)
    echo selected
of "query":
  if getEnv("MISSING_SNAPSHOT") != "": quit(1)
  if "/snapshots/" in args[1]:
    echo $(%*{"name": "ready", "config": {"volatile.uuid": "base-uuid"}})
  elif "/storage-pools/" in args[1]:
    echo $(%*{"driver": getEnv("DRIVER", "btrfs")})
  else:
    echo $(%*{"expanded_devices": {"root": {"pool": "fixture"}}})
of "exec":
  if "SLEEP" in args: sleep(10000)
  if "FAIL" in args:
    echo "SECRET_SENTINEL"
    quit(7)
  if "ocdev-seed" in args and getEnv("EXEC_SEEDS") != "":
    let guest = getEnv("HOME") / "guest"
    createDir(guest)
    let script = args[args.find("-c") + 1]
    let mode = args[args.find("ocdev-seed") + 2]
    let child = startProcess("/bin/sh", args = @["-c", script, "ocdev-seed", guest, mode, guest / "config"], options = {})
    child.inputStream.write(data)
    child.inputStream.close()
    stdout.write(child.outputStream.readAll())
    stderr.write(child.errorStream.readAll())
    let code = child.waitForExit()
    child.close()
    quit(code)
  if "process-compose" in args:
    if "list" in args:
      echo (if getEnv("BAD_SERVICES") != "": "bad" else: "[{\"name\":\"api\",\"status\":\"Running\",\"command\":\"PRIVATE\"}]")
    elif "logs" in args:
      echo "line\npassword=SECRET_SENTINEL\n" & repeat('x', 70000)
  else: echo "SECRET_SENTINEL"
else: quit(9)
