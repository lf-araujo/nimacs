## A small VT/ANSI terminal emulator: a screen grid of colored cells with a
## cursor, driven by the byte stream from a PTY. Enough to render cursor-
## addressed TUIs (claude, htop, vim) that the earlier ANSI-stripped line-log
## could not -- CUP/cursor moves, ED/EL erase, scroll region, insert/delete,
## the alternate screen, and SGR colors (16 / 256 / truecolor).
##
## Not a conformance-complete DEC VT; unknown sequences are swallowed rather
## than printed. Pure data -- the host reads `grid`/`cursor` and draws them.

import std/strutils
import uirelays   # Color, color

type
  Cell* = object
    ch*: string        ## one UTF-8 grapheme; "" renders as a blank
    fg*, bg*: Color
    inv*: bool         ## reverse video (swap fg/bg at draw time)
  VtState = enum vsGround, vsEsc, vsCsi, vsOsc
  VTerm* = ref object
    rows*, cols*: int
    grid*: seq[seq[Cell]]      ## the visible screen, rows*cols
    saved: seq[seq[Cell]]      ## stash for the primary screen while in alt
    inAlt*: bool               ## on the alternate screen (TUIs; no scrollback)
    scrollback*: seq[seq[Cell]] ## lines pushed off the top of the primary screen
    viewOffset*: int           ## lines scrolled up into scrollback (0 == live tail)
    mouseRep*: bool            ## app enabled mouse reporting (DECSET 1000/1002/1003)
    mouseSgr*: bool            ## app enabled SGR mouse encoding (DECSET 1006)
    cx*, cy*: int              ## cursor column, row (0-based)
    scx, scy: int              ## saved cursor (DECSC / ESC7)
    top, bot: int              ## scroll region rows [top, bot]
    curFg, curBg: Color
    inv, bold: bool
    defFg*, defBg*: Color      ## palette defaults (from the theme)
    st: VtState
    par: string                ## collected CSI parameter bytes
    priv: bool                 ## CSI '?' private marker
    osc: string

const maxScrollback = 5000    ## cap history so a long-running shell stays bounded

proc blankCell(t: VTerm): Cell = Cell(ch: "", fg: t.curFg, bg: t.curBg, inv: false)

proc blankRow(t: VTerm): seq[Cell] =
  result = newSeq[Cell](t.cols)
  for i in 0 ..< t.cols: result[i] = Cell(ch: "", fg: t.defFg, bg: t.defBg)

proc newVTerm*(rows, cols: int; fg, bg: Color): VTerm =
  result = VTerm(rows: max(1, rows), cols: max(1, cols),
                 defFg: fg, defBg: bg, curFg: fg, curBg: bg)
  result.top = 0; result.bot = result.rows - 1
  result.grid = newSeq[seq[Cell]](result.rows)
  for r in 0 ..< result.rows: result.grid[r] = result.blankRow()

proc clampCursor(t: VTerm) =
  t.cx = max(0, min(t.cx, t.cols - 1))
  t.cy = max(0, min(t.cy, t.rows - 1))

proc resize*(t: VTerm; rows, cols: int) =
  let rows = max(1, rows)
  let cols = max(1, cols)
  if rows == t.rows and cols == t.cols: return
  var ng = newSeq[seq[Cell]](rows)
  for r in 0 ..< rows:
    var row = newSeq[Cell](cols)
    for c in 0 ..< cols:
      row[c] = if r < t.grid.len and c < t.grid[r].len: t.grid[r][c]
               else: Cell(ch: "", fg: t.defFg, bg: t.defBg)
    ng[r] = row
  t.rows = rows; t.cols = cols
  t.grid = ng
  t.top = 0; t.bot = rows - 1
  t.viewOffset = min(t.viewOffset, t.scrollback.len)
  t.clampCursor()

proc maxViewOffset*(t: VTerm): int = t.scrollback.len

