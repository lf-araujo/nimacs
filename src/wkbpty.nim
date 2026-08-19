## Thread-free PTY primitive: spawn a program on a pseudo-terminal / pseudo-
## console we own and poll it from the main loop (NO Nim thread -- a background
## thread floods input with phantom Esc under labwc/XWayland).
##
## `Pty` is the shared low-level object used by BOTH the in-pane terminal and the
## interactive REPL sessions (wkbsession): spawn, a non-blocking master, a
## rolling output buffer / screen grid, feed/size/close. Sessions layer a
## marker-driven `runBlock` on top of the same primitive.
##
## POSIX uses openpt/fork/exec + a non-blocking fd; Windows uses a ConPTY
## (CreatePseudoConsole) + pipes. The high-level API (`spawnPty`, `feed`,
## `drain`, `readUntil`, `setPtySize`, `closePty`, `alive`, `startPty`) is the
## same on both; the `wkbvterm` screen emulator is pure Nim and platform-free.

import std/[strutils, os]
import wkbvterm
export wkbvterm
from uirelays import Color

when defined(windows): import std/winlean   # Handle, WINBOOL, ...
else:                   import std/posix     # Pid, fork, ...

type
  Pty* = object
    outbuf*: string       ## line-log (REPL sessions; ANSI-stripped at draw)
    vt*: VTerm            ## screen-grid emulator (standalone terminal); nil for sessions
    when defined(windows):
      hpc: Handle         ## pseudo-console
      hproc: Handle       ## child process
      inw, outr: Handle   ## our write end (child stdin) / read end (child stdout)
      running: bool
    else:
      master*: cint       ## -1 when not running
      pid*: Pid
  PtyTerm* = Pty          ## the in-pane terminal is a bare Pty (name kept for the host)

# ============================ platform primitives ============================
# Each branch defines: ptSpawn, ptSetSize, ptAlive, ptWrite, ptReadAvail
# (>0 bytes / 0 none-now / -1 dead), and ptClose. The rest is shared.

