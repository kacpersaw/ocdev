import std/[os, json, unittest, strutils, posix]
import test_support

disableParamFiltering()
if paramCount() != 1: quit("Usage: test-process-support <built process probe>", 2)
let probe = absolutePath(paramStr(1))

suite "isolated subprocess support":
  setup:
    let s = newSandbox("ocdev-process-")
  teardown:
    close(s)

  test "absence checks reject files directories and dangling symlinks":
    let path = s.home / "entry"
    check not pathExists(path)
    writeFile(path, "synthetic")
    check pathExists(path)
    removeFile(path)
    createDir(path)
    check pathExists(path)
    removeDir(path)
    createSymlink(s.home / "missing", path)
    check pathExists(path)

  test "large streams remain separate and preserve exit status":
    let r = run(s, probe, @["streams"])
    check r.code == 7
    check r.output == repeat('o', 131072)
    check r.error == repeat('e', 131072)

  test "private environment literal arguments and noninteractive stdin":
    s.env["PROBE_VALUE"] = "synthetic value"
    let arg = "space ; $(not-executed)"
    let r = run(s, probe, @["environment", arg])
    check r.code == 0
    check r.error == ""
    check parseJson(r.output) == %*{"home": s.home, "value": "synthetic value",
                                    "argument": arg, "stdin": ""}

  test "outer timeout raises rather than passing a negative CLI assertion":
    expect TestProcessTimeout:
      discard run(s, probe, @["sleep"], timeoutMs = 50)
    var status: cint
    check waitpid(Pid(-1), status, WNOHANG) == Pid(-1)
    check errno == ECHILD

  test "closing a sandbox kills and reaps unfinished commands":
    discard start(s, probe, @["sleep"])
    close(s)
    check not dirExists(s.home)
    var status: cint
    check waitpid(Pid(-1), status, WNOHANG) == Pid(-1)
    check errno == ECHILD
