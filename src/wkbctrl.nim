## Control server: a Unix-domain socket the editor polls (non-blocking, from the
## main loop -- NO thread) so external tools (e.g. Claude running in the terminal
## via `wkbctl`) can drive the editor: run code in a live session, read the
## buffer, or run a named command.
##
## Protocol (one request per connection; client half-closes after sending):
##   "buffer"                      -> the current buffer text
##   "eval\t<lang>\t<session>\n<code>" -> run <code> in that session, return output
##   "command\t<name>"             -> run a registered command, return "ok"/"?"
##   "blocks"                      -> list #+begin_src blocks (lang, session, lines)

import std/[posix, strutils, os, tables]
import wkbcore

type Sockaddr_un {.importc: "struct sockaddr_un", header: "<sys/un.h>", pure, final.} = object
  sun_family: cushort
  sun_path: array[108, char]

type ControlServer* = object
  listenFd*: cint
  clientFd*: cint
  inbuf*: string

proc controlPath*(): string = getCacheDir() / "wkbenchless" / "control.sock"

proc startControl*(): ControlServer =
  result = ControlServer(listenFd: -1, clientFd: -1)
  let path = controlPath()
  try: createDir(path.parentDir) except CatchableError: discard
  removeFile(path)
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  if fd.cint < 0: return
  var sa: Sockaddr_un
  sa.sun_family = AF_UNIX.cushort
  if path.len >= sa.sun_path.len: return
  copyMem(addr sa.sun_path[0], unsafeAddr path[0], path.len)
  if bindSocket(fd, cast[ptr SockAddr](addr sa), sizeof(sa).SockLen) != 0: return
  if listen(fd, 4) != 0: return
  discard fcntl(fd.cint, F_SETFL, O_NONBLOCK)
  discard fcntl(fd.cint, F_SETFD, FD_CLOEXEC)   # don't leak into forked sessions
  result.listenFd = fd.cint

proc handle(app: var App; req: string): string =
  let nl = req.find('\n')
  let header = (if nl >= 0: req[0 ..< nl] else: req).strip()
  let body = if nl >= 0: req[nl + 1 .. ^1] else: ""
  let parts = header.split('\t')
  case parts[0]
  of "buffer":
    result = app.ed.fullText()
  of "eval":
    let lang = if parts.len > 1 and parts[1].len > 0: parts[1] else: "r"
    let sess = if parts.len > 2 and parts[2].len > 0: parts[2] else: "default"
    let code = if body.len > 0: body elif parts.len > 3: parts[3] else: ""
    if strutils.strip(code).len == 0: return "(no code)"
    let s = getSession(app, lang, sess)
    if s == nil: return "(no session for '" & lang & "')"
    result = s.runBlock(code)
  of "command":
    if parts.len > 1 and gCommands.hasKey(parts[1]):
      gCommands[parts[1]].run(app); result = "ok: " & parts[1]
    else: result = "unknown command"
  of "blocks":
    let total = app.ed.getLineCount()
    var i = 0
    while i < total:
      let ln = strutils.strip(app.ed.getLineText(i))
      if ln.toLowerAscii.startsWith("#+begin_src"):
        result.add $(i + 1) & ": " & ln & "\n"
      inc i
    if result.len == 0: result = "(no src blocks)"
  else:
    result = "unknown verb: " & parts[0]

proc poll*(cs: var ControlServer; app: var App) =
  if cs.listenFd < 0: return
  if cs.clientFd < 0:
    let c = accept(cs.listenFd.SocketHandle, nil, nil)
    if c.cint >= 0:
      discard fcntl(c.cint, F_SETFL, O_NONBLOCK)
      discard fcntl(c.cint, F_SETFD, FD_CLOEXEC)   # so a forked session can't hold it open
      cs.clientFd = c.cint; cs.inbuf = ""
  if cs.clientFd >= 0:
    var b {.noinit.}: array[4096, char]
    while true:
      let n = read(cs.clientFd, addr b[0], b.len)
      if n > 0:
        for i in 0 ..< n: cs.inbuf.add b[i]
      elif n == 0:                       # client half-closed: request complete
        let resp = handle(app, cs.inbuf)
        if resp.len > 0: discard write(cs.clientFd, unsafeAddr resp[0], resp.len)
        discard close(cs.clientFd); cs.clientFd = -1
        break
      else:
        break                            # EAGAIN: nothing more yet
