## Configuration constants and types for ocdev
import std/[json, os, posix, strutils]

const
  Version* {.strdefine.} = "dev"
  ContainerPrefix* = "ocdev-"
  ProfileName* = "ocdev"
  BaseImage* = "images:ubuntu/25.10"
  SshPortStart* = 2200
  ServicePortStart* = 2300
  PortsPerVm* = 10
  ServicePortsCount* = 10
  MaxNameLength* = 50

# Runtime computed paths (can't be const because getHomeDir is runtime)
proc getOcdevDir*(): string =
  getHomeDir() / ".ocdev"

proc loadCreateConfig*(path = getOcdevDir() / "config.json"): tuple[baseImage, defaultBaseSource: string] =
  ## User-wide defaults; absent config preserves normal remote-image creation.
  result = (BaseImage, "")
  var info: Stat
  if stat(path.cstring, info) != 0:
    let code = osLastError()
    if code == OSErrorCode(ENOENT) and not symlinkExists(path):
      return
    raiseOSError(code, path)
  if not S_ISREG(info.st_mode):
    raise newException(IOError, "Config path must be a regular file")
  let settings = parseFile(path)
  if settings.kind != JObject:
    raise newException(ValueError, "Config must be a JSON object")
  for key in ["base_image", "default_base_source"]:
    if settings.hasKey(key) and settings[key].kind != JString:
      raise newException(ValueError, key & " must be a string")
  if settings.hasKey("base_image"):
    result.baseImage = settings["base_image"].getStr().strip()
    if result.baseImage.len == 0 or result.baseImage.startsWith("-"):
      raise newException(ValueError, "base_image must be a nonempty image reference")
  if settings.hasKey("default_base_source"):
    result.defaultBaseSource = settings["default_base_source"].getStr().strip()

proc getPortsFile*(): string =
  getOcdevDir() / "ports"

proc getLockFile*(): string =
  getOcdevDir() / ".lock"

# Convenience aliases for backward compatibility
template OcdevDir*: string = getOcdevDir()
template PortsFile*: string = getPortsFile()
template LockFile*: string = getLockFile()

type
  ExitCode* = enum
    ecSuccess = 0       ## Operation succeeded
    ecError = 1         ## General error
    ecPrereq = 2        ## Prerequisite check failed
    ecNotFound = 3      ## Container not found
    ecNotRunning = 4    ## Container not running
