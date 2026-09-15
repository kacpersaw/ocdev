## Public, secret-minimizing CLI projections and legacy output isolation.
import std/[os, osproc, json, strutils, posix]
import config, ports, container

proc captureLegacy*(body: proc(): int {.closure.}): int =
  ## Reuse lifecycle procedures directly. Child output must never corrupt JSON.
  flushFile(stdout)
  flushFile(stderr)
  let outFd = dup(STDOUT_FILENO)
  let errFd = dup(STDERR_FILENO)
  let sink = posix.open("/dev/null", O_WRONLY)
  if outFd < 0 or errFd < 0 or sink < 0:
    if outFd >= 0: discard posix.close(outFd)
    if errFd >= 0: discard posix.close(errFd)
    if sink >= 0: discard posix.close(sink)
    raise newException(IOError, "output.capture_failed")
  try:
    if dup2(sink, STDOUT_FILENO) < 0 or dup2(sink, STDERR_FILENO) < 0:
      raise newException(IOError, "output.capture_failed")
    result = body()
  finally:
    flushFile(stdout)
    flushFile(stderr)
    discard dup2(outFd, STDOUT_FILENO)
    discard dup2(errFd, STDERR_FILENO)
    discard posix.close(outFd)
    discard posix.close(errFd)
    discard posix.close(sink)

proc requireName*(name: string) =
  if not validateName(name).valid:
    raise newException(ValueError, "name.invalid: use a letter followed by letters, numbers or hyphens (max 50)")

proc queryInstances*(): JsonNode =
  let (raw, code) = execCmdEx("incus list --format=json 2>/dev/null")
  if code != 0: raise newException(IOError, "incus.query_failed")
  try:
    result = parseJson(raw)
    if result.kind != JArray: raise newException(ValueError, "invalid")
    for item in result:
      if item.kind != JObject or not item.hasKey("name") or item["name"].kind != JString or
          not item.hasKey("status") or item["status"].kind != JString:
        raise newException(ValueError, "invalid")
  except CatchableError:
    raise newException(IOError, "incus.invalid_metadata")

proc publicInstance*(item: JsonNode): JsonNode =
  let instance = item["name"].getStr()
  if not instance.startsWith(ContainerPrefix):
    raise newException(ValueError, "instance.unmanaged")
  let name = instance[ContainerPrefix.len .. ^1]
  requireName(name)
  var uuid = newJNull()
  if item.hasKey("config") and item["config"].kind == JObject:
    let value = item["config"].getOrDefault("volatile.uuid")
    if not value.isNil and value.kind == JString and value.getStr().len > 0: uuid = value
  let port = getPort(name)
  result = %*{"name": name, "instance": instance, "status": item["status"],
    "uuid": uuid, "ssh_port": (if port > 0: %port else: newJNull())}

proc plainInspect*(name: string): JsonNode =
  requireName(name)
  for item in queryInstances():
    if item["name"].getStr() == ContainerPrefix & name:
      result = publicInstance(item)
      result["recipe"] = newJNull()
      return
  raise newException(ValueError, "environment.not_found")

proc portRows*(): JsonNode =
  result = newJArray()
  let instances = queryInstances()
  if not fileExists(PortsFile): return
  for line in readFile(PortsFile).splitLines():
    if line.len == 0: continue
    let parts = line.split(':')
    if parts.len != 2: raise newException(ValueError, "ports.invalid_state")
    var port: int
    try: port = parseInt(parts[1])
    except ValueError: raise newException(ValueError, "ports.invalid_state")
    requireName(parts[0])
    if port < 1 or getServicePortBase(port) + ServicePortsCount - 1 > 65535:
      raise newException(ValueError, "ports.invalid_state")
    var status = "Missing"
    for item in instances:
      if item["name"].getStr() == ContainerPrefix & parts[0]: status = item["status"].getStr()
    result.add(%*{"name": parts[0], "ssh_port": port,
      "service_start": getServicePortBase(port),
      "service_end": getServicePortBase(port) + ServicePortsCount - 1, "status": status})

proc bindingRows*(name = ""): JsonNode =
  if name.len > 0: requireName(name)
  result = newJArray()
  var found = name.len == 0
  for item in queryInstances():
    let fullName = item["name"].getStr()
    if not fullName.startsWith(ContainerPrefix): continue
    let shortName = fullName[ContainerPrefix.len .. ^1]
    if name.len > 0 and name != shortName: continue
    found = true
    let devices = if item.hasKey("expanded_devices"): item["expanded_devices"]
                  elif item.hasKey("devices"): item["devices"] else: newJObject()
    if devices.kind != JObject: raise newException(ValueError, "incus.invalid_devices")
    for key, device in devices:
      if not key.startsWith("dyn-"): continue
      try:
        if device.kind != JObject or device.getOrDefault("type").getStr() != "proxy":
          raise newException(ValueError, "invalid")
        let host = parseInt(key[4 .. ^1])
        let target = device.getOrDefault("connect").getStr()
        if not target.startsWith("tcp:127.0.0.1:"):
          raise newException(ValueError, "invalid")
        let guest = parseInt(target.split(':')[^1])
        if host < 1 or host > 65535 or guest < 1 or guest > 65535:
          raise newException(ValueError, "invalid")
        result.add(%*{"name": shortName, "host_port": host, "container_port": guest,
          "status": item["status"]})
      except CatchableError:
        raise newException(ValueError, "ports.invalid_binding")
  if not found: raise newException(ValueError, "environment.not_found")

proc doctorResult*(): JsonNode =
  var checks = newJArray()
  let installed = findExe("incus").len > 0
  checks.add(%*{"id": "incus.executable", "ok": installed})
  var healthy = installed
  if installed:
    try:
      let instances = queryInstances()
      checks.add(%*{"id": "incus.connection", "ok": true, "instance_count": instances.len})
      let allocations = portRows()
      var stale = newJArray()
      for item in allocations:
        if item["status"].getStr() == "Missing": stale.add(item["name"])
      checks.add(%*{"id": "ports.allocations", "ok": stale.len == 0, "missing_instances": stale})
      if stale.len > 0: healthy = false
    except CatchableError:
      checks.add(%*{"id": "incus.metadata_and_ports", "ok": false})
      healthy = false
  %*{"ok": healthy, "checks": checks}
