## Strict local definitions. Loading and registration never execute recipe code.
import std/[os, json, strutils, sets, algorithm, math, tempfiles, posix]
import checksums/sha2
import yaml/[parser, data, stream, tojson]
import container

const MaxDefinitionBytes = 1024 * 1024
const PrivateDir = {fpUserRead, fpUserWrite, fpUserExec}
const PrivateFile = {fpUserRead, fpUserWrite}

proc invalid(message = "Invalid definition") {.noreturn.} =
  raise newException(ValueError, message)

proc obj(n: JsonNode) =
  if n.isNil or n.kind != JObject: invalid()
proc fields(n: JsonNode, allowed: openArray[string]) =
  obj(n)
  for key in n.keys:
    if key notin allowed: invalid("Unknown definition field")
proc required(n: JsonNode, key: string): JsonNode =
  obj(n)
  if not n.hasKey(key): invalid("Missing required definition field")
  n[key]
proc text(n: JsonNode): string =
  if n.isNil or n.kind != JString or n.getStr.len == 0: invalid()
  result = n.getStr
  for c in result:
    if c < ' ' or c == '\x7f': invalid("Invalid control character")
proc safeId(s: string): bool =
  if s.len == 0 or s.len > 128 or s[0] notin Letters + Digits: return false
  for c in s:
    if c notin Letters + Digits + {'_', '-', '.'}: return false
  s != "." and s != ".."
proc identifier(n: JsonNode): string =
  result = text(n)
  if not safeId(result): invalid("Invalid identifier")
proc boolean(n: JsonNode) =
  if n.kind != JBool: invalid()
proc strings(n: JsonNode, unique = false) =
  if n.kind != JArray: invalid()
  var seen = initHashSet[string]()
  for item in n:
    let s = text(item)
    if unique and s in seen: invalid("Duplicate entry")
    seen.incl(s)
proc safePath(s: string, absolute = true) =
  discard text(%s)
  if absolute and not s.isAbsolute: invalid("Expected absolute environment path")
  if s.startsWith("~") or '\\' in s: invalid("Invalid environment path")
  for part in s.split('/'):
    if part == "..": invalid("Parent traversal is not allowed")
proc hostPath(s, base: string): string =
  discard text(%s)
  var p = s
  if p.startsWith("~/"): p = getHomeDir() / p[2..^1]
  elif p.startsWith("~"): invalid("Unsupported home expansion")
  absolutePath(p, base).normalizedPath

proc checkEvents(raw: string) =
  # Validate before constructing JSON: no aliases/cycles, duplicate keys,
  # complex keys, custom tags, or unbounded nesting. JSON uses this pass too.
  var p: YamlParser
  p.init()
  var events = p.parse(raw)
  type Frame = object
    mapping, key: bool
    keys: HashSet[string]
  var stack: seq[Frame]
  var docs = 0
  for e in events:
    case e.kind
    of yamlStartDoc:
      inc docs
      if docs > 1: invalid("Expected one document")
    of yamlAlias: invalid("YAML aliases are not supported")
    of yamlStartMap, yamlStartSeq, yamlScalar:
      let props = case e.kind
        of yamlStartMap: e.mapProperties
        of yamlStartSeq: e.seqProperties
        else: e.scalarProperties
      if props.anchor != yAnchorNone: invalid("YAML anchors are not supported")
      if props.tag notin [yTagQuestionMark, yTagExclamationMark, yTagString,
          yTagInteger, yTagFloat, yTagBoolean, yTagNull, yTagMapping, yTagSequence]:
        invalid("Unsupported YAML tag")
      if stack.len > 0 and stack[^1].mapping:
        if stack[^1].key:
          if e.kind != yamlScalar: invalid("Expected scalar mapping key")
          let key = e.scalarContent
          if key in stack[^1].keys: invalid("Duplicate mapping key")
          stack[^1].keys.incl(key)
        stack[^1].key = not stack[^1].key
      if e.kind != yamlScalar:
        if stack.len >= 32: invalid("Definition nesting limit exceeded")
        stack.add(Frame(mapping: e.kind == yamlStartMap, key: true,
                        keys: initHashSet[string]()))
    of yamlEndMap, yamlEndSeq: discard stack.pop()
    else: discard
  if docs != 1: invalid("Expected one document")

