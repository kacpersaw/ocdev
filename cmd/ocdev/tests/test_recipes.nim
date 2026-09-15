import std/[unittest, os, json, strutils, tempfiles]
import ../src/recipes

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

putEnv("HOME", oldHome)
removeDir(sandbox)