proc scrollView*(t: VTerm; delta: int) =
  ## Move the viewport by `delta` lines (positive = back into history).
  t.viewOffset = max(0, min(t.viewOffset + delta, t.scrollback.len))

proc viewRow*(t: VTerm; ry: int): seq[Cell] =
  ## Row `ry` (0-based, top of body) of the viewport, accounting for how far the
  ## user has scrolled back. When `viewOffset == 0` this is just `grid[ry]`.
  let idx = t.scrollback.len - t.viewOffset + ry
  if idx < 0: return t.blankRow()
  if idx < t.scrollback.len: return t.scrollback[idx]
  let g = idx - t.scrollback.len
  if g >= 0 and g < t.grid.len: return t.grid[g]
  t.blankRow()

# --- screen ops -------------------------------------------------------------

proc scrollUp(t: VTerm; n = 1) =
  ## Move lines in the scroll region up by n; blank the vacated bottom lines.
  ## On the primary screen with a full-height region, the evicted top line is
  ## preserved in `scrollback` so the user can scroll back to it.
  let history = not t.inAlt and t.top == 0 and t.bot == t.rows - 1
  for _ in 0 ..< n:
    if history:
      t.scrollback.add t.grid[0]
    for r in t.top ..< t.bot:
      t.grid[r] = t.grid[r + 1]
    t.grid[t.bot] = t.blankRow()
  if history and t.scrollback.len > maxScrollback:
    t.scrollback = t.scrollback[^maxScrollback .. ^1]
  # Keep a scrolled-up viewport looking at the same content as history grows.
  if history and t.viewOffset > 0:
    t.viewOffset = min(t.viewOffset + n, t.scrollback.len)

proc scrollDown(t: VTerm; n = 1) =
  for _ in 0 ..< n:
    for r in countdown(t.bot, t.top + 1):
      t.grid[r] = t.grid[r - 1]
    t.grid[t.top] = t.blankRow()

proc lineFeed(t: VTerm) =
  if t.cy == t.bot: t.scrollUp()
  elif t.cy < t.rows - 1: inc t.cy

proc putChar(t: VTerm; ch: string) =
  if t.cx >= t.cols:            # wrap
    t.cx = 0
    t.lineFeed()
  t.clampCursor()
  t.grid[t.cy][t.cx] = Cell(ch: ch, fg: t.curFg, bg: t.curBg, inv: t.inv)
  inc t.cx

proc eraseInLine(t: VTerm; mode: int) =
  let blank = Cell(ch: "", fg: t.defFg, bg: t.defBg)
  case mode
  of 0: (for c in t.cx ..< t.cols: t.grid[t.cy][c] = blank)          # cursor->end
  of 1: (for c in 0 .. min(t.cx, t.cols - 1): t.grid[t.cy][c] = blank)  # start->cursor
  of 2: (for c in 0 ..< t.cols: t.grid[t.cy][c] = blank)             # whole line
  else: discard

proc eraseInDisplay(t: VTerm; mode: int) =
  let blank = Cell(ch: "", fg: t.defFg, bg: t.defBg)
  case mode
  of 0:                                    # cursor -> end of screen
    t.eraseInLine(0)
    for r in t.cy + 1 ..< t.rows: t.grid[r] = t.blankRow()
  of 1:                                    # start -> cursor
    for r in 0 ..< t.cy: t.grid[r] = t.blankRow()
    t.eraseInLine(1)
  of 2, 3:                                 # whole screen
    for r in 0 ..< t.rows: t.grid[r] = t.blankRow()
  else: discard

proc insertLines(t: VTerm; n: int) =
  if t.cy < t.top or t.cy > t.bot: return
  for _ in 0 ..< n:
    for r in countdown(t.bot, t.cy + 1): t.grid[r] = t.grid[r - 1]
    t.grid[t.cy] = t.blankRow()

proc deleteLines(t: VTerm; n: int) =
  if t.cy < t.top or t.cy > t.bot: return
  for _ in 0 ..< n:
    for r in t.cy ..< t.bot: t.grid[r] = t.grid[r + 1]
    t.grid[t.bot] = t.blankRow()

