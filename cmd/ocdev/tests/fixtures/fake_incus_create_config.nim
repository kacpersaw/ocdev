## No daemon or containers: the only successful provider calls are read-only.
import std/[os, json]

if getAppFilename().extractFilename == "groups":
  echo "incus-admin"
  quit(0)

let calls = getEnv("CALLS")
doAssert calls.len > 0
let args = commandLineParams()
let log = open(calls, fmAppend)
log.writeLine($(%args))
log.close()
if args.len > 0 and args[0] == "list":
  # Port allocation now checks the provider before reserving a block.
  echo "[]"
  quit(0)
if args == @["profile", "show", "ocdev"]:
  quit(0)
# All source/destination info and launches deliberately fail, as upstream did.
# Include a sentinel to check that JSON errors do not expose provider output.
stderr.writeLine("private-backend-sentinel")
quit(1)
