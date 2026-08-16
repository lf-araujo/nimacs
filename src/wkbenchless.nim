## wkbenchless: a pure-Nim, custom-rendered literate editor (org-babel + LSP +
## interactive sessions) on uirelays, targeting Windows/macOS/Linux. A native,
## deeply Nim-configurable "workbench-less" alternative to heavier IDEs.
##
## This module is the HOST: it owns the window, fonts, the NIF layout and the
## main event loop. The editor model lives in wkbcore (shared with user
## config); wkbconfig is the user's own Nim configuration.

import uirelays
import uirelays/layout
import wkbcore
import wkbconfig
import std/[os, tables, strutils]

const fontPath =
  when defined(windows): "C:/Windows/Fonts/consola.ttf"
  elif defined(macosx): "/System/Library/Fonts/Menlo.ttc"
  else: "/usr/share/fonts/truetype/hack/Hack-Regular.ttf"

const layoutBare =                         # no session yet: just the editor
  "(layout (editor) (divS (px 2)) (status (lines 1)))"
const layoutPlain =                        # a session exists
  "(layout (editor) (divH1 (px 2)) (session (lines 12)) (divS (px 2)) (status (lines 1)))"
const layoutSrc =                          # the 4-quadrant src-edit env
  "(layout" &
  "  (cols" &
  "    (rows (editor (stretch 3)) (divH1 (px 2)) (session (stretch 2)))" &
  "    (divV (px 2))" &
  "    (rows (px 340) (objects (stretch 1)) (divH2 (px 2)) (help (stretch 1))))" &
  "  (divS (px 2))" &
  "  (status (lines 1)))"

const dividerNames = ["divH1", "divH2", "divV", "divS"]
const welcomeOrg = staticRead("../examples/welcome.org")

proc langIdOf(ext: string): string =
  ## The LSP languageId for a file extension ("" = none).
  case ext.toLowerAscii
  of ".nim", ".nims": "nim"
  of ".py", ".pyw": "python"
  of ".r": "r"
  of ".c", ".h": "c"
  of ".cpp", ".cxx", ".hpp": "cpp"
  of ".js": "javascript"
  else: ""

proc drawPalette(app: App; area: Rect; lineH: int) =
  let boxW = min(area.w - 80, 620)
  let bx = area.x + (area.w - boxW) div 2
  let by = area.y + 36
  let items = paletteEntries(app)
  let rows = min(items.len, 12)
  let boxBg = color(38, 42, 52)
  fillRect(rect(bx, by, boxW, (rows + 1) * lineH + 20), boxBg)
  let prompt = case app.paletteMode
    of pmCommands: "> "
    of pmBuffers: "buffer: "
    of pmFiles: app.paletteDir & "/ "
  discard drawText(app.font, bx + 10, by + 8, prompt & app.paletteQuery,
                   color(235, 235, 235), boxBg)
  var y = by + 8 + lineH + 4
  for i in 0 ..< rows:
    let rowBg = if i == app.paletteSel: color(60, 72, 96) else: boxBg
    fillRect(rect(bx + 4, y, boxW - 8, lineH), rowBg)
    discard drawText(app.font, bx + 12, y, items[i][1], color(222, 222, 222), rowBg)
    y += lineH

proc paletteAccept(app: var App) =
  let items = paletteEntries(app)
  if app.paletteSel < 0 or app.paletteSel >= items.len: return
  let id = items[app.paletteSel].id
  case app.paletteMode
  of pmCommands:
    app.paletteActive = false
    gCommands[id].run(app)
  of pmBuffers:
    app.paletteActive = false
    switchToBuffer(app, parseInt(id))
  of pmFiles:
    if id == "..":                          # navigate up, stay open
      app.paletteDir = parentDir(app.paletteDir); app.paletteQuery = ""; app.paletteSel = 0
    elif dirExists(id):                     # descend, stay open
      app.paletteDir = id; app.paletteQuery = ""; app.paletteSel = 0
    else:
      app.paletteActive = false
      openFile(app, id)