proc insertChars(t: VTerm; n: int) =
  for _ in 0 ..< n:
    for c in countdown(t.cols - 1, t.cx + 1): t.grid[t.cy][c] = t.grid[t.cy][c - 1]
    t.grid[t.cy][t.cx] = Cell(ch: "", fg: t.defFg, bg: t.defBg)

proc deleteChars(t: VTerm; n: int) =
  for _ in 0 ..< n:
    for c in t.cx ..< t.cols - 1: t.grid[t.cy][c] = t.grid[t.cy][c + 1]
    t.grid[t.cy][t.cols - 1] = Cell(ch: "", fg: t.defFg, bg: t.defBg)

# --- SGR colors -------------------------------------------------------------

proc xterm256(n: int; defFg, defBg: Color): Color =
  if n < 16:
    const base = [0x000000, 0x800000, 0x008000, 0x808000, 0x000080, 0x800080,
                  0x008080, 0xc0c0c0, 0x808080, 0xff0000, 0x00ff00, 0xffff00,
                  0x0000ff, 0xff00ff, 0x00ffff, 0xffffff]
    let h = base[n]
    color(uint8(h shr 16 and 0xFF), uint8(h shr 8 and 0xFF), uint8(h and 0xFF))
  elif n < 232:
    let i = n - 16
    let r = i div 36
    let g = (i div 6) mod 6
    let b = i mod 6
    proc c(v: int): uint8 = uint8(if v == 0: 0 else: 55 + v * 40)
    color(c(r), c(g), c(b))
  else:
    let v = uint8(8 + (n - 232) * 10)
    color(v, v, v)

proc applySgr(t: VTerm; params: seq[int]) =
  var i = 0
  if params.len == 0:
    t.curFg = t.defFg; t.curBg = t.defBg; t.inv = false; t.bold = false; return
  while i < params.len:
    let p = params[i]
    case p
    of 0: t.curFg = t.defFg; t.curBg = t.defBg; t.inv = false; t.bold = false
    of 1: t.bold = true
    of 7: t.inv = true
    of 22: t.bold = false
    of 27: t.inv = false
    of 39: t.curFg = t.defFg
    of 49: t.curBg = t.defBg
    of 30..37: t.curFg = xterm256(p - 30, t.defFg, t.defBg)
    of 90..97: t.curFg = xterm256(p - 90 + 8, t.defFg, t.defBg)
    of 40..47: t.curBg = xterm256(p - 40, t.defFg, t.defBg)
    of 100..107: t.curBg = xterm256(p - 100 + 8, t.defFg, t.defBg)
    of 38, 48:
      # extended color: 5;n (256) or 2;r;g;b (truecolor)
      if i + 1 < params.len and params[i+1] == 5 and i + 2 < params.len:
        let col = xterm256(params[i+2], t.defFg, t.defBg)
        if p == 38: t.curFg = col else: t.curBg = col
        i += 2
      elif i + 1 < params.len and params[i+1] == 2 and i + 4 < params.len:
        let col = color(uint8(params[i+2] and 0xFF), uint8(params[i+3] and 0xFF),
                        uint8(params[i+4] and 0xFF))
        if p == 38: t.curFg = col else: t.curBg = col
        i += 4
    else: discard
    inc i

# --- CSI dispatch -----------------------------------------------------------

proc csiParams(par: string): seq[int] =
  for p in par.split(';'):
    result.add (if p.len == 0: 0 else: (try: parseInt(p) except: 0))

