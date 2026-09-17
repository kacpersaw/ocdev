import std/[unittest, os, json, strutils, tempfiles, posix, monotimes, times]
import ../src/[recipes, safe_input]

proc boundedChild(body: proc()) =
  ## Keep a FIFO regression or allocator abort from hanging/crashing the suite.
  let child = fork()
  doAssert child >= 0
  if child == 0:
    try:
      body()
      exitnow(0)
    except:
      exitnow(1)
  var status: cint
  let deadline = getMonoTime() + initDuration(seconds = 3)
  while true:
    let waited = waitpid(child, status, WNOHANG)
    if waited == child: break
    doAssert waited == 0
    if getMonoTime() >= deadline:
      discard kill(child, SIGKILL)
      discard waitpid(child, status, 0)
      raise newException(ValueError, "Bounded child timed out")
    sleep(10)
  check WIFEXITED(status)
  check WEXITSTATUS(status) == 0

let sandbox = createTempDir("ocdev-recipes-test-", "")
let oldHome = getEnv("HOME")
putEnv("HOME", sandbox)
let recipePath = sandbox / "demo.json"
let projectPath = sandbox / "project.json"
proc example(): JsonNode =
  %*{"schemaVersion": 1, "id": "demo", "name": "Demo", "source": {"snapshot": "base/ready"},
     "tasks": {"check": {"kind": "command", "cwd": "/workspace", "command": "printf", "args": ["dummy-argument"],
       "inputs": {"TOKEN": {"type": "string", "secret": true}, "COUNT": {"type": "number", "default": 2}}}},
     "hooks": {"afterCreate": ["check"]}}
proc save(n: JsonNode): string =
  writeFile(recipePath, $n)
  recipePath

