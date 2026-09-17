## Compiled, isolated Incus fixture for the CLI recipe suite.
import std/[os, json, strutils, posix]

proc flock(fd, operation: cint): cint {.importc, header: "<sys/file.h>".}

proc main() =
  if getAppFilename().extractFilename == "groups":
    echo "incus-admin"
    return
  let root = getEnv("FAKE_ROOT")
  doAssert root.len > 0
  let a = commandLineParams()
  proc barrier(marker, release: string) =
    writeFile(root / marker, "ready")
    for attempt in 0 ..< 2000:
      if fileExists(root / release): return
      sleep(5)
    quit("Fixture barrier deadline exceeded", 98)
  # Pause before taking the backend lock so other CLI processes can query state.
  if a[0] == "copy" and getEnv("WAIT_COPY") == "1":
    barrier("copy-waiting", "copy-release")
  if a[0] == "list" and getEnv("WAIT_ABSENCE") == "1" and fileExists(root / "cleanup-deleted"):
    barrier("cleanup-waiting", "cleanup-release")
  let fd = posix.open((root / "backend.lock").cstring, O_WRONLY or O_CREAT, Mode(0o600))
  doAssert fd >= 0
  defer: discard posix.close(fd)
  doAssert flock(fd, 2) == 0
  var state = parseJson(readFile(root / "backend.json"))
  let log = open(root / "calls", fmAppend)
  log.writeLine($(%a))
  log.close()
  template save() = writeFile(root / "backend.json", $state)
  case a[0]
  of "list":
    if getEnv("BAD_METADATA").len > 0:
      echo "private-sentinel"
      quit(1)
    if getEnv("SWITCH_REBIND_OWNER") == "1" and a == @["list", "--format=json"]:
      let counter = root / "owner-queries"
      let count = (if fileExists(counter): parseInt(readFile(counter)) else: 0) + 1
      writeFile(counter, $count)
      if count == 2:
        state["ocdev-base"]["expanded_devices"]["dyn-8080"] = state["ocdev-demo"]["expanded_devices"]["dyn-8080"]
        state["ocdev-demo"]["expanded_devices"].delete("dyn-8080")
        save()
    if "csv" in a:
      for name, _ in state: echo name
    else:
      var rows = newJArray()
      for _, item in state: rows.add(item)
      echo rows
  of "info":
    if not state.hasKey(a[1]): quit(1)
    if getEnv("FAIL_FINAL_INFO").len > 0 and a[1] != "ocdev-base" and
        state[a[1]]["status"].getStr == "Running": quit(1)
    echo "Status: " & state[a[1]]["status"].getStr.toUpperAscii
  of "snapshot":
    doAssert a[1] == "list"
    echo "ready,fixture"
  of "query":
    if "/snapshots/" in a[1]:
      echo %*{"name": "ready", "config": {"volatile.uuid": "base-uuid"}}
    elif "/storage-pools/" in a[1]: echo %*{"driver": "btrfs"}
    else: echo %*{"expanded_devices": {"root": {"pool": "fixture"}}}
  of "copy":
    if getEnv("FAIL_COPY").len > 0:
      echo "private-sentinel"
      quit(1)
    if state.hasKey(a[2]): quit(1)
    sleep(30)
    var item = state[a[1].split('/')[0]].copy()
    item["name"] = %a[2]
    item["status"] = %"Stopped"
    item["config"] = %*{"volatile.uuid": a[2] & "-uuid"}
    state[a[2]] = item
    save()
    echo "private-sentinel"
    stderr.writeLine("private-sentinel")
  of "start", "stop":
    if a[0] == "start" and getEnv("FAIL_START") == "1": quit(7)
    state[a[1]]["status"] = %(if a[0] == "start": "Running" else: "Stopped")
    save()
  of "delete":
    state.delete(a[^1]) # Supports both delete NAME and delete --force NAME.
    save()
    if getEnv("WAIT_ABSENCE") == "1": writeFile(root / "cleanup-deleted", "ready")
  of "config":
    if a[1] == "unset": return
    doAssert a[1] == "device"
    let devices = state[a[3]]["expanded_devices"]
    case a[2]
    of "list":
      for name, _ in devices: echo name
    of "get":
      if devices.hasKey(a[4]) and devices[a[4]].hasKey(a[5]): echo devices[a[4]][a[5]].getStr
      else: echo ""
    of "remove":
      devices.delete(a[4])
      save()
    of "add":
      let device = %*{"type": a[5]}
      for arg in a[6 .. ^1]:
        let pair = arg.split('=', 1)
        device[pair[0]] = %pair[1]
      devices[a[4]] = device
      save()
    else: quit(99)
  of "exec":
    discard stdin.readAll()
    if "FAIL" in a or (getEnv("FAIL_HOOK").len > 0 and "su" in a):
      echo "private-sentinel"
      quit(7)
    if "process-compose" in a and "list" in a:
      echo %*[{"name": "api", "status": "Running", "command": "private-sentinel"}]
    else: echo "task-output"
  of "file": doAssert a[1] == "push"
  of "export": writeFile(a[2], "dummy archive")
  of "import":
    state[a[2]] = %*{"name": a[2], "status": "Stopped",
      "config": {"volatile.uuid": a[2] & "-uuid"}, "expanded_devices": {}}
    save()
  of "profile": doAssert a[1] == "show"
  else:
    stderr.writeLine("Unexpected fake Incus call")
    quit(99)

main()
