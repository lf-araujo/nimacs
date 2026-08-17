## Thread-free PTY primitive: spawn a program on a pseudo-terminal we own
## (fork/exec -- NO Nim thread, which floods input with phantom Esc under
## labwc/XWayland) and poll the non-blocking master fd from the main loop.
##
## `Pty` is the shared low-level object used by BOTH the in-pane terminal and
## the interactive REPL sessions (wkbsession): openpt/fork/exec, a non-blocking
## master, a rolling output buffer for live display, feed/size/close. Sessions
## layer a marker-driven `runBlock` on top of the same primitive (see
## wkbsession.nim); nothing here spawns twice.
##
## v1 renders a scrolling, ANSI-stripped log; full VT/screen emulation (needed
## for claude's TUI) is future work.

import std/[posix, strutils, os]
import wkbvterm
export wkbvterm
from uirelays import Color

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
  Pty* = object
    master*: cint         ## -1 when not running
    pid*: Pid
    outbuf*: string       ## line-log (REPL sessions; ANSI-stripped at draw)
    vt*: VTerm            ## screen-grid emulator (standalone terminal); nil for sessions
  PtyTerm* = Pty          ## the in-pane terminal is a bare Pty (name kept for the host)

# --- low-level primitive: spawn / drain / feed / size / close -----------------

proc spawnPty*(argv: openArray[string]; dir = "";
               env: openArray[(string, string)] = @[];
               rows = 24; cols = 80): Pty =
  ## Fork/exec `argv` on a fresh PTY. Master is non-blocking + CLOEXEC.
  ## Returns a Pty with master == -1 on any failure.
  result.master = -1
  if argv.len == 0: return
  let exe = findExe(argv[0])
  if exe.len == 0: return
  let master = posix_openpt(O_RDWR or O_NOCTTY)
  if master < 0: return
  discard grantpt(master); discard unlockpt(master)
  let sname = $ptsname(master)
  let cargv = allocCStringArray(@argv)
  let pid = fork()
  if pid == 0:
    discard setsid()
    for (k, v) in env: putEnv(k, v)
    let slave = posix.open(sname.cstring, O_RDWR)
    discard dup2(slave, 0); discard dup2(slave, 1); discard dup2(slave, 2)
    if slave > 2: discard close(slave)
    discard close(master)
    if dir.len > 0: discard chdir(dir.cstring)
    putEnv("TERM", "xterm-256color")
    discard execv(exe.cstring, cargv)
    quit(127)
  discard fcntl(master, F_SETFL, O_NONBLOCK)
  discard fcntl(master, F_SETFD, FD_CLOEXEC)   # don't leak into later forks
  setSize(master, rows, cols)
  result.master = master
  result.pid = pid
  result.outbuf = ""

proc setPtySize*(t: Pty; rows, cols: int) =
  setSize(t.master, rows, cols)
  if t.vt != nil: t.vt.resize(rows, cols)

proc setVtColors*(t: Pty; fg, bg: Color) =
  if t.vt != nil: (t.vt.defFg = fg; t.vt.defBg = bg)

proc alive*(t: Pty): bool = t.master >= 0

proc feed*(t: var Pty; s: string) =
  if t.master >= 0 and s.len > 0:
    discard write(t.master, unsafeAddr s[0], s.len)

proc drain*(t: var Pty): bool =
  ## Non-blocking: consume everything available. A screen-grid terminal (vt !=
  ## nil) feeds the emulator; a REPL session appends to the line-log `outbuf`.
  ## Returns false and marks not-running on EOF (child closed its side).
  if t.master < 0: return false
  var b {.noinit.}: array[8192, char]
  while true:
    let n = read(t.master, addr b[0], b.len)
    if n > 0:
      if t.vt != nil:
        var chunk = newString(n)
        copyMem(addr chunk[0], addr b[0], n)
        t.vt.write(chunk)
      else:
        for i in 0 ..< n: t.outbuf.add b[i]
    elif n == 0:
      t.master = -1                # EOF: child exited
      return false
    else:
      break                        # EAGAIN: nothing more right now
  true

proc pump*(t: var Pty) =
  ## Drain and cap the line-log (for the session live display; the vt grid is
  ## bounded by construction).
  discard drain(t)
  if t.vt == nil and t.outbuf.len > 200_000:
    t.outbuf = t.outbuf[^120_000 .. ^1]

proc waitReadable(fd: cint; timeoutMs: int): bool =
  ## select() on one fd so blocking reads (runBlock) don't busy-spin.
  var fds: TFdSet
  FD_ZERO(fds)
  FD_SET(fd, fds)
  var tv = Timeval(tv_sec: posix.Time(timeoutMs div 1000),
                   tv_usec: posix.Suseconds((timeoutMs mod 1000) * 1000))
  select(fd + 1, addr fds, nil, nil, addr tv) > 0

proc readUntil*(t: var Pty; token: string; timeoutMs = 15_000; mirror = true): string =
  ## Block (via select) reading from the master until `token` appears or we
  ## time out. When `mirror`, bytes also flow into `outbuf` so the live display
  ## stays current; internal queries pass mirror=false to stay off the terminal.
  if t.master < 0: return
  var b {.noinit.}: array[4096, char]
  while token notin result:
    if not waitReadable(t.master, timeoutMs): break     # timed out / no data
    let n = read(t.master, addr b[0], b.len)
    if n > 0:
      for i in 0 ..< n:
        result.add b[i]
        if mirror: t.outbuf.add b[i]
    elif n == 0:
      t.master = -1; break                              # child exited
    # n < 0 (EAGAIN after a spurious wakeup): loop and select again

proc closePty*(t: var Pty; quit = "") =
  if t.master < 0: return
  if quit.len > 0: feed(t, quit)
  discard close(t.master)
  discard kill(t.pid, SIGTERM)
  var status: cint
  discard waitpid(t.pid, status, 0)
  t.master = -1

# --- convenience: the in-pane terminal (a Pty driven by a command line) -------

proc startPty*(cmd, dir: string; fg, bg: Color): Pty =
  ## Split a shell-style command line and spawn it on a PTY (terminal pane),
  ## backed by a screen-grid emulator so cursor-addressed TUIs render.
  result = spawnPty(cmd.splitWhitespace(), dir)
  if result.alive: result.vt = newVTerm(24, 80, fg, bg)

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
