## nimacs on uirelays (the "focim" branch): a pure-Nim, custom-rendered editor
## targeting Windows/macOS/Linux. The GTK version (nimacs.nim) stays on main.
##
## This module is the HOST: it owns the window, fonts, the NIF layout and the
## main event loop. The editor model lives in focimcore (shared with user
## config); focimconfig is the user's own Nim configuration.

import uirelays
import uirelays/layout
import focimcore
import focimconfig
import std/[os, tables]

const fontPath =
  when defined(windows): "C:/Windows/Fonts/consola.ttf"
  elif defined(macosx): "/System/Library/Fonts/Menlo.ttc"
  else: "/usr/share/fonts/truetype/hack/Hack-Regular.ttf"

const layoutSrc = "(layout (editor) (session (lines 12)) (status (lines 1)))"

proc drawPalette(app: App; area: Rect; lineH: int) =
  let boxW = min(area.w - 80, 620)
  let bx = area.x + (area.w - boxW) div 2
  let by = area.y + 36
  let items = paletteFiltered(app)
  let rows = min(items.len, 10)
  let boxBg = color(38, 42, 52)
  fillRect(rect(bx, by, boxW, (rows + 1) * lineH + 20), boxBg)
  discard drawText(app.font, bx + 10, by + 8, "> " & app.paletteQuery,
                   color(235, 235, 235), boxBg)
  var y = by + 8 + lineH + 4
  for i in 0 ..< rows:
    let rowBg = if i == app.paletteSel: color(60, 72, 96) else: boxBg
    fillRect(rect(bx + 4, y, boxW - 8, lineH), rowBg)
    discard drawText(app.font, bx + 12, y, items[i][1], color(222, 222, 222), rowBg)
    y += lineH

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

proc dispatch(app: var App; e: Event): bool =
  ## Route a key through the keymap (with prefix-sequence support). Returns
  ## true if the event was consumed by a command/prefix.
  let chord = chordOf(e)
  if chord.len == 0: return false
  if app.pendingPrefix.len > 0:
    let full = app.pendingPrefix & " " & chord
    app.pendingPrefix = ""
    if gKeymap.hasKey(full): gCommands[gKeymap[full]].run(app)
    else: app.msg = full & " is unbound"
    return true
  if gKeymap.hasKey(chord):
    gCommands[gKeymap[chord]].run(app); return true
  if isPrefix(chord):
    app.pendingPrefix = chord; app.msg = chord & "-"; return true
  false

proc main() =
  var screen = createWindow(960, 700)
  setWindowTitle("nimacs (focim)")
  var metrics: FontMetrics
  let font = openFont(fontPath, 15, metrics)
  let lineH = metrics.lineHeight

  registerBuiltins()
  var app = App(ed: createSynEdit(font), sess: createSynEdit(font),
                font: font, running: true, msg: "ready")
  if paramCount() >= 1 and fileExists(paramStr(1)):
    app.filePath = paramStr(1); app.ed.loadFromFile(app.filePath)
  else:
    app.ed.setText("#+TITLE: focim scratch\n\n" &
                   "C-c C-c runs the block; C-Enter runs a line; C-S-p opens the palette.\n\n" &
                   "#+begin_src r :session default\n" &
                   "x <- c(10, 20, 30)\nmean(x)\nsummary(x)\n#+end_src\n")
  app.sess.setText("session output\n")

  configure(app)            # user config (focimconfig.nim) -- full-typed, no ABI
  app.runHooks("startup")

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
      consumed = dispatch(app, e)

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
