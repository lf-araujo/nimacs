## nimacs on uirelays (the "focim" branch): a pure-Nim, custom-rendered editor
## targeting Windows/macOS/Linux. The GTK version (nimacs.nim) stays on main.
##
## Now: app shell + interactive R session + a command registry with data-driven
## keybindings and a command palette (ported design from the GTK version).

import uirelays
import uirelays/layout
import widgets/synedit
import focimsession
import std/[tables, os, strutils]

const fontPath =
  when defined(windows): "C:/Windows/Fonts/consola.ttf"
  elif defined(macosx): "/System/Library/Fonts/Menlo.ttc"
  else: "/usr/share/fonts/truetype/hack/Hack-Regular.ttf"

const layoutSrc = "(layout (editor) (session (lines 12)) (status (lines 1)))"

type
  App = object
    ed, sess: SynEdit
    sessions: Table[string, Session]   ## key: langId & "/" & sessionName
    font: Font
    filePath, msg: string
    running: bool
    pendingPrefix: string              ## e.g. "C-c" awaiting the next chord
    paletteActive: bool
    paletteQuery: string
    paletteSel: int
  Command = object
    label: string
    run: proc(app: var App)

var gCommands: OrderedTable[string, Command]
var gKeymap: Table[string, string]   ## chord -> command name

proc defcommand(name, label: string; run: proc(app: var App)) =
  gCommands[name] = Command(label: label, run: run)
proc bindkey(chord, name: string) = gKeymap[chord] = name

# -- sessions --------------------------------------------------------------
proc specFor(lang: string): (bool, ReplSpec) =
  ## Which interpreter drives a given src-block language. Only R for now;
  ## config-registered specs (bindRepl) will extend this, as in the GTK build.
  case lang.toLowerAscii
  of "r", "rscript": (true, rSpec)
  else: (false, ReplSpec())

proc getSession(app: var App; lang, name: string): Session =
  let (ok, spec) = specFor(lang)
  if not ok: return nil
  let key = lang.toLowerAscii & "/" & name
  if app.sessions.hasKey(key) and app.sessions[key] != nil:
    return app.sessions[key]
  let s = startSession(spec)
  if s != nil: app.sessions[key] = s
  s

proc dedentBody(lines: seq[string]): string =
  ## Strip the common leading whitespace (org src blocks are indented).
  var minIndent = high(int)
  for ln in lines:
    if strutils.strip(ln).len == 0: continue
    var n = 0
    while n < ln.len and ln[n] in {' ', '\t'}: inc n
    minIndent = min(minIndent, n)
  if minIndent == high(int): minIndent = 0
  var outl: seq[string]
  for ln in lines:
    outl.add (if ln.len >= minIndent: ln[minIndent .. ^1] else: ln)
  outl.join("\n")

# -- command implementations -----------------------------------------------
proc runLine(app: var App) =
  let line = app.ed.getLineText(app.ed.currentLine)
  if strutils.strip(line).len == 0: return
  let s = getSession(app, "r", "default")
  if s == nil: app.msg = "could not start R (on PATH?)"; return
  let outp = s.runBlock(line)
  app.sess.appendOutput("> " & line & "\n")
  if outp.len > 0: app.sess.appendOutput(outp & "\n")
  app.msg = "ran line"

proc babelExecute(app: var App) =
  ## org-babel C-c C-c: run the src block enclosing the cursor in its
  ## :session and splice the output back as a #+RESULTS: block.
  let total = app.ed.getLineCount()
  let cur = app.ed.currentLine
  var b = -1
  var header = ""
  for i in countdown(cur, 0):
    let low = strutils.strip(app.ed.getLineText(i)).toLowerAscii
    if low.startsWith("#+begin_src"):
      b = i; header = strutils.strip(app.ed.getLineText(i)); break
    if low.startsWith("#+end_src") and i < cur: break   # cursor sits below a block
  if b < 0: app.msg = "not in a src block"; return
  var e = -1
  for i in b + 1 ..< total:
    if strutils.strip(app.ed.getLineText(i)).toLowerAscii.startsWith("#+end_src"):
      e = i; break
  if e < 0 or cur > e: app.msg = "not in a src block"; return

  let hdr = strutils.splitWhitespace(header)
  let lang = if hdr.len >= 2: hdr[1] else: ""
  var sessName = "default"
  var k = 2
  while k < hdr.len:
    if hdr[k] == ":session" and k + 1 < hdr.len: sessName = hdr[k + 1]
    inc k

  var bodyLines: seq[string]
  for i in b + 1 ..< e: bodyLines.add app.ed.getLineText(i)
  let s = getSession(app, lang, sessName)
  if s == nil: app.msg = "no session for '" & lang & "'"; return
  let outp = s.runBlock(dedentBody(bodyLines))
  app.sess.appendOutput("# " & (if lang.len > 0: lang else: "?") &
                        " [" & sessName & "]\n" & outp & "\n")

  # find an existing results block right after #+end_src (skip blanks)
  var p = e + 1
  while p < total and strutils.strip(app.ed.getLineText(p)).len == 0: inc p
  var removeTo = e + 1
  if p < total and strutils.strip(app.ed.getLineText(p)).toLowerAscii.startsWith("#+results:"):
    inc p
    while p < total and strutils.strip(app.ed.getLineText(p)).startsWith(":"): inc p
    removeTo = p

  var outLines: seq[string]
  for i in 0 .. e: outLines.add app.ed.getLineText(i)
  outLines.add ""
  outLines.add "#+RESULTS:"
  if strutils.strip(outp).len == 0:
    outLines.add ": "
  else:
    for ln in outp.split('\n'): outLines.add ": " & ln
  for i in removeTo ..< total: outLines.add app.ed.getLineText(i)

  app.ed.setText(outLines.join("\n"))
  app.ed.gotoLine(min(cur, app.ed.getLineCount() - 1), 0)
  app.msg = "babel: ran " & (if lang.len > 0: lang else: "?") & " block"