proc document(path: string): JsonNode =
  try:
    let full = hostPath(path, getCurrentDir())
    let ext = splitFile(full).ext.toLowerAscii
    if ext notin [".json", ".yaml", ".yml"]: invalid()
    if getFileInfo(full).kind != pcFile: invalid()
    let f = open(full, fmRead)
    defer: f.close()
    var raw = newString(MaxDefinitionBytes + 1)
    let count = f.readBuffer(addr raw[0], raw.len)
    if count > MaxDefinitionBytes: invalid()
    raw.setLen(count)
    checkEvents(raw)
    if ext == ".json": result = parseJson(raw)
    else:
      let docs = loadToJson(raw)
      if docs.len != 1: invalid()
      result = docs[0]
  except CatchableError:
    # Never expose parser source lines, document values, or filesystem paths.
    raise newException(ValueError, "Cannot read or parse definition")

proc valueMatches(value, declaration: JsonNode) =
  case declaration["type"].getStr
  of "string":
    if value.kind != JString: invalid("Input type mismatch")
  of "stringList": strings(value)
  of "number":
    if value.kind notin {JInt, JFloat}: invalid("Input type mismatch")
    if classify(value.getFloat) in {fcNan, fcInf, fcNegInf}: invalid()
  of "boolean": boolean(value)
  else: invalid("Unsupported input type")
  if declaration.hasKey("choices"):
    let choices = declaration["choices"]
    if value.kind == JArray:
      for item in value:
        if item notin choices.elems: invalid("Input choice mismatch")
    elif value notin choices.elems: invalid("Input choice mismatch")

proc validateRecipe(n: JsonNode): JsonNode =
  fields(n, ["schemaVersion", "id", "name", "source", "tasks", "hooks", "processCompose"])
  if required(n, "schemaVersion").kind != JInt or n["schemaVersion"].getInt != 1: invalid("Unsupported schema version")
  discard identifier(required(n, "id"))
  discard text(required(n, "name"))
  let source = required(n, "source")
  fields(source, ["provider", "snapshot"])
  if source.hasKey("provider") and text(source["provider"]) != "ocdev": invalid("Unsupported provider")
  let snapshot = text(required(source, "snapshot")).split('/')
  if snapshot.len != 2 or not validateName(snapshot[0]).valid or not safeId(snapshot[1]): invalid("Invalid snapshot reference")
  source["provider"] = %"ocdev"
  let tasks = required(n, "tasks")
  obj(tasks)
  for name, task in tasks:
    if not safeId(name): invalid("Invalid task identifier")
    fields(task, ["kind", "plane", "cwd", "command", "args", "taskfile", "task", "timeoutMs", "inputs", "description"])
    let kind = text(required(task, "kind"))
    safePath(text(required(task, "cwd")))
    if task.hasKey("plane") and text(task["plane"]) != "env": invalid("Only environment tasks are supported")
    task["plane"] = %"env"
    if task.hasKey("description"): discard text(task["description"])
    if kind == "command":
      if task.hasKey("taskfile") or task.hasKey("task"): invalid()
      let command = text(required(task, "command"))
      if command.startsWith("-"): invalid()
      if task.hasKey("args"):
        if task["args"].kind != JArray: invalid()
        for arg in task["args"]:
          if arg.kind != JString or '\0' in arg.getStr: invalid()
      else: task["args"] = newJArray()
    elif kind == "taskfile":
      if task.hasKey("command") or task.hasKey("args"): invalid()
      safePath(text(required(task, "taskfile")), false)
      if text(required(task, "task")).startsWith("-"): invalid()
    else: invalid("Unsupported task kind")
    if task.hasKey("timeoutMs"):
      let t = task["timeoutMs"]
      if t.kind != JInt or t.getBiggestInt < 1 or t.getBiggestInt > 86_400_000: invalid("Invalid task timeout")
    if task.hasKey("inputs"):
      obj(task["inputs"])
      for inputName, input in task["inputs"]:
        if inputName.len == 0 or inputName[0] notin Letters: invalid("Invalid input identifier")
        for c in inputName:
          if c notin Letters + Digits + {'_'}: invalid("Invalid input identifier")
        fields(input, ["type", "required", "choices", "secret", "default", "description"])
        let typ = text(required(input, "type"))
        if typ notin ["string", "stringList", "number", "boolean"]: invalid("Unsupported input type")
        for key in ["required", "secret"]:
          if input.hasKey(key): boolean(input[key])
        if input.hasKey("description"): discard text(input["description"])
        if input.hasKey("secret") and input["secret"].getBool and (input.hasKey("default") or input.hasKey("choices")):
          invalid("Secret inputs cannot declare defaults or choices")
        if input.hasKey("choices"):
          if typ notin ["string", "stringList"]: invalid()
          strings(input["choices"], true)
          if input["choices"].len == 0: invalid()
        if input.hasKey("default"): valueMatches(input["default"], input)
  if n.hasKey("hooks"):
    fields(n["hooks"], ["afterCreate", "beforeDelete"])
    for hook, names in n["hooks"]:
      strings(names)
      for name in names:
        if not tasks.hasKey(name.getStr): invalid("Unknown hook task")
  if n.hasKey("processCompose"):
    let pc = n["processCompose"]
    fields(pc, ["cwd", "file", "binary", "projectName", "autostart", "services"])
    safePath(text(required(pc, "cwd")))
    safePath(text(required(pc, "file")), false)
    if pc.hasKey("binary"):
      let binary = text(pc["binary"])
      if binary.startsWith("-"): invalid()
    if pc.hasKey("projectName"): discard identifier(pc["projectName"])
    if pc.hasKey("autostart"): boolean(pc["autostart"])
    if pc.hasKey("services"):
      strings(pc["services"], true)
      for service in pc["services"]: discard identifier(service)
  n