proc handleCsi(t: VTerm; final: char) =
  let ps = csiParams(t.par)
  proc arg(i, def: int): int = (if i < ps.len and ps[i] != 0: ps[i] else: def)
  case final
  of 'A': t.cy = max(t.top, t.cy - arg(0, 1))
  of 'B': t.cy = min(t.bot, t.cy + arg(0, 1))
  of 'C': t.cx = min(t.cols - 1, t.cx + arg(0, 1))
  of 'D': t.cx = max(0, t.cx - arg(0, 1))
  of 'E': t.cx = 0; t.cy = min(t.bot, t.cy + arg(0, 1))
  of 'F': t.cx = 0; t.cy = max(t.top, t.cy - arg(0, 1))
  of 'G', '`': t.cx = max(0, min(t.cols - 1, arg(0, 1) - 1))
  of 'd': t.cy = max(0, min(t.rows - 1, arg(0, 1) - 1))
  of 'H', 'f':
    t.cy = max(0, min(t.rows - 1, arg(0, 1) - 1))
    t.cx = max(0, min(t.cols - 1, arg(1, 1) - 1))
  of 'J': t.eraseInDisplay(arg(0, 0))
  of 'K': t.eraseInLine(arg(0, 0))
  of 'L': t.insertLines(arg(0, 1))
  of 'M': t.deleteLines(arg(0, 1))
  of '@': t.insertChars(arg(0, 1))
  of 'P': t.deleteChars(arg(0, 1))
  of 'S': t.scrollUp(arg(0, 1))
  of 'T': t.scrollDown(arg(0, 1))
  of 'm': t.applySgr(ps)
  of 'r':
    t.top = max(0, arg(0, 1) - 1)
    t.bot = min(t.rows - 1, arg(1, t.rows) - 1)
    if t.top >= t.bot: (t.top = 0; t.bot = t.rows - 1)
    t.cx = 0; t.cy = t.top
  of 's': t.scx = t.cx; t.scy = t.cy
  of 'u': t.cx = t.scx; t.cy = t.scy
  of 'h', 'l':
    if t.priv:
      let on = final == 'h'
      for p in ps:
        case p
        of 1049, 1047, 47:               # alternate screen
          if on and not t.inAlt:
            t.saved = t.grid
            t.grid = newSeq[seq[Cell]](t.rows)
            for r in 0 ..< t.rows: t.grid[r] = t.blankRow()
            t.inAlt = true
            t.viewOffset = 0             # alt screen has no scrollback to view
            if p == 1049: (t.scx = t.cx; t.scy = t.cy)
          elif not on and t.inAlt:
            t.grid = t.saved
            t.saved = @[]
            t.inAlt = false
            if p == 1049: (t.cx = t.scx; t.cy = t.scy)
        of 1000, 1002, 1003: t.mouseRep = on   # mouse click/drag/any reporting
        of 1006: t.mouseSgr = on               # SGR mouse encoding
        else: discard                    # ?25 (cursor), ?2004 (bracketed paste): ignored
  else: discard
  t.clampCursor()

# --- byte-stream driver -----------------------------------------------------

proc feedByte(t: VTerm; b: char) =
  case t.st
  of vsGround:
    case b
    of '\e': t.st = vsEsc
    of '\r': t.cx = 0
    of '\n', '\x0b', '\x0c': t.lineFeed()
    of '\b': t.cx = max(0, t.cx - 1)
    of '\t': t.cx = min(t.cols - 1, (t.cx div 8 + 1) * 8)
    of '\a': discard                       # bell
    else:
      if b >= ' ' or b.uint8 >= 0x80:       # printable / UTF-8 lead or cont
        t.putChar($b)
  of vsEsc:
    case b
    of '[': t.st = vsCsi; t.par = ""; t.priv = false
    of ']': t.st = vsOsc; t.osc = ""
    of '7': t.scx = t.cx; t.scy = t.cy; t.st = vsGround
    of '8': t.cx = t.scx; t.cy = t.scy; t.st = vsGround
    of 'M':                                # reverse index
      if t.cy == t.top: t.scrollDown() else: t.cy = max(0, t.cy - 1)
      t.st = vsGround
    of 'c': t.eraseInDisplay(2); t.cx = 0; t.cy = 0; t.st = vsGround   # RIS
    of '(', ')', '*', '+': discard         # charset select: consume next byte
    else: t.st = vsGround
  of vsCsi:
    case b
    of '?', '<', '=', '>': t.priv = true
    of '0'..'9', ';', ':': t.par.add b
    of ' '..'/': discard                   # intermediate bytes
    of '@'..'~': t.handleCsi(b); t.st = vsGround
    else: t.st = vsGround
  of vsOsc:
    # OSC ... terminated by BEL or ST (ESC \)
    if b == '\a': t.st = vsGround
    elif b == '\e': t.st = vsEsc           # ST: next char is '\'; ESC handler resets
    else: t.osc.add b

