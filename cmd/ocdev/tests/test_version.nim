## Exercise the real Make rules and config constant in disposable repositories.
## No Atlas dependencies or live Incus needed by the miniature CLI.
import std/[exitprocs, os, strutils]
import test_support

let sourceRoot = getCurrentDir()
let s = newSandbox("ocdev-version-")
addExitProc(proc() = s.close())
# Outer Make exports its resolved version and may forward command-line overrides.
var inherited: seq[string]
for key, value in s.env:
  if key.startsWith("GIT_") or key.startsWith("MAKE") or
      key in ["OCDEV_VERSION", "MFLAGS"]:
    inherited.add(key)
for key in inherited: s.env.del(key)
s.env["GIT_CONFIG_NOSYSTEM"] = "1"
s.env["GIT_CONFIG_GLOBAL"] = "/dev/null"
s.env["GIT_AUTHOR_NAME"] = "Version test"
s.env["GIT_AUTHOR_EMAIL"] = "version@example.invalid"
s.env["GIT_COMMITTER_NAME"] = "Version test"
s.env["GIT_COMMITTER_EMAIL"] = "version@example.invalid"
# The choosenim launcher resolves its toolchain through HOME. Git configuration
# is isolated above; the miniature CLI never reads application configuration.
s.env["HOME"] = getHomeDir()

proc run(binary: string; args: seq[string]): string =
  let r = s.run(findExe(binary), args, timeoutMs = 120000)
  doAssert r.code == 0, binary & " " & $args & "\n" & r.output & r.error
  r.output.strip()

proc fixture(path: string) =
  createDir(path / "cmd/ocdev/src")
  createDir(path / "bin")
  copyFile(sourceRoot / "Makefile", path / "Makefile")
  copyFile(sourceRoot / "cmd/ocdev/src/config.nim", path / "cmd/ocdev/src/config.nim")
  writeFile(path / "cmd/ocdev/src/ocdev.nim", "import config\necho Version\n")
  writeFile(path / ".gitignore", "bin/\n")

proc git(path: string; args: varargs[string]): string =
  run("git", @["-C", path] & @args)

proc build(path, expected: string; extra: seq[string] = @[]) =
  discard run("make", @["--no-print-directory", "-C", path,
    "all", "bin/ocdev-debug"] & extra)
  for binary in ["ocdev", "ocdev-debug"]:
    let actual = run(path / "bin" / binary, @["--version"])
    doAssert actual == expected, binary & ": expected " & expected & ", got " & actual

let repo = s.home / "repo"
fixture(repo)
discard git(repo, "init", "-q")
discard git(repo, "add", ".")
discard git(repo, "commit", "-qm", "initial")
let hash = git(repo, "rev-parse", "--short", "HEAD")
build(repo, hash)
discard git(repo, "tag", "v0.3.0")
build(repo, "v0.3.0")
discard git(repo, "tag", "-d", "v0.3.0")
build(repo, hash)
discard git(repo, "tag", "v0.3.0")
discard git(repo, "commit", "--allow-empty", "-qm", "next")
let distance = git(repo, "describe", "--tags", "--always")
doAssert distance.startsWith("v0.3.0-1-g")
build(repo, distance)
echo "PASS: tagless, exact tag, tag addition/removal, commit distance"

let source = repo / "cmd/ocdev/src/ocdev.nim"
let original = readFile(source)
writeFile(source, original & "# tracked change\n")
build(repo, distance & "-dirty")
writeFile(source, original)
build(repo, distance)
writeFile(repo / "untracked", "not dirty\n")
build(repo, distance)
build(repo, "override A", @["OCDEV_VERSION=override A"])
let quoted = "beta \"quoted\" 'words'; `false`"
build(repo, quoted, @["OCDEV_VERSION=" & quoted])
build(repo, distance)
s.env["OCDEV_VERSION"] = "environment-version"
build(repo, "environment-version")
build(repo, "command-line-version", @["OCDEV_VERSION=command-line-version"])
s.env.del("OCDEV_VERSION")
build(repo, distance)
echo "PASS: dirty/clean, untracked, literal overrides and precedence on both targets"

let archive = s.home / "archive"
fixture(archive)
build(archive, "dev")
build(archive, "archive-version", @["OCDEV_VERSION=archive-version"])
let nested = repo / "nested-archive"
fixture(nested)
build(nested, "dev")
let unborn = s.home / "unborn"
fixture(unborn)
discard git(unborn, "init", "-q")
build(unborn, "dev")
# Simulate Git being unavailable without removing the compiler/linker from PATH.
writeFile(s.home / "git", "#!/bin/sh\nexit 127\n")
setFilePermissions(s.home / "git", {fpUserRead, fpUserWrite, fpUserExec})
build(repo, "dev")
removeFile(s.home / "git")
discard run("nim", @["c", "--hints:off", "--out:" & archive / "bin/direct",
  archive / "cmd/ocdev/src/ocdev.nim"])
doAssert run(archive / "bin/direct", @[]) == "dev"
echo "PASS: archive, nested archive, unborn/missing Git and direct Nim fallbacks"

let worktree = s.home / "worktree"
discard git(repo, "worktree", "add", "--detach", worktree, "HEAD")
doAssert fileExists(worktree / ".git")
createDir(worktree / "bin")
build(worktree, distance)
echo "PASS: worktree .git file"

# The post-strip CI size check must not rebuild even with a different override.
discard run("strip", @[repo / "bin/ocdev"])
let stripped = readFile(repo / "bin/ocdev")
discard run("make", @["--no-print-directory", "-C", repo,
  "--old-file=bin/ocdev", "size-check", "OCDEV_VERSION=must-not-rebuild"])
doAssert readFile(repo / "bin/ocdev") == stripped
# A normal build following the size check still refreshes provenance.
build(repo, distance)
echo "PASS: post-strip size check preserves artifact; normal build refreshes"
