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
    session: Session
    font: Font
    filePath, msg: string
    running: bool
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

# -- command implementations -----------------------------------------------
proc runLine(app: var App) =
  let line = app.ed.getLineText(app.ed.currentLine)
  if strutils.strip(line).len == 0: return
  if app.session == nil: app.session = startSession(rSpec)
  if app.session == nil: app.msg = "could not start R (on PATH?)"; return
  let outp = app.session.runBlock(line)
  app.sess.appendOutput("> " & line & "\n")
  if outp.len > 0: app.sess.appendOutput(outp & "\n")
  app.msg = "ran line"

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
  bindkey("C-s", "save")
  bindkey("C-q", "quit")
  bindkey("C-Enter", "run-line")
  bindkey("C-/", "comment-toggle")
  bindkey("C-z", "undo")
  bindkey("C-y", "redo")
  bindkey("C-S-p", "palette")

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
    app.ed.setText("# Ctrl+Enter runs the current line in R. C-S-p: palette.\n\n" &
                   "x <- c(10, 20, 30)\nmean(x)\nsummary(x)\n")
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
      if chord.len > 0 and gKeymap.hasKey(chord):
        gCommands[gKeymap[chord]].run(app); consumed = true

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

  closeSession(app.session)
  closeFont(font)

when isMainModule:
  main()