when defined(windows):

  type
    COORD {.pure, bycopy.} = object
      x, y: int16
  const
    PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016
    EXTENDED_STARTUPINFO_PRESENT = 0x00080000'u32
    WAIT_OBJECT_0 = 0'i32

  proc createPipe(hRead, hWrite: ptr Handle; sa: ptr SECURITY_ATTRIBUTES;
                  size: int32): WINBOOL {.stdcall, dynlib: "kernel32", importc: "CreatePipe".}
  proc readFile(h: Handle; buf: pointer; n: int32; got: ptr int32;
                ov: pointer): WINBOOL {.stdcall, dynlib: "kernel32", importc: "ReadFile".}
  proc writeFile(h: Handle; buf: pointer; n: int32; put: ptr int32;
                 ov: pointer): WINBOOL {.stdcall, dynlib: "kernel32", importc: "WriteFile".}
  proc peekNamedPipe(h: Handle; buf: pointer; n: int32; read, avail, left: ptr int32):
                WINBOOL {.stdcall, dynlib: "kernel32", importc: "PeekNamedPipe".}
  proc waitForSingleObject(h: Handle; ms: int32): int32 {.stdcall, dynlib: "kernel32",
                importc: "WaitForSingleObject".}
  proc terminateProcess(h: Handle; code: uint32): WINBOOL {.stdcall, dynlib: "kernel32",
                importc: "TerminateProcess".}
  proc createPseudoConsole(size: COORD; hIn, hOut: Handle; flags: int32;
                phc: ptr Handle): int32 {.stdcall, dynlib: "kernel32", importc: "CreatePseudoConsole".}
  proc resizePseudoConsole(hc: Handle; size: COORD): int32 {.stdcall, dynlib: "kernel32",
                importc: "ResizePseudoConsole".}
  proc closePseudoConsole(hc: Handle) {.stdcall, dynlib: "kernel32", importc: "ClosePseudoConsole".}
  proc initProcThreadAttrList(lst: pointer; count, flags: int32;
                size: ptr int): WINBOOL {.stdcall, dynlib: "kernel32",
                importc: "InitializeProcThreadAttributeList".}
  proc updateProcThreadAttr(lst: pointer; flags: int32; attr: int; val: pointer;
                cb: int; prev, ret: pointer): WINBOOL {.stdcall, dynlib: "kernel32",
                importc: "UpdateProcThreadAttribute".}
  proc deleteProcThreadAttrList(lst: pointer) {.stdcall, dynlib: "kernel32",
                importc: "DeleteProcThreadAttributeList".}

  type
    STARTUPINFOEX = object
      si: STARTUPINFO
      attrList: pointer
  proc createProcessExW(appName: pointer; cmdLine: WideCString; pa, ta: pointer;
                inherit: WINBOOL; flags: uint32; env: pointer; cwd: WideCString;
                si: pointer; pi: ptr PROCESS_INFORMATION): WINBOOL {.stdcall,
                dynlib: "kernel32", importc: "CreateProcessW".}

  proc coord(cols, rows: int): COORD = COORD(x: int16(max(1, cols)), y: int16(max(1, rows)))

  proc ptSpawn(argv: openArray[string]; dir: string;
               env: openArray[(string, string)]; rows, cols: int): Pty =
    result.running = false
    if argv.len == 0: return
    let exe = findExe(argv[0])
    if exe.len == 0: return
    var sa = SECURITY_ATTRIBUTES(nLength: int32(sizeof(SECURITY_ATTRIBUTES)),
                                 lpSecurityDescriptor: nil, bInheritHandle: 1)
    var inR, inW, outR, outW: Handle
    if createPipe(addr inR, addr inW, addr sa, 0) == 0: return
    if createPipe(addr outR, addr outW, addr sa, 0) == 0: return
    var hpc: Handle
    if createPseudoConsole(coord(cols, rows), inR, outW, 0, addr hpc) != 0: return
    discard closeHandle(inR); discard closeHandle(outW)     # owned by the console now
    # attribute list carrying the pseudo-console
    var sz: int
    discard initProcThreadAttrList(nil, 1, 0, addr sz)
    let attr = alloc(sz)
    if initProcThreadAttrList(attr, 1, 0, addr sz) == 0: return
    discard updateProcThreadAttr(attr, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                                 addr hpc, sizeof(Handle), nil, nil)
    var six: STARTUPINFOEX
    six.si.cb = int32(sizeof(STARTUPINFOEX))
    six.attrList = attr
    # command line: quote args containing spaces
    var cmd = ""
    for i, a in argv:
      if i > 0: cmd.add ' '
      cmd.add (if ' ' in a: "\"" & a & "\"" else: a)
    var pi: PROCESS_INFORMATION
    let cwd = newWideCString(if dir.len > 0: dir else: getCurrentDir())
    let ok = createProcessExW(nil, newWideCString(cmd), nil, nil, 1,
                              EXTENDED_STARTUPINFO_PRESENT, nil, cwd, addr six, addr pi)
    deleteProcThreadAttrList(attr); dealloc(attr)
    if ok == 0: (discard closeHandle(inW); discard closeHandle(outR); closePseudoConsole(hpc); return)
    discard closeHandle(pi.hThread)
    result.hpc = hpc; result.hproc = pi.hProcess
    result.inw = inW; result.outr = outR; result.running = true

  proc ptAlive(t: Pty): bool = t.running
  proc ptSetSize(t: var Pty; rows, cols: int) =
    if t.running: discard resizePseudoConsole(t.hpc, coord(cols, rows))
  proc ptWrite(t: var Pty; s: string) =
    if t.running and s.len > 0:
      var put: int32
      discard writeFile(t.inw, unsafeAddr s[0], int32(s.len), addr put, nil)
  proc ptReadAvail(t: var Pty; b: var array[8192, char]): int =
    if not t.running: return -1
    var avail: int32
    if peekNamedPipe(t.outr, nil, 0, nil, addr avail, nil) == 0:
      t.running = false; return -1                 # pipe broken -> child gone
    if avail <= 0:
      if waitForSingleObject(t.hproc, 0) == WAIT_OBJECT_0: t.running = false; return -1
      return 0
    var got: int32
    if readFile(t.outr, addr b[0], int32(min(avail.int, b.len)), addr got, nil) == 0 or got == 0:
      t.running = false; return -1
    got.int
  proc ptClose(t: var Pty) =
    if not t.running: return
    closePseudoConsole(t.hpc)
    discard terminateProcess(t.hproc, 0)
    discard closeHandle(t.inw); discard closeHandle(t.outr); discard closeHandle(t.hproc)
    t.running = false

  proc adoptTerminal*(master: cint; pid: int; fg, bg: Color): Pty =
    discard   # hot-reload fd handoff is POSIX-only; returns a not-running Pty