proc saveCmd(app: var App) =
  if app.filePath.len > 0:
    app.ed.saveToFile(app.filePath); app.ed.markSaved()
    app.msg = "saved " & extractFilename(app.filePath)
  else: app.msg = "no file (pass a path on the command line)"

proc quitCmd(app: var App) = app.running = false
proc paletteCmd(app: var App) =
  app.paletteActive = true; app.paletteQuery = ""; app.paletteSel = 0

proc registerCommands() =
  defcommand("save", "Save", saveCmd)
  defcommand("quit", "Quit", quitCmd)
  defcommand("run-line", "Run current line in session", runLine)
  defcommand("comment-toggle", "Comment: toggle line", proc(app: var App) = app.ed.toggleComment())
  defcommand("undo", "Undo", proc(app: var App) = app.ed.undo())
  defcommand("redo", "Redo", proc(app: var App) = app.ed.redo())
  defcommand("palette", "Command palette", paletteCmd)
  defcommand("babel-execute", "Org-babel: run this src block", babelExecute)
  bindkey("C-s", "save")
  bindkey("C-q", "quit")
  bindkey("C-Enter", "run-line")
  bindkey("C-c C-c", "babel-execute")
  bindkey("C-/", "comment-toggle")
  bindkey("C-z", "undo")
  bindkey("C-y", "redo")
  bindkey("C-S-p", "palette")

proc isPrefix(chord: string): bool =
  ## True if `chord` begins a multi-key binding (e.g. "C-c" for "C-c C-c").
  for k in gKeymap.keys:
    if k.startsWith(chord & " "): return true

# -- keychords -------------------------------------------------------------
proc keyName(k: KeyCode): string =
  if k in {KeyA..KeyZ}: return $chr(ord('a') + (ord(k) - ord(KeyA)))
  if k in {Key0..Key9}: return $chr(ord('0') + (ord(k) - ord(Key0)))
  if k in {KeyF1..KeyF12}: return "F" & $(ord(k) - ord(KeyF1) + 1)
  case k
  of KeyEnter: "Enter"
  of KeySpace: "Space"
  of KeySlash: "/"
  of KeyMinus: "-"
  of KeyEqual: "="
  of KeyPlus: "+"
  of KeyComma: ","
  of KeyPeriod: "."
  else: ""   # arrows/esc/tab etc. -> not a chord, let the editor handle them

proc chordOf(e: Event): string =
  if e.kind != KeyDownEvent: return ""
  let kn = keyName(e.key)
  if kn.len == 0: return ""
  if CtrlPressed in e.mods: result &= "C-"
  if AltPressed in e.mods: result &= "M-"
  if ShiftPressed in e.mods: result &= "S-"
  result &= kn

# -- command palette -------------------------------------------------------
proc paletteFiltered(app: App): seq[(string, string)] =
  let q = app.paletteQuery.toLowerAscii
  for name, c in gCommands:
    if q.len == 0 or q in c.label.toLowerAscii: result.add (name, c.label)

proc handlePalette(app: var App; e: Event) =
  if e.kind == KeyDownEvent:
    case e.key
    of KeyEsc: app.paletteActive = false
    of KeyEnter:
      let items = paletteFiltered(app)
      app.paletteActive = false
      if app.paletteSel >= 0 and app.paletteSel < items.len:
        gCommands[items[app.paletteSel][0]].run(app)
    of KeyUp: app.paletteSel = max(0, app.paletteSel - 1)
    of KeyDown:
      app.paletteSel = min(max(0, paletteFiltered(app).len - 1), app.paletteSel + 1)
    of KeyBackspace:
      if app.paletteQuery.len > 0:
        app.paletteQuery.setLen(app.paletteQuery.len - 1); app.paletteSel = 0
    else: discard
  elif e.kind == TextInputEvent:
    for ch in e.text:
      if ch == '\0': break
      app.paletteQuery.add ch
    app.paletteSel = 0