proc write*(t: VTerm; s: string) =
  ## Feed raw PTY bytes. UTF-8 multibyte sequences are reassembled into one cell.
  var i = 0
  while i < s.len:
    let c = s[i]
    if t.st == vsGround and c.uint8 >= 0x80:     # UTF-8 lead byte -> one grapheme
      var nbytes = 1
      if (c.uint8 and 0xE0) == 0xC0: nbytes = 2
      elif (c.uint8 and 0xF0) == 0xE0: nbytes = 3
      elif (c.uint8 and 0xF8) == 0xF0: nbytes = 4
      let stop = min(i + nbytes, s.len)
      t.putChar(s[i ..< stop])
      i = stop
    else:
      t.feedByte(c)
      inc i

proc lineText*(t: VTerm; row: int): string =
  ## The row's text with trailing blanks trimmed (for selection / copy).
  if row < 0 or row >= t.rows: return ""
  for c in t.grid[row]:
    result.add (if c.ch.len == 0: " " else: c.ch)
  result = result.strip(leading = false, trailing = true)

# --- hot-reload snapshot: preserve the visible screen across a re-exec so a TUI
#     looks identical afterwards without waiting for it to repaint (tmux-style).

proc serialize*(t: VTerm): string =
  ## Compact binary snapshot of the visible screen (dims, alt flag, cursor, cells).
  proc u16(s: var string; v: int) = s.add chr((v shr 8) and 0xFF); s.add chr(v and 0xFF)
  result = newStringOfCap(t.rows * t.cols * 8 + 16)
  result.u16(t.rows); result.u16(t.cols)
  result.add chr(if t.inAlt: 1 else: 0)
  result.u16(t.cx); result.u16(t.cy)
  for row in t.grid:
    for c in row:
      let n = min(c.ch.len, 255)
      result.add chr(n)
      if n > 0: result.add c.ch[0 ..< n]
      result.add chr(c.fg.r.int); result.add chr(c.fg.g.int); result.add chr(c.fg.b.int)
      result.add chr(c.bg.r.int); result.add chr(c.bg.g.int); result.add chr(c.bg.b.int)
      result.add chr(if c.inv: 1 else: 0)

proc restore*(t: VTerm; blob: string) =
  ## Rebuild the screen from a `serialize` snapshot.
  if blob.len < 9: return
  var i = 0
  proc rd(): int =
    if i >= blob.len: return 0
    result = blob[i].int and 0xFF; inc i
  proc rd16(): int = (let hi = rd(); let lo = rd(); (hi shl 8) or lo)
  let rows = rd16(); let cols = rd16()
  if rows <= 0 or cols <= 0: return
  t.resize(rows, cols)
  t.inAlt = rd() == 1
  t.cx = rd16(); t.cy = rd16()
  for r in 0 ..< rows:
    for c in 0 ..< cols:
      let n = rd()
      var ch = ""
      for _ in 0 ..< n:
        if i < blob.len: (ch.add blob[i]; inc i)
      let fr = rd(); let fgc = rd(); let fb = rd()
      let br = rd(); let bgc = rd(); let bb = rd()
      let inv = rd() == 1
      if r < t.grid.len and c < t.grid[r].len:
        t.grid[r][c] = Cell(ch: ch, fg: color(fr.uint8, fgc.uint8, fb.uint8),
                            bg: color(br.uint8, bgc.uint8, bb.uint8), inv: inv)
  t.clampCursor()