else:

  when not declared(posix_openpt):
    proc posix_openpt(flags: cint): cint {.importc, header: "<stdlib.h>".}
    proc grantpt(fd: cint): cint {.importc, header: "<stdlib.h>".}
    proc unlockpt(fd: cint): cint {.importc, header: "<stdlib.h>".}
    proc ptsname(fd: cint): cstring {.importc, header: "<stdlib.h>".}
  when not declared(SIGWINCH):
    const SIGWINCH = cint(28)   # Linux/macOS/BSD: window-size-change signal

  type WinSz = object
    ws_row, ws_col, ws_xpixel, ws_ypixel: cushort
  proc ioctl(fd, request: cint; argp: pointer): cint {.importc, header: "<sys/ioctl.h>", varargs.}
  const TIOCSWINSZ = 0x5414   # Linux

  proc setSizeFd(master: cint; rows, cols: int) =
    if master < 0: return
    var ws = WinSz(ws_row: cushort(max(1, rows)), ws_col: cushort(max(1, cols)))
    discard ioctl(master, TIOCSWINSZ.cint, addr ws)

  proc ptSpawn(argv: openArray[string]; dir: string;
               env: openArray[(string, string)]; rows, cols: int): Pty =
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
    setSizeFd(master, rows, cols)
    result.master = master
    result.pid = pid

  proc ptAlive(t: Pty): bool = t.master >= 0
  proc ptSetSize(t: var Pty; rows, cols: int) = setSizeFd(t.master, rows, cols)
  proc ptWrite(t: var Pty; s: string) =
    if t.master >= 0 and s.len > 0: discard write(t.master, unsafeAddr s[0], s.len)
  proc ptReadAvail(t: var Pty; b: var array[8192, char]): int =
    if t.master < 0: return -1
    let n = read(t.master, addr b[0], b.len)
    if n > 0: return n
    elif n == 0: (t.master = -1; return -1)     # EOF: child exited
    else: return 0                              # EAGAIN: nothing right now
  proc ptClose(t: var Pty) =
    if t.master < 0: return
    discard close(t.master)
    discard kill(t.pid, SIGTERM)
    var status: cint
    discard waitpid(t.pid, status, 0)
    t.master = -1

  # -- POSIX-only extras: hot-reload fd handoff needs the raw fd/pid ----------
  proc adoptTerminal*(master: cint; pid: int; fg, bg: Color): Pty =
    ## Rebuild a terminal Pty from an fd/pid inherited across a hot reload.
    result = Pty(master: master, pid: Pid(pid), vt: newVTerm(24, 80, fg, bg))
    discard fcntl(master, F_SETFL, O_NONBLOCK)
    discard fcntl(master, F_SETFD, FD_CLOEXEC)
    setSizeFd(master, 2, 2)   # tiny now, so the first real resize forces a repaint

# ============================ shared high-level ==============================

proc spawnPty*(argv: openArray[string]; dir = "";
               env: openArray[(string, string)] = @[]; rows = 24; cols = 80): Pty =
  ## Spawn `argv` on a PTY/ConPTY. Returns a not-running Pty on any failure.
  ## `env` is applied in the POSIX child before exec; on Windows the child
  ## inherits our environment (per-child env vars are future work there).
  ptSpawn(argv, dir, env, rows, cols)

proc setPtySize*(t: Pty; rows, cols: int) =
  var t = t
  ptSetSize(t, rows, cols)
  if t.vt != nil: t.vt.resize(rows, cols)

proc setVtColors*(t: Pty; fg, bg: Color) =
  if t.vt != nil: (t.vt.defFg = fg; t.vt.defBg = bg)

proc notRunningPty*(): Pty =
  ## A Pty in the not-running state (POSIX master defaults to 0, a valid fd, so
  ## it must be set to -1; Windows defaults to running=false already).
  when not defined(windows): result.master = -1

proc alive*(t: Pty): bool = ptAlive(t)

proc feed*(t: var Pty; s: string) = ptWrite(t, s)

proc drain*(t: var Pty): bool =
  ## Non-blocking: consume everything available. A screen-grid terminal (vt !=
  ## nil) feeds the emulator; a REPL session appends to the line-log `outbuf`.
  var b {.noinit.}: array[8192, char]
  while true:
    let n = ptReadAvail(t, b)
    if n > 0:
      if t.vt != nil:
        var chunk = newString(n)
        copyMem(addr chunk[0], addr b[0], n)
        t.vt.write(chunk)
      else:
        for i in 0 ..< n: t.outbuf.add b[i]
    elif n < 0: return false                    # dead
    else: break                                 # nothing more right now
  true

proc pump*(t: var Pty) =
  discard drain(t)
  if t.vt == nil and t.outbuf.len > 200_000:
    t.outbuf = t.outbuf[^120_000 .. ^1]

proc readUntil*(t: var Pty; token: string; timeoutMs = 15_000; mirror = true): string =
  ## Block until `token` appears or we time out (poll, so it works on both the
  ## non-blocking fd and the Windows pipe). `mirror` also feeds `outbuf`.
  var b {.noinit.}: array[8192, char]
  var waited = 0
  while token notin result:
    let n = ptReadAvail(t, b)
    if n > 0:
      for i in 0 ..< n:
        result.add b[i]
        if mirror: t.outbuf.add b[i]
      waited = 0
    elif n < 0: break                           # child gone
    else:
      if waited >= timeoutMs: break
      sleep(2); waited += 2

proc closePty*(t: var Pty; quit = "") =
  if not alive(t): return
  if quit.len > 0: feed(t, quit)
  ptClose(t)

proc startPty*(cmd, dir: string; fg, bg: Color): Pty =
  ## Split a shell-style command line and spawn it, backed by a screen grid.
  result = spawnPty(cmd.splitWhitespace(), dir)
  if result.alive: result.vt = newVTerm(24, 80, fg, bg)

proc nudgeRepaint*(t: Pty) =
  ## Ask a full-screen TUI to repaint (used after a hot reload). POSIX SIGWINCHes;
  ## the grid snapshot handles this on all platforms so this is best-effort.
  when not defined(windows):
    if t.master >= 0: discard kill(t.pid, cint(28))

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
    elif c < ' ':
      inc i
    else:
      result.add c; inc i