proc loadRecipe*(path: string): JsonNode = validateRecipe(document(path))

proc canonical(n: JsonNode): string =
  case n.kind
  of JObject:
    var keys: seq[string]
    for key in n.keys: keys.add(key)
    keys.sort()
    result = "{"
    for i, key in keys:
      if i > 0: result.add(',')
      result.add($(%key) & ":" & canonical(n[key]))
    result.add('}')
  of JArray:
    result = "["
    for i, value in n.elems:
      if i > 0: result.add(',')
      result.add(canonical(value))
    result.add(']')
  else: result = $n

proc recipeDigest*(recipe: JsonNode): string =
  ## A content identity, not an authenticity or reproducibility guarantee.
  var hasher = initSha_256()
  hasher.update(canonical(validateRecipe(recipe.copy())))
  $hasher.digest()

proc registryDir(): string = getHomeDir() / ".ocdev" / "recipes"
var noFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
proc flock(fd: cint, operation: cint): cint {.importc, header: "<sys/file.h>".}
proc registryLock[T](body: proc(): T): T =
  let root = registryDir()
  if symlinkExists(parentDir(root)) or symlinkExists(root): invalid("Unsafe registry directory")
  createDir(root)
  setFilePermissions(root, PrivateDir)
  let fd = posix.open((root / ".lock").cstring, O_CREAT or O_RDWR or noFollow, Mode(0o600))
  if fd < 0: invalid("Cannot lock recipe registry")
  defer: discard posix.close(fd)
  if flock(fd, 2) != 0: invalid("Cannot lock recipe registry")
  defer: discard flock(fd, 8)
  result = body()

proc atomicWrite(path, content: string) =
  let (f, temporary) = createTempFile(".recipe-", ".tmp", parentDir(path))
  try:
    setFilePermissions(temporary, PrivateFile)
    f.write(content)
    f.flushFile()
    if fsync(getFileHandle(f)) != 0: invalid("Cannot persist recipe registry")
    f.close()
    moveFile(temporary, path)
  finally:
    if fileExists(temporary):
      f.close()
      removeFile(temporary)

proc registered(id: string): JsonNode =
  if not safeId(id): invalid("Invalid recipe reference")
  let root = registryDir()
  let pointerPath = root / (id & ".id.json")
  if symlinkExists(pointerPath): invalid("Unsafe registry entry")
  let pointer = document(pointerPath)
  fields(pointer, ["id", "digest"])
  if text(required(pointer, "id")) != id: invalid("Invalid registry entry")
  let digest = text(required(pointer, "digest"))
  if digest.len != 64: invalid("Invalid registry digest")
  for c in digest:
    if c notin {'0'..'9', 'a'..'f'}: invalid("Invalid registry digest")
  let revision = root / (id & "--" & digest & ".recipe.json")
  if symlinkExists(revision): invalid("Unsafe registry entry")
  result = loadRecipe(revision)
  if result["id"].getStr != id or recipeDigest(result) != digest: invalid("Recipe revision mismatch")

proc resolveRecipe*(reference: string): JsonNode =
  if reference.contains('/') or reference.startsWith("~") or splitFile(reference).ext.toLowerAscii in [".json", ".yaml", ".yml"]:
    return loadRecipe(reference)
  if not safeId(reference): invalid("Invalid recipe reference")
  if not dirExists(registryDir()): invalid("Recipe is not registered")
  # Pointers are atomically replaced and revisions immutable; reads need no lock/write.
  registered(reference)