proc handlePalette(app: var App; e: Event) =
  if e.kind == KeyDownEvent:
    case e.key
    of KeyEsc: app.paletteActive = false
    of KeyEnter: paletteAccept(app)
    of KeyUp: app.paletteSel = max(0, app.paletteSel - 1)
    of KeyDown:
      app.paletteSel = min(max(0, paletteEntries(app).len - 1), app.paletteSel + 1)
    of KeyBackspace:
      if app.paletteQuery.len > 0:
        app.paletteQuery.setLen(app.paletteQuery.len - 1); app.paletteSel = 0
    else: discard
  elif e.kind == TextInputEvent:
    for ch in e.text:
      if ch == '\0': break
      app.paletteQuery.add ch
    app.paletteSel = 0

proc drawCompletion(app: App; area: Rect; lineH: int) =
  let rows = min(app.completionItems.len, 8)
  if rows == 0: return
  var chars = 8
  for i in 0 ..< rows: chars = max(chars, app.completionItems[i].len)
  let w = min(chars * (lineH div 2 + 1) + 16, area.w - 40)
  let bx = area.x + 24
  let by = area.y + 24
  let boxBg = color(40, 44, 52)
  fillRect(rect(bx, by, w, rows * lineH + 8), boxBg)
  var y = by + 4
  for i in 0 ..< rows:
    let rowBg = if i == app.completionSel: color(60, 72, 96) else: boxBg
    fillRect(rect(bx + 2, y, w - 4, lineH), rowBg)
    discard drawText(app.font, bx + 6, y, app.completionItems[i], color(222, 222, 222), rowBg)
    y += lineH

proc handleCompletion(app: var App; e: Event): bool =
  ## Returns true if consumed. On a non-navigation key it dismisses the popup
  ## and returns false so the key reaches the editor.
  if e.kind != KeyDownEvent: return false
  case e.key
  of KeyEsc: app.completionActive = false; true
  of KeyEnter, KeyTab: completionAccept(app); true
  of KeyUp: app.completionSel = max(0, app.completionSel - 1); true
  of KeyDown:
    app.completionSel = min(app.completionItems.len - 1, app.completionSel + 1); true
  else: app.completionActive = false; false

