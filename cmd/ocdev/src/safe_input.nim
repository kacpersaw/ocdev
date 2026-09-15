## Bounded local input reads. Validate the opened descriptor, not a path stat.
import std/posix

proc readBoundedRegularFile*(path: string, maxBytes: int): string =
  ## Follow symlinks to regular files, but never block opening a FIFO.
  ## Errors intentionally omit paths and file contents.
  template invalid() =
    raise newException(ValueError, "Cannot read bounded regular file")
  if maxBytes < 0 or '\0' in path: invalid()
  let fd = posix.open(path.cstring, O_RDONLY or O_NONBLOCK or O_CLOEXEC)
  if fd < 0: invalid()
  defer: discard posix.close(fd)
  var info: Stat
  if fstat(fd, info) != 0 or not S_ISREG(info.st_mode): invalid()
  var buffer: array[8192, char]
  while true:
    # Read one extra byte only at the limit. This also handles zero limits and
    # files whose size changes (or whose stat size does not describe content).
    let remaining = maxBytes - result.len
    let requested = if remaining == 0: 1 else: min(buffer.len, remaining)
    let count = posix.read(fd, addr buffer[0], requested)
    if count < 0:
      if errno == EINTR: continue
      invalid()
    if count == 0: break
    if count > remaining: invalid()
    let start = result.len
    result.setLen(start + count)
    copyMem(addr result[start], addr buffer[0], count)