proc summary(recipe: JsonNode): JsonNode =
  result = %*{"schemaVersion": 1, "id": recipe["id"], "name": recipe["name"],
              "source": recipe["source"], "digest": recipeDigest(recipe), "tasks": newJObject()}
  for name, task in recipe["tasks"]:
    var item = %*{"kind": task["kind"], "plane": "env"}
    if task.hasKey("inputs"):
      item["inputs"] = newJObject()
      for key, declaration in task["inputs"]:
        var input = %*{"type": declaration["type"]}
        for flag in ["secret", "required"]:
          if declaration.hasKey(flag): input[flag] = declaration[flag]
        item["inputs"][key] = input
    result["tasks"][name] = item
  if recipe.hasKey("hooks"): result["hooks"] = recipe["hooks"].copy()
  result["hasProcessCompose"] = %recipe.hasKey("processCompose")

proc showRecipe*(reference: string): JsonNode = summary(resolveRecipe(reference))
proc registerRecipe*(path: string): JsonNode =
  let recipe = loadRecipe(path)
  let id = recipe["id"].getStr
  let digest = recipeDigest(recipe)
  result = registryLock(proc(): JsonNode =
    let revision = registryDir() / (id & "--" & digest & ".recipe.json")
    if fileExists(revision) or symlinkExists(revision):
      if symlinkExists(revision) or canonical(loadRecipe(revision)) != canonical(recipe): invalid("Recipe revision mismatch")
    else: atomicWrite(revision, canonical(recipe))
    atomicWrite(registryDir() / (id & ".id.json"), $(%*{"id": id, "digest": digest}))
    summary(recipe))
proc listRecipes*(): JsonNode =
  if not dirExists(registryDir()): return newJArray()
  result = newJArray()
  var ids: seq[string]
  for kind, path in walkDir(registryDir()):
    let file = extractFilename(path)
    if file.endsWith(".id.json"):
      ids.add(file[0 ..< file.len - 8])
  ids.sort()
  for id in ids: result.add(summary(registered(id)))

proc loadProject*(path: string): JsonNode =
  result = document(path)
  fields(result, ["schemaVersion", "id", "name", "recipePath", "recipeId", "seedFiles", "inputDefaults"])
  if required(result, "schemaVersion").kind != JInt or result["schemaVersion"].getInt != 1: invalid("Unsupported schema version")
  discard identifier(required(result, "id"))
  if result.hasKey("name"): discard text(result["name"])
  if result.hasKey("recipePath") == result.hasKey("recipeId"): invalid("Select exactly one recipe reference")
  let base = parentDir(hostPath(path, getCurrentDir()))
  if result.hasKey("recipePath"):
    result["recipePath"] = %hostPath(text(result["recipePath"]), base)
  else: discard identifier(result["recipeId"])
  if not result.hasKey("seedFiles"): result["seedFiles"] = newJArray()
  if result["seedFiles"].kind != JArray: invalid()
  var ids, destinations = initHashSet[string]()
  for seed in result["seedFiles"]:
    fields(seed, ["id", "source", "destination", "mode", "required"])
    let id = identifier(required(seed, "id"))
    let destination = text(required(seed, "destination"))
    safePath(destination)
    if destination == "/" or destination.endsWith('/'): invalid("Invalid seed destination")
    if id in ids or destination.normalizedPath in destinations: invalid("Duplicate seed file")
    ids.incl(id)
    destinations.incl(destination.normalizedPath)
    seed["source"] = %hostPath(text(required(seed, "source")), base)
    let mode = text(required(seed, "mode"))
    if mode.len != 4 or mode[0] != '0': invalid("Expected four-digit octal mode")
    for c in mode:
      if c notin {'0'..'7'}: invalid("Invalid seed mode")
    boolean(required(seed, "required"))
  if result.hasKey("inputDefaults"):
    obj(result["inputDefaults"])
    let reference = if result.hasKey("recipePath"): result["recipePath"].getStr else: result["recipeId"].getStr
    let recipe = resolveRecipe(reference)
    for taskName, defaults in result["inputDefaults"]:
      obj(defaults)
      if not recipe["tasks"].hasKey(taskName): invalid("Unknown defaults task")
      let task = recipe["tasks"][taskName]
      for key, value in defaults:
        if not task.hasKey("inputs") or not task["inputs"].hasKey(key): invalid("Unknown default input")
        let declaration = task["inputs"][key]
        if declaration.hasKey("secret") and declaration["secret"].getBool: invalid("Secret defaults are forbidden")
        valueMatches(value, declaration)