proc dispatch(app: var App; e: Event): bool =
  ## Route a key through the keymap (with prefix-sequence support). Returns
  ## true if the event was consumed by a command/prefix.
  let chord = chordOf(e)
  if chord.len == 0: return false
  # Let Ctrl+C copy a selection (SynEdit handles it) rather than starting the
  # org-babel prefix -- otherwise standard copy is shadowed by C-c C-c.
  if chord == "C-c" and app.pendingPrefix.len == 0 and app.ed.getSelectedText().len > 0:
    return false
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
  setWindowTitle("wkbenchless")
  var metrics, bigMetrics: FontMetrics
  var fontSize = 15
  var font = openFont(fontPath, fontSize, metrics)
  var bigFont = openFont(fontPath, fontSize * 3 div 2, bigMetrics)   # ~1.5x
  var lineH = metrics.lineHeight

  registerBuiltins()
  var app = App(ed: createSynEdit(font), sess: createSynEdit(font),
                objects: createSynEdit(font), help: createSynEdit(font),
                curLang: "r", curSession: "default", focus: "editor",
                font: font, bigFont: bigFont, fontSize: fontSize,
                running: true, msg: "ready")
  app.ed.showLineNumbers = true
  app.ed.bigFont = bigFont
  app.ed.theme.fg[TokenClass.Link] = color(96, 160, 255)   # org links in blue
  app.objects.setText("Objects\n(run a block: C-c C-c)\n")
  app.help.setText("Help\n(F1 on a word)\n")
  if paramCount() >= 1 and fileExists(paramStr(1)):
    app.filePath = paramStr(1)
    let ext = splitFile(app.filePath).ext
    app.ed.lang = fileExtToLanguage(ext)   # set before load: setText highlights now
    app.docLang = langIdOf(ext)            # for LSP
    app.ed.loadFromFile(app.filePath)
  else:
    app.ed.lang = langOrg                  # before setText, so org highlights now
    app.docLang = ""
    app.ed.setText(welcomeOrg)
  app.buffers = @[BufferState(ed: app.ed, filePath: app.filePath, docLang: app.docLang)]
  app.curBuf = 0
  app.sess.setText("session output\n")

  # `--goto N`: restore the cursor line after a recompile re-exec.
  for i in 1 .. paramCount() - 1:
    if paramStr(i) == "--goto":
      try: app.ed.gotoLine(parseInt(paramStr(i + 1)), 0)
      except ValueError: discard

  configure(app)            # user config (wkbconfig.nim) -- full-typed, no ABI
  app.runHooks("startup")

  let layBare = parseLayout(layoutBare)
  let layPlain = parseLayout(layoutPlain)
  let laySrc = parseLayout(layoutSrc)
  var lastMouse = (x: 0, y: 0)
  var suppressText = false   # swallow the TextInput that follows a prefix chord
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
    if suppressText:
      suppressText = false
      if e.kind == TextInputEvent: consumed = true   # the char after e.g. "C-c e"
    if not consumed:
      if app.paletteActive:
        handlePalette(app, e); consumed = true
      elif app.completionActive:
        consumed = handleCompletion(app, e)
    if not consumed and not app.paletteActive:
      if dispatch(app, e):
        consumed = true
        # A command/prefix ran from this keystroke; swallow the TextInput it may
        # also emit (e.g. M-x -> 'x', C-c e -> 'e') so it isn't typed anywhere.
        if e.kind == KeyDownEvent: suppressText = true

    # Session pane as a live REPL: when it has focus, type at the prompt.
    if not consumed and not app.paletteActive and not app.completionActive and
       app.focus == "session":
      case e.kind
      of KeyDownEvent:
        if e.key == KeyEnter: replSubmit(app); consumed = true
        elif e.key == KeyBackspace:
          if app.replInput.len > 0: app.replInput.setLen(app.replInput.len - 1)
          consumed = true
      of TextInputEvent:
        for ch in e.text:
          if ch == '\0': break
          app.replInput.add ch
        consumed = true
      else: discard

    if e.kind in {MouseMoveEvent, MouseDownEvent, MouseUpEvent}:
      lastMouse = (e.x, e.y)   # live proof of pointer delivery (XWayland check)

    if app.fontSize != fontSize:                 # zoom: re-open the fonts
      fontSize = app.fontSize
      font = openFont(fontPath, fontSize, metrics)
      bigFont = openFont(fontPath, fontSize * 3 div 2, bigMetrics)
      lineH = metrics.lineHeight
      app.font = font; app.bigFont = bigFont
      app.ed.setFont(font); app.sess.setFont(font)
      app.objects.setFont(font); app.help.setFont(font)
      app.ed.bigFont = bigFont
      for b in app.buffers.mitems: b.ed.setFont(font); b.ed.bigFont = bigFont

    screen = getWindowLayout()
    let lay = if app.srcEdit: laySrc
              elif app.sessions.len > 0: layPlain
              else: layBare
    let cells = resolve(lay, screen.width, screen.height, lineH)

    if e.kind == MouseDownEvent:          # click a pane to focus it
      for nm in ["editor", "session", "objects", "help"]:
        if cells.hasKey(nm):
          let r = cells[nm]
          if e.x >= r.x and e.x < r.x + r.w and e.y >= r.y and e.y < r.y + r.h:
            app.focus = nm
    fillRect(rect(0, 0, screen.width, screen.height), bg)

    var editorRect = rect(0, 0, screen.width, screen.height)
    # Route: a wheel goes to the pane under the pointer; other unconsumed input
    # goes to the focused pane. Everything else gets noEvent.
    let overlay = app.paletteActive or app.completionActive
    proc evFor(name: string): Event =
      if overlay: return noEvent
      if e.kind == MouseWheelEvent:
        if cells.hasKey(name):
          let r = cells[name]
          if lastMouse.x >= r.x and lastMouse.x < r.x + r.w and
             lastMouse.y >= r.y and lastMouse.y < r.y + r.h: return e
        return noEvent
      if not consumed and name == app.focus: return e
      return noEvent

    if cells.hasKey("editor"):
      editorRect = cells["editor"]
      let act = app.ed.draw(evFor("editor"), editorRect, focused = app.focus == "editor" and not overlay)
      if act.kind == ctrlClick:              # Ctrl+click an org link -> open it
        app.ed.gotoPos(act.pos)
        openLink(app)
    if cells.hasKey("session"):
      let r = cells["session"]
      fillRect(r, sessBg)
      let bh = lineH                       # top row = session switcher bar
      let ph = lineH                       # bottom row = live REPL prompt
      # switcher bar: one chip per open session, current highlighted
      let barRect = rect(r.x, r.y, r.w, bh)
      fillRect(barRect, color(26, 30, 38))
      var cx = r.x + 4
      let curKey = app.curLang & "/" & app.curSession
      for k in app.sessionKeys():
        let chipBg = if k == curKey: color(70, 100, 70) else: color(40, 44, 52)
        let label = " " & k & " "
        let w = label.len * (metrics.lineHeight div 2) + 4
        fillRect(rect(cx, r.y, w, bh), chipBg)
        discard drawText(app.font, cx + 2, r.y, label, color(220, 224, 210), chipBg)
        cx += w + 4
      # transcript
      discard app.sess.draw(evFor("session"),
        rect(r.x, r.y + bh, r.w, max(lineH, r.h - bh - ph)), focused = app.focus == "session")
      # prompt
      let pr = rect(r.x, r.y + r.h - ph, r.w, ph)
      let pbg = if app.focus == "session": color(30, 40, 52) else: color(20, 24, 30)
      fillRect(pr, pbg)
      let caret = if app.focus == "session": "_" else: ""
      discard drawText(app.font, pr.x + 4, pr.y,
        app.curLang & "> " & app.replInput & caret, color(210, 220, 150), pbg)
    if cells.hasKey("objects"):
      fillRect(cells["objects"], sessBg)
      discard app.objects.draw(evFor("objects"), cells["objects"], focused = app.focus == "objects")
    if cells.hasKey("help"):
      fillRect(cells["help"], sessBg)
      discard app.help.draw(evFor("help"), cells["help"], focused = app.focus == "help")
    for dn in dividerNames:
      if cells.hasKey(dn): fillRect(cells[dn], color(70, 78, 92))
    if cells.hasKey("status"):
      let sr = cells["status"]
      fillRect(sr, statusBg)
      let name = if app.filePath.len > 0: extractFilename(app.filePath) else: "*scratch*"
      let dirty = if app.ed.changed: " [+]" else: ""
      discard drawText(app.font, sr.x + 6, sr.y,
        "  wkbenchless   " & name & dirty & "   " &
        $(app.ed.currentLine + 1) & ":" & $(app.ed.currentCol + 1) &
        "   m:" & $lastMouse.x & "," & $lastMouse.y & "   " & app.msg,
        statusFg, statusBg)

    if app.completionActive:
      drawCompletion(app, editorRect, lineH)
    if app.paletteActive:
      drawPalette(app, editorRect, lineH)

    refresh()

  for s in app.sessions.values: closeSession(s)
  for c in app.lsp.values: shutdownLsp(c)
  closeFont(font)

when isMainModule:
  main()