proc drawPalette(app: App; area: Rect; lineH: int) =
  let boxW = min(area.w - 80, 620)
  let bx = area.x + (area.w - boxW) div 2
  let by = area.y + 36
  let items = paletteFiltered(app)
  let rows = min(items.len, 10)
  let boxH = (rows + 1) * lineH + 20
  let boxBg = color(38, 42, 52)
  fillRect(rect(bx, by, boxW, boxH), boxBg)
  discard drawText(app.font, bx + 10, by + 8, "> " & app.paletteQuery,
                   color(235, 235, 235), boxBg)
  var y = by + 8 + lineH + 4
  for i in 0 ..< rows:
    let sel = i == app.paletteSel
    let rowBg = if sel: color(60, 72, 96) else: boxBg
    fillRect(rect(bx + 4, y, boxW - 8, lineH), rowBg)
    discard drawText(app.font, bx + 12, y, items[i][1], color(222, 222, 222), rowBg)
    y += lineH

proc main() =
  var screen = createWindow(960, 700)
  setWindowTitle("nimacs (focim)")
  var metrics: FontMetrics
  let font = openFont(fontPath, 15, metrics)
  let lineH = metrics.lineHeight
  registerCommands()

  var app = App(ed: createSynEdit(font), sess: createSynEdit(font),
                font: font, running: true, msg: "ready")
  if paramCount() >= 1 and fileExists(paramStr(1)):
    app.filePath = paramStr(1); app.ed.loadFromFile(app.filePath)
  else:
    app.ed.setText("#+TITLE: focim scratch\n\n" &
                   "C-c C-c runs the block below; C-Enter runs one line; C-S-p opens the palette.\n\n" &
                   "#+begin_src r :session default\n" &
                   "x <- c(10, 20, 30)\n" &
                   "mean(x)\n" &
                   "summary(x)\n" &
                   "#+end_src\n")
  app.sess.setText("R session -- cursor on a line, Ctrl+Enter to run.\n")

  let lay = parseLayout(layoutSrc)
  let bg = color(21, 23, 27)
  let sessBg = color(16, 18, 22)
  let statusBg = color(32, 35, 42)
  let statusFg = color(190, 190, 190)
  let noEvent = Event(kind: NoEvent)

  var e: Event
  while app.running:
    if not waitEvent(e): continue
    if e.kind in {WindowCloseEvent, QuitEvent}: break

    var consumed = false
    if app.paletteActive:
      handlePalette(app, e); consumed = true
    else:
      let chord = chordOf(e)
      if chord.len > 0:
        if app.pendingPrefix.len > 0:                 # completing a prefix seq
          let full = app.pendingPrefix & " " & chord
          app.pendingPrefix = ""
          if gKeymap.hasKey(full): gCommands[gKeymap[full]].run(app)
          else: app.msg = full & " is unbound"
          consumed = true
        elif gKeymap.hasKey(chord):
          gCommands[gKeymap[chord]].run(app); consumed = true
        elif isPrefix(chord):
          app.pendingPrefix = chord; app.msg = chord & "-"; consumed = true

    screen = getWindowLayout()
    let cells = resolve(lay, screen.width, screen.height, lineH)
    fillRect(rect(0, 0, screen.width, screen.height), bg)

    var editorRect = rect(0, 0, screen.width, screen.height)
    if cells.hasKey("editor"):
      editorRect = cells["editor"]
      discard app.ed.draw((if consumed: noEvent else: e), editorRect, focused = not app.paletteActive)
    if cells.hasKey("session"):
      fillRect(cells["session"], sessBg)
      discard app.sess.draw(noEvent, cells["session"], focused = false)
    if cells.hasKey("status"):
      let sr = cells["status"]
      fillRect(sr, statusBg)
      let name = if app.filePath.len > 0: extractFilename(app.filePath) else: "*scratch*"
      let dirty = if app.ed.changed: " [+]" else: ""
      discard drawText(app.font, sr.x + 6, sr.y,
        "  focim   " & name & dirty & "   " &
        $(app.ed.currentLine + 1) & ":" & $(app.ed.currentCol + 1) & "   " & app.msg,
        statusFg, statusBg)

    if app.paletteActive:
      drawPalette(app, editorRect, lineH)

    refresh()

  for s in app.sessions.values: closeSession(s)
  closeFont(font)

when isMainModule:
  main()
