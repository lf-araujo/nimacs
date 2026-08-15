## Interactive REPL sessions on a pseudo-terminal we own -- ported almost
## verbatim from the GTK version's engine (pure std/posix, so it also covers
## macOS; Windows will need a ConPTY variant). A ReplSpec drives it; the driver
## brackets each block's output with markers whose literals are split (paste0)
## so they never appear in the driver's echo and desync the reader.

import std/[posix, os, strutils, tempfiles]

when not declared(posix_openpt):
  proc posix_openpt(flags: cint): cint {.importc, header: "<stdlib.h>".}
  proc grantpt(fd: cint): cint {.importc, header: "<stdlib.h>".}
  proc unlockpt(fd: cint): cint {.importc, header: "<stdlib.h>".}
  proc ptsname(fd: cint): cstring {.importc, header: "<stdlib.h>".}

type
  ReplSpec* = object
    argv*: seq[string]
    prime*, ready*, run*, quit*: string
  Session* = ref object
    master: cint
    pid: Pid
    spec: ReplSpec

const
  markerBegin = "__NIMACS_BOR__"
  markerEnd = "__NIMACS_END__"

let rSpec* = ReplSpec(
  argv: @["R", "--no-save", "--no-restore", "--quiet"],
  prime: ".nimacs_run <- function(path) { cat(paste0(\"__NIMACS\",\"_BOR__\"),\"\\n\"); " &
         "con <- textConnection(\"._b\",\"w\"); sink(con); sink(con,type=\"message\"); options(warn=1); " &
         "tryCatch(source(path,echo=FALSE,print.eval=TRUE), error=function(e) cat(\"Error:\",conditionMessage(e),\"\\n\")); " &
         "sink(type=\"message\"); sink(); close(con); cat(._b,sep=\"\\n\"); " &
         "cat(paste0(\"\\n__NIMACS\",\"_END__\"),\"\\n\"); flush(stdout()) }\n",
  ready: "cat(paste0(\"NIMACSx\",\"READY\"),\"\\n\")\n",
  run: ".nimacs_run(\"{file}\")\n",
  quit: "q('no')\n")

proc ptyWrite(fd: cint; s: string) =
  var off = 0
  while off < s.len:
    let n = write(fd, unsafeAddr s[off], s.len - off)
    if n <= 0: break
    off += n

proc readUntil(fd: cint; token: string): string =
  var b: array[4096, char]
  while token notin result:
    let n = read(fd, addr b[0], b.len)
    if n <= 0: break
    for i in 0 ..< n: result.add(b[i])

proc startSession*(spec: ReplSpec): Session =
  let exe = findExe(spec.argv[0])
  if exe.len == 0: return nil
  let master = posix_openpt(O_RDWR or O_NOCTTY)
  if master < 0: return nil
  discard grantpt(master); discard unlockpt(master)
  let sname = $ptsname(master)
  let argv = allocCStringArray(spec.argv)
  let pid = fork()
  if pid == 0:
    discard setsid()
    let slave = posix.open(sname.cstring, O_RDWR)
    discard dup2(slave, 0); discard dup2(slave, 1); discard dup2(slave, 2)
    if slave > 2: discard close(slave)
    discard close(master)
    discard execv(exe.cstring, argv)
    quit(127)
  result = Session(master: master, pid: pid, spec: spec)
  ptyWrite(master, spec.prime)
  ptyWrite(master, spec.ready)   # sync past banner + prime echo
  discard readUntil(master, "NIMACSxREADY")

proc runBlock*(s: Session; code: string): string =
  ## Run `code` in the session, returning the captured output.
  let path = genTempPath("focim-", ".src")
  writeFile(path, code)
  ptyWrite(s.master, s.spec.run.replace("{file}", path))
  let acc = readUntil(s.master, markerEnd)
  removeFile(path)
  var lines: seq[string]
  var collecting = false
  for raw in acc.split('\n'):
    let line = raw.strip(leading = false, trailing = true, chars = {'\r'})
    if markerEnd in line: break
    if collecting: lines.add(line)
    if markerBegin in line: collecting = true
  while lines.len > 0 and strutils.strip(lines[^1]) == "": lines.setLen(lines.len - 1)
  lines.join("\n")

proc closeSession*(s: Session) =
  if s == nil: return
  ptyWrite(s.master, s.spec.quit)
  discard close(s.master)
  discard kill(s.pid, SIGTERM)
  var status: cint
  discard waitpid(s.pid, status, 0)
