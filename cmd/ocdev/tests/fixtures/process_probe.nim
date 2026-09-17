## Synthetic subprocess for testing capture/timeout support itself.
import std/[os, json, strutils]
let args = commandLineParams()
case args[0]
of "streams":
  stdout.write(repeat('o', 131072))
  stderr.write(repeat('e', 131072))
  quit(7)
of "environment":
  echo $(%*{"home": getEnv("HOME"), "value": getEnv("PROBE_VALUE"),
            "argument": args[1], "stdin": stdin.readAll()})
of "sleep": sleep(10000)
else: quit(99)
