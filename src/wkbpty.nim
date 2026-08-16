## Thread-free PTY terminal: spawn a program on a pseudo-terminal we own
## (fork/exec -- NO Nim thread, which floods input with phantom Esc under
## labwc/XWayland) and poll the non-blocking master fd from the main loop.
## v1 renders a scrolling, ANSI-stripped log; full VT/screen emulation (needed
## for claude's TUI) is future work.

import std/[posix, strutils, os]

when not declared(posix_openpt):
  proc posix_openpt(flags: cint): cint {.importc, header: "<stdlib.h>".}
  proc grantpt(fd: cint): cint {.importc, header: "<stdlib.h>".}
  proc unlockpt(fd: cint): cint {.importc, header: "<stdlib.h>".}
  proc ptsname(fd: cint): cstring {.importc, header: "<stdlib.h>".}

type WinSz = object
  ws_row, ws_col, ws_xpixel, ws_ypixel: cushort
proc ioctl(fd, request: cint; argp: pointer): cint {.importc, header: "<sys/ioctl.h>", varargs.}
const TIOCSWINSZ = 0x5414   # Linux

proc setSize(master: cint; rows, cols: int) =
  if master < 0: return
  var ws = WinSz(ws_row: cushort(max(1, rows)), ws_col: cushort(max(1, cols)))
  discard ioctl(master, TIOCSWINSZ.cint, addr ws)

type
  PtyTerm* = object
    master*: cint         ## -1 when not running
    pid*: Pid
    outbuf*: string       ## accumulated output

proc startPty*(cmd, dir: string): PtyTerm =
  result.master = -1
  let parts = cmd.splitWhitespace()
  if parts.len == 0: return
  let exe = findExe(parts[0])
  if exe.len == 0: return
  let master = posix_openpt(O_RDWR or O_NOCTTY)
  if master < 0: return
  discard grantpt(master); discard unlockpt(master)
  let sname = $ptsname(master)
  let argv = allocCStringArray(parts)
  let pid = fork()
  if pid == 0:
    discard setsid()
    let slave = posix.open(sname.cstring, O_RDWR)
    discard dup2(slave, 0); discard dup2(slave, 1); discard dup2(slave, 2)
    if slave > 2: discard close(slave)
    discard close(master)
    if dir.len > 0: discard chdir(dir.cstring)
    putEnv("TERM", "xterm-256color")
    discard execv(exe.cstring, argv)
    quit(127)
  discard fcntl(master, F_SETFL, O_NONBLOCK)
  setSize(master, 24, 80)          # give the child a sane terminal size
  result.master = master
  result.pid = pid
  result.outbuf = ""

proc setPtySize*(t: PtyTerm; rows, cols: int) =
  setSize(t.master, rows, cols)

proc pump*(t: var PtyTerm) =
  ## Drain whatever the pty has (non-blocking). Also reaps: if the child closed
  ## its side, mark not-running.
  if t.master < 0: return
  var b {.noinit.}: array[8192, char]
  var got = false
  while true:
    let n = read(t.master, addr b[0], b.len)
    if n > 0:
      for i in 0 ..< n: t.outbuf.add b[i]
      got = true
    elif n == 0:
      t.master = -1                # EOF: child exited
      break
    else:
      break                        # EAGAIN: nothing more right now
  if got and t.outbuf.len > 200_000:
    t.outbuf = t.outbuf[^120_000 .. ^1]

proc feed*(t: var PtyTerm; s: string) =
  if t.master >= 0 and s.len > 0:
    discard write(t.master, unsafeAddr s[0], s.len)

proc alive*(t: PtyTerm): bool = t.master >= 0

proc closePty*(t: var PtyTerm) =
  if t.master < 0: return
  discard close(t.master)
  discard kill(t.pid, SIGTERM)
  var status: cint
  discard waitpid(t.pid, status, 0)
  t.master = -1

proc stripAnsi*(s: string): string =
  ## Remove CSI (ESC[ ... final) and OSC (ESC] ... BEL) sequences and CRs.
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '\e' and i + 1 < s.len and s[i+1] == '[':
      i += 2
      while i < s.len and s[i] notin {'@'..'~'}: inc i
      if i < s.len: inc i
    elif c == '\e' and i + 1 < s.len and s[i+1] == ']':
      i += 2
      while i < s.len and s[i] notin {'\a', '\e'}: inc i
      if i < s.len and s[i] == '\a': inc i
    elif c == '\e':
      i += 2
    elif c == '\n' or c == '\t':
      result.add c; inc i
    elif c < ' ':                # drop stray control bytes (CR, BEL, BS, ...)
      inc i
    else:
      result.add c; inc i
