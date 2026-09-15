## Compiled fake backend for the list JSON contract tests. No live fallback.
import std/[os, json, strutils]

let root = getEnv("FAKE_ROOT")
if root.len == 0: quit("FAKE_ROOT is required", 99)
if extractFilename(getAppFilename()) == "groups":
  let path = root / "groups-output"
  echo (if fileExists(path): readFile(path) else: "incus-admin")
  quit(0)

let args = commandLineParams()
var log = open(root / "calls", fmAppend)
log.writeLine($(%args))
log.close()
if args notin [@["list", "--format=json", "ocdev-"],
                @["list", "--format=csv", "-c", "n,s", "ocdev-"]]:
  quit("Unexpected Incus command", 99)
stdout.write(readFile(root / "response"))
stderr.write(readFile(root / "stderr"))
quit(parseInt(readFile(root / "exit")))
