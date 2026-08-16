## Thread-free PTY terminal prototype: spawn bash on a pseudo-terminal we own,
## poll the master fd from the main loop (non-blocking), render the output.
## NO Nim background thread -> should not wedge input under XWayland.
## Type commands, Enter runs them, Esc quits. (Minimal: strips ANSI CSI, sends
## printable chars + Enter + Backspace; no cursor/alt-screen emulation yet.)

import uirelays
import std/[posix, strutils]
from std/os import findExe

when not declared(posix_openpt):
  proc posix_openpt(flags: cint): cint {.importc, header: "<stdlib.h>".}
  proc grantpt(fd: cint): cint {.importc, header: "<stdlib.h>".}
  proc unlockpt(fd: cint): cint {.importc, header: "<stdlib.h>".}
  proc ptsname(fd: cint): cstring {.importc, header: "<stdlib.h>".}

proc spawnPty(cmd: string): cint =
  let exe = findExe(cmd)
  if exe.len == 0: return -1
  let master = posix_openpt(O_RDWR or O_NOCTTY)
  if master < 0: return -1
  discard grantpt(master); discard unlockpt(master)
  let sname = $ptsname(master)
  let argv = allocCStringArray(@[cmd, "--norc", "-i"])
  let pid = fork()
  if pid == 0:
    discard setsid()
    let slave = posix.open(sname.cstring, O_RDWR)
    discard dup2(slave, 0); discard dup2(slave, 1); discard dup2(slave, 2)
    if slave > 2: discard close(slave)
    discard close(master)
    discard execv(exe.cstring, argv)
    quit(127)
  discard fcntl(master, F_SETFL, O_NONBLOCK)   # non-blocking reads
  master

proc stripAnsi(s: string): string =
  ## Remove CSI (ESC[ ... final byte) and OSC (ESC] ... BEL) sequences.
  var i = 0
  while i < s.len:
    if s[i] == '\e' and i + 1 < s.len and s[i+1] == '[':
      i += 2
      while i < s.len and s[i] notin {'@'..'~'}: inc i
      if i < s.len: inc i
    elif s[i] == '\e' and i + 1 < s.len and s[i+1] == ']':
      i += 2
      while i < s.len and s[i] != '\a' and s[i] != '\e': inc i
      if i < s.len: inc i
    elif s[i] == '\e':
      i += 2
    elif s[i] == '\r':
      inc i
    else:
      result.add s[i]; inc i

proc ptyWrite(fd: cint; s: string) =
  if s.len > 0: discard write(fd, unsafeAddr s[0], s.len)

proc main() =
  var screen = createWindow(700, 420)
  setWindowTitle("5 thread-free PTY terminal")
  var metrics: FontMetrics
  let font = openFont("/usr/share/fonts/truetype/hack/Hack-Regular.ttf", 15, metrics)
  let lineH = metrics.lineHeight
  let master = spawnPty("bash")
  if master < 0:
    discard drawText(font, 10, 10, "failed to spawn bash", color(255,120,120), color(0,0,0))
    refresh()
  var buf = ""
  var readBytes {.noinit.}: array[8192, char]
  var e: Event
  while true:
    if not waitEvent(e, 20):        # 20ms timeout -> poll the pty
      e = Event(kind: NoEvent)
    if e.kind in {WindowCloseEvent, QuitEvent}: break
    if e.kind == KeyDownEvent and e.key == KeyEsc: break

    if master >= 0:
      # drain whatever the pty has (non-blocking)
      while true:
        let n = read(master, addr readBytes[0], readBytes.len)
        if n <= 0: break
        for i in 0 ..< n: buf.add readBytes[i]
      # send input
      if e.kind == TextInputEvent:
        for ch in e.text:
          if ch != '\0': ptyWrite(master, $ch)
      elif e.kind == KeyDownEvent:
        case e.key
        of KeyEnter: ptyWrite(master, "\n")
        of KeyBackspace: ptyWrite(master, "\x7f")
        of KeyTab: ptyWrite(master, "\t")
        else: discard

    if buf.len > 60000: buf = buf[^40000 .. ^1]   # cap
    screen = getWindowLayout()
    fillRect(rect(0, 0, screen.width, screen.height), color(16, 18, 24))
    discard drawText(font, 8, 4, "thread-free PTY bash -- type; Esc quits",
                     color(150, 150, 160), color(16, 18, 24))
    let lines = stripAnsi(buf).splitLines()
    let rows = max(1, (screen.height - 30) div lineH)
    let start = max(0, lines.len - rows)
    var y = 26
    for i in start ..< lines.len:
      discard drawText(font, 8, y, lines[i], color(200, 210, 200), color(16, 18, 24))
      y += lineH
    refresh()

main()