suite "strict recipe and project definitions":
  test "normalization and public projection":
    let recipe = loadRecipe(save(example()))
    check recipe["source"]["provider"].getStr == "ocdev"
    check recipe["tasks"]["check"]["plane"].getStr == "env"
    check not recipe.hasKey("definitionPath")
    let public = showRecipe(recipePath)
    check "dummy-argument" notin $public
    check "printf" notin $public
    check not public["tasks"]["check"]["inputs"]["COUNT"].hasKey("default")
  test "unknown fields, unsafe identifiers, source and hooks":
    for key in ["agentConfig", "databaseProvider", "unknown"]:
      var recipe = example()
      recipe[key] = newJObject()
      expect ValueError: discard loadRecipe(save(recipe))
    for id in ["../bad", "-bad", "a/b", ""]:
      var recipe = example()
      recipe["id"] = %id
      expect ValueError: discard loadRecipe(save(recipe))
    var recipe = example()
    recipe["source"]["snapshot"] = %"base/ready/extra"
    expect ValueError: discard loadRecipe(save(recipe))
    recipe = example()
    recipe["hooks"]["afterCreate"] = %*["missing"]
    expect ValueError: discard loadRecipe(save(recipe))
    recipe = example()
    recipe["hooks"]["afterDatabaseCreate"] = newJArray()
    expect ValueError: discard loadRecipe(save(recipe))
  test "environment paths and typed inputs":
    for cwd in ["relative", "/workspace/../etc", "~/work", "/tmp\nname"]:
      var recipe = example()
      recipe["tasks"]["check"]["cwd"] = %cwd
      expect ValueError: discard loadRecipe(save(recipe))
    var recipe = example()
    recipe["tasks"]["check"]["inputs"]["TOKEN"]["default"] = %"dummy-secret"
    expect ValueError: discard loadRecipe(save(recipe))
    recipe = example()
    recipe["tasks"]["check"]["inputs"]["TOKEN"]["choices"] = %*["dummy-secret"]
    expect ValueError: discard loadRecipe(save(recipe))
    recipe = example()
    recipe["tasks"]["check"]["inputs"]["COUNT"]["default"] = %"two"
    expect ValueError: discard loadRecipe(save(recipe))
    recipe = example()
    recipe["tasks"]["check"]["inputs"]["COUNT"]["type"] = %"object"
    expect ValueError: discard loadRecipe(save(recipe))
  test "YAML and JSON normalize identically":
    let yamlPath = sandbox / "demo.yaml"
    writeFile(yamlPath, "schemaVersion: 1\nid: demo\nname: Demo\nsource: {snapshot: base/ready}\ntasks: {}\n")
    let jsonRecipe = %*{"schemaVersion": 1, "id": "demo", "name": "Demo", "source": {"snapshot": "base/ready"}, "tasks": {}}
    check recipeDigest(loadRecipe(yamlPath)) == recipeDigest(loadRecipe(save(jsonRecipe)))
    for raw in ["id: one\nid: two\n", "x: &loop [*loop]\n", "---\nid: one\n---\nid: two\n", "x: !custom value\n"]:
      writeFile(yamlPath, raw)
      expect ValueError: discard loadRecipe(yamlPath)
    writeFile(recipePath, "{\"id\":\"one\",\"id\":\"two\"}")
    expect ValueError: discard loadRecipe(recipePath)
  test "bounded and sanitized malformed documents":
    writeFile(recipePath, "{dummy-secret: [}")
    try:
      discard loadRecipe(recipePath)
      check false
    except ValueError as error:
      check "dummy-secret" notin error.msg
    writeFile(recipePath, repeat(' ', 1024 * 1024 + 1))
    expect ValueError: discard loadRecipe(recipePath)
    writeFile(recipePath, repeat('[', 40) & repeat(']', 40))
    expect ValueError: discard loadRecipe(recipePath)
  test "regular input reads are bounded and follow regular symlinks":
    let input = sandbox / "dummy-input"
    let link = sandbox / "dummy-link.json"
    writeFile(input, "")
    check readBoundedRegularFile(input, 0) == ""
    writeFile(input, repeat('x', 8193))
    check readBoundedRegularFile(input, 8193).len == 8193
    for limit in [0, 8192, -1]:
      expect ValueError: discard readBoundedRegularFile(input, limit)
    createSymlink(input, link)
    check readBoundedRegularFile(link, 8193).len == 8193
    writeFile(input, $example())
    check loadRecipe(link)["id"].getStr == "demo"
    for path in [sandbox, "/dev/null", sandbox / "missing-dummy-secret"]:
      try:
        discard readBoundedRegularFile(path, 1024)
        check false
      except ValueError as error:
        check error.msg == "Cannot read bounded regular file"
    # procfs reports zero size but returns bytes: a stat-size-only limit fails.
    when defined(linux):
      var info: Stat
      check stat("/proc/self/status", info) == 0
      check info.st_size == 0
      expect ValueError: discard readBoundedRegularFile("/proc/self/status", 1)
  test "FIFO definitions and inputs are rejected without a writer":
    let fifo = sandbox / "fifo.json"
    check mkfifo(fifo.cstring, Mode(0o600)) == 0
    boundedChild(proc() =
      var rejected = false
      try: discard readBoundedRegularFile(fifo, 1024)
      except ValueError: rejected = true
      doAssert rejected
      rejected = false
      try: discard loadRecipe(fifo)
      except ValueError: rejected = true
      doAssert rejected)
    removeFile(fifo)
  test "project paths and nonsecret defaults":
    discard save(example())
    let project = %*{"schemaVersion": 1, "id": "project", "recipePath": "demo.json",
      "seedFiles": [{"id": "config", "source": "config.txt", "destination": "/workspace/config.txt", "mode": "0600", "required": true}],
      "inputDefaults": {"check": {"COUNT": 3}}}
    writeFile(projectPath, $project)
    let resolved = loadProject(projectPath)
    check resolved["recipePath"].getStr == recipePath
    check resolved["seedFiles"][0]["source"].getStr == sandbox / "config.txt"
    check not fileExists(sandbox / "config.txt") # loader never reads seed contents
    project["seedFiles"][0]["source"] = %"~/config.txt"
    writeFile(projectPath, $project)
    check loadProject(projectPath)["seedFiles"][0]["source"].getStr == sandbox / "config.txt"
    project["inputDefaults"]["check"]["TOKEN"] = %"dummy-secret"
    writeFile(projectPath, $project)
    expect ValueError: discard loadProject(projectPath)
    project.delete("inputDefaults")
    project["recipeId"] = %"demo"
    writeFile(projectPath, $project)
    expect ValueError: discard loadProject(projectPath)
  test "registry revisions are immutable and summary is safe":
    check listRecipes().len == 0
    check not dirExists(sandbox / ".ocdev")
    let first = registerRecipe(save(example()))
    let pinned = resolveRecipe("demo")
    var changed = example()
    changed["tasks"]["check"]["args"] = %*["second-dummy-argument"]
    let second = registerRecipe(save(changed))
    check first["digest"] != second["digest"]
    check recipeDigest(pinned) == first["digest"].getStr
    check recipeDigest(resolveRecipe("demo")) == second["digest"].getStr
    check fileExists(sandbox / ".ocdev/recipes" / ("demo--" & first["digest"].getStr & ".recipe.json"))
    check listRecipes().len == 1
    check "second-dummy-argument" notin $listRecipes()
    check getFilePermissions(sandbox / ".ocdev/recipes") == {fpUserRead, fpUserWrite, fpUserExec}
    check getFilePermissions(sandbox / ".ocdev/recipes/demo.id.json") == {fpUserRead, fpUserWrite}

  test "failed registry pointer rename closes once and removes temporary files":
    let root = sandbox / ".ocdev/recipes"
    let pointer = root / "demo.id.json"
    removeFile(pointer)
    createDir(pointer)
    discard save(example())
    boundedChild(proc() =
      var rejected = false
      try: discard registerRecipe(recipePath)
      except ValueError as error:
        doAssert error.msg == "Cannot persist recipe registry"
        rejected = true
      doAssert rejected)
    check dirExists(pointer)
    for kind, path in walkDir(root):
      check not extractFilename(path).startsWith(".recipe-")

putEnv("HOME", oldHome)
removeDir(sandbox)
