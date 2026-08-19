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
import wkbextensions
import wkbpty
import wkbctrl
import std/[os, tables, strutils]

const fontPath =
  when defined(windows): "C:/Windows/Fonts/consola.ttf"
  elif defined(macosx): "/System/Library/Fonts/Menlo.ttc"
  else: "/usr/share/fonts/truetype/hack/Hack-Regular.ttf"

proc facePath(suffix: string): string =
  ## The bold/italic sibling of `fontPath` if it exists, else the regular font
  ## (so emphasis degrades to plain rather than failing to open).
  let cand = fontPath.replace("-Regular", "-" & suffix)
  if cand != fontPath and fileExists(cand): cand else: fontPath

const layoutBare =                         # no session yet: just the editor
  "(layout (editor) (divS (px 2)) (status (lines 1)))"
const layoutPlain =                        # a session exists
  "(layout (editor) (divH1 (px 2)) (session (lines 12)) (divS (px 2)) (status (lines 1)))"
const layoutSrc =                          # the 4-quadrant src-edit env
  "(layout" &
  "  (cols" &
  "    (rows (stretch 7) (editor (stretch 3)) (divH1 (px 2)) (session (stretch 2)))" &
  "    (divV (px 2))" &
  "    (rows (stretch 3) (objects (stretch 1)) (divH2 (px 2)) (help (stretch 1))))" &
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
  const maxRows = 12
  let rows = min(items.len, maxRows)
  let boxBg = app.theme.boxBg
  fillRect(rect(bx, by, boxW, (rows + 1) * lineH + 20), boxBg)
  let prompt = case app.paletteMode
    of pmCommands: "> "
    of pmBuffers: "buffer: "
    of pmFiles: app.paletteDir & "/ "
    of pmThemes: "theme: "
    of pmOrg: "org: "
    of pmRecent: "recent: "
  # Scroll the visible window so the selection stays in view.
  var top = 0
  if app.paletteSel >= maxRows: top = app.paletteSel - maxRows + 1
  top = clamp(top, 0, max(0, items.len - maxRows))
  let more = items.len - top - rows
  let countTag = if items.len > maxRows: "   (" & $(app.paletteSel + 1) & "/" & $items.len & ")" else: ""
  discard drawText(app.font, bx + 10, by + 8, prompt & app.paletteQuery & countTag,
                   app.theme.boxFg, boxBg)
  var y = by + 8 + lineH + 4
  for i in top ..< top + rows:
    let rowBg = if i == app.paletteSel: app.theme.boxSelBg else: boxBg
    fillRect(rect(bx + 4, y, boxW - 8, lineH), rowBg)
    let suffix = if i == top + rows - 1 and more > 0: "   \u2026 +" & $more else: ""
    discard drawText(app.font, bx + 12, y, items[i][1] & suffix, app.theme.boxFg, rowBg)
    y += lineH

proc drawSearch(app: App; sr: Rect; lineH: int) =
  ## The find / replace minibuffer, drawn over the status bar row.
  let bg = app.theme.boxBg
  fillRect(sr, bg)
  let count =
    if app.searchQuery.len == 0: ""
    elif app.searchMatches.len == 0: "  (no matches)"
    else: "  " & $(app.searchIdx + 1) & "/" & $app.searchMatches.len
  var line: string
  if app.searchMode == smFind:
    line = "find: " & app.searchQuery & "\u2503" & count
  else:
    let qCur = if app.searchField == sfQuery: "\u2503" else: ""
    let rCur = if app.searchField == sfReplace: "\u2503" else: ""
    line = "replace: " & app.searchQuery & qCur & "  \u2192  " &
           app.searchReplace & rCur & count &
           "   [Enter: replace  ! : all  Tab: field  Esc: done]"
  discard drawText(app.font, sr.x + 6, sr.y, line, app.theme.boxFg, bg)

proc handleSearch(app: var App; e: Event) =
  if e.kind == KeyDownEvent:
    case e.key
    of KeyEsc: app.endSearch()
    of KeyEnter:
      if app.searchMode == smReplace and app.searchField == sfReplace:
        replaceCurrent(app)
      else:
        searchNext(app)
    of KeyTab:
      if app.searchMode == smReplace:
        app.searchField = if app.searchField == sfQuery: sfReplace else: sfQuery
    of KeyBackspace:
      if app.searchField == sfReplace:
        if app.searchReplace.len > 0: app.searchReplace.setLen(app.searchReplace.len - 1)
      elif app.searchQuery.len > 0:
        app.searchQuery.setLen(app.searchQuery.len - 1)
        recomputeMatches(app); gotoCurrentMatch(app)
    else: discard
  elif e.kind == TextInputEvent:
    for ch in e.text:
      if ch == '\0': break
      if app.searchMode == smReplace and app.searchField == sfReplace:
        app.searchReplace.add ch
      elif app.searchMode == smReplace and ch == '!':
        replaceAll(app); return
      else:
        app.searchQuery.add ch; recomputeMatches(app); gotoCurrentMatch(app)

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
  of pmThemes:
    app.paletteActive = false
    applyTheme(app, parseInt(id))
    setState("theme", app.theme.name)      # remember across restarts
  of pmOrg:
    app.paletteActive = false
    app.ed.gotoLine(parseInt(id) + 1, 0)
  of pmRecent:
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
  let boxBg = app.theme.boxBg
  fillRect(rect(bx, by, w, rows * lineH + 8), boxBg)
  var y = by + 4
  for i in 0 ..< rows:
    let rowBg = if i == app.completionSel: app.theme.boxSelBg else: boxBg
    fillRect(rect(bx + 2, y, w - 4, lineH), rowBg)
    discard drawText(app.font, bx + 6, y, app.completionItems[i], app.theme.boxFg, rowBg)
    y += lineH

proc handleCompletion(app: var App; e: Event): bool =
  ## Returns true if consumed. On a non-navigation key it dismisses the popup
  ## and returns false so the key reaches the editor.
  if e.kind != KeyDownEvent: return false
  case e.key
  of KeyEsc: app.completionActive = false; true
  of KeyTab: completionAccept(app); true
  of KeyUp: app.completionSel = max(0, app.completionSel - 1); true
  of KeyDown:
    app.completionSel = min(app.completionItems.len - 1, app.completionSel + 1); true
  of KeyEnter:
    # Enter accepts only if the user has moved into the list; otherwise it is a
    # newline so always-on suggestions never hijack the return key.
    if app.completionSel > 0: completionAccept(app); true
    else: app.completionActive = false; false
  else: false   # let the keystroke reach the editor; refresh happens post-draw

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

proc feedTerminalKey(t: var Pty; e: Event): bool =
  ## Translate a keystroke into the bytes a PTY expects. Shared by the standalone
  ## terminal and the live REPL-session terminal (both are just a `Pty`).
  if t.vt != nil and e.kind in {TextInputEvent, KeyDownEvent}:
    t.vt.viewOffset = 0          # any typing snaps the viewport back to the tail
  case e.kind
  of TextInputEvent:
    for ch in e.text:
      if ch != '\0': t.feed($ch)
    true
  of KeyDownEvent:
    case e.key
    of KeyEnter: t.feed("\r"); true
    of KeyBackspace: t.feed("\x7f"); true
    of KeyTab: t.feed("\t"); true
    of KeyEsc: t.feed("\e"); true
    of KeyUp: t.feed("\e[A"); true
    of KeyDown: t.feed("\e[B"); true
    of KeyRight: t.feed("\e[C"); true
    of KeyLeft: t.feed("\e[D"); true
    else:
      if CtrlPressed in e.mods and e.key in {KeyA..KeyZ}:
        t.feed($chr(ord(e.key) - ord(KeyA) + 1))   # Ctrl-A..Ctrl-Z
        true
      else: false
  else: false

proc blend(a, b: Color; t: int): Color =
  ## Mix t% of b into a (per channel), for subtle diff line backgrounds.
  proc mix(x, y: uint8): uint8 = uint8((x.int * (100 - t) + y.int * t) div 100)
  color(mix(a.r, b.r), mix(a.g, b.g), mix(a.b, b.b))

proc tabLabel(app: App; key: string): string =
  ## Display text for a bottom-pane tab key (the terminal shows its command).
  if key == terminalTabKey: app.termLabel else: key

proc tabWidth(app: App; key: string; lineH: int): int =
  (" " & tabLabel(app, key) & " ").len * (lineH div 2) + 4

proc termLines(outbuf: string): seq[string] =
  ## ANSI-strip the live buffer and drop the marker driver's own noise so a
  ## session terminal shows only interactive I/O and real block output. Every
  ## driver artefact -- the run call (`.nimacs_run(...)`), the markers
  ## (`__NIMACS_BOR__`), and the ready ping and its echo (`paste0("NIMACSx",
  ## "READY")`, split so the token never appears contiguously) -- carries
  ## "nimacs", so a case-insensitive substring test catches them all. Returns
  ## ALL lines; the caller windows them (with scrollback).
  for ln in stripAnsi(outbuf).splitLines():
    if "nimacs" in ln.toLowerAscii: continue
    result.add ln

proc main() =
  var screen = createWindow(960, 700)
  setWindowTitle("wkbenchless")
  var metrics, bigMetrics: FontMetrics
  var fontSize = 15
  var font = openFont(fontPath, fontSize, metrics)
  var bigFont = openFont(fontPath, fontSize * 3 div 2, bigMetrics)   # ~1.5x
  var lineH = metrics.lineHeight
  var emMetrics: FontMetrics
  var boldFont = openFont(facePath("Bold"), fontSize, emMetrics)
  var italicFont = openFont(facePath("Italic"), fontSize, emMetrics)
  var boldItalicFont = openFont(facePath("BoldItalic"), fontSize, emMetrics)
  var captionFont = openFont(fontPath, fontSize + 2, emMetrics)
  proc applyEmphasisFonts(ed: var SynEdit) =
    ed.setEmphasisFonts(boldFont, italicFont, boldItalicFont, captionFont)

  registerBuiltins()
  var app = App(ed: createSynEdit(font), sess: createSynEdit(font),
                objects: createSynEdit(font), help: createSynEdit(font),
                curLang: "r", curSession: "default", focus: "editor",
                font: font, bigFont: bigFont, fontSize: fontSize,
                running: true, msg: "ready")
  app.ed.showLineNumbers = true
  app.ed.bigFont = bigFont
  applyEmphasisFonts(app.ed)
  app.objects.setText("Objects\n(run a block: C-c C-c)\n")
  app.help.setText("Help\n(F1 on a word)\n")
  if paramCount() >= 1 and fileExists(paramStr(1)):
    app.filePath = paramStr(1)
    let ext = splitFile(app.filePath).ext
    app.ed.lang = fileExtToLanguage(ext)   # set before load: setText highlights now
    app.docLang = langIdOf(ext)            # for LSP
    app.ed.loadFromFile(app.filePath)
    noteRecentFile(app.filePath)
    if app.ed.lang == langOrg:
      app.ed.foldAllPending = true
  else:
    app.ed.lang = langOrg                  # before setText, so org highlights now
    app.docLang = ""
    app.ed.setText(welcomeOrg)
    app.ed.foldAllPending = true
  app.buffers = @[BufferState(ed: app.ed, filePath: app.filePath, docLang: app.docLang)]
  app.curBuf = 0
  app.sess.setText("session output\n")

  # `--goto N`: restore the cursor line after a recompile re-exec.
  for i in 1 .. paramCount() - 1:
    if paramStr(i) == "--goto":
      try: app.ed.gotoLine(parseInt(paramStr(i + 1)), 0)
      except ValueError: discard

  configure(app)            # user config (wkbconfig.nim) -- full-typed, no ABI
  loadExtensions(app)       # extensions/*.nim, each with proc extend*(app)
  setupExecPath()           # seed PATH from the login shell (+ config paths)
  # Themes come from the config; guarantee one so the chrome is never unstyled,
  # and honor a default the config may already have applied.
  if gThemes.len == 0: registerTheme("default", defaultBase16())
  if app.theme.name.len == 0: applyTheme(app, 0)
  loadState()                               # persisted UI state (XDG config dir)
  if gState.hasKey("theme"):                # start in the last theme the user picked
    applyThemeByName(app, gState["theme"])
  app.runHooks("startup")

  let layBare = parseLayout(layoutBare)
  let layPlain = parseLayout(layoutPlain)
  let laySrc = parseLayout(layoutSrc)
  var lastMouse = (x: 0, y: 0)
  var pty = notRunningPty()               # thread-free in-pane terminal
  var ctrl = startControl()              # control socket for wkbctl / agents
  let termGridPath = getTempDir() / "wkbenchless-termgrid"
  var termRepaintFrames = 0              # fallback nudge if no grid snapshot exists
  block:                                 # adopt sessions/terminal from a hot reload
    let ti = adoptHandoff(app)
    if ti.master >= 0:
      pty = adoptTerminal(ti.master, ti.pid, app.theme.termFg, app.theme.panelBg)
      app.hasTerminal = true; app.termLabel = ti.label; app.termActive = ti.active
      if getEnv("WKB_TERMGRID").len > 0 and fileExists(getEnv("WKB_TERMGRID")):
        pty.vt.restore(readFile(getEnv("WKB_TERMGRID")))   # identical screen, no repaint wait
        removeFile(getEnv("WKB_TERMGRID")); delEnv("WKB_TERMGRID")
      else:
        termRepaintFrames = 3            # no snapshot: fall back to SIGWINCH nudges
    if app.sessions.len > 0 or ti.master >= 0:
      app.sessionHidden = false
      app.msg = "reloaded -- sessions & terminal preserved"
  # Terminal text selection (drag to select, copy on release). Coords are
  # (row, col) within the drawn terminal body.
  var selecting = false
  var selHas = false
  var selA, selB = (r: 0, c: 0)

  # The bottom pane is a live terminal on whichever Pty is current: the
  # standalone terminal (M-t / claude), or else the current REPL session.
  proc activePtyPtr(): ptr Pty =
    if app.termActive: addr pty
    else:
      let cs = currentSession(app)
      if cs != nil: addr cs.pty else: nil
  var suppressText = false   # swallow the TextInput that follows a prefix chord
  let noEvent = Event(kind: NoEvent)

  var e: Event
  while app.running:
    let livePane = not app.sessionHidden and (app.termActive or currentSession(app) != nil)
    # A timeout so we still poll the pty and the control socket while idle.
    if not waitEvent(e, if livePane: 30 else: 100):
      e = Event(kind: NoEvent)
    if e.kind in {WindowCloseEvent, QuitEvent}: break

    if app.termRequest.len > 0:               # (re)start the terminal process
      closePty(pty)
      pty = startPty(app.termRequest, terminalDir(app), app.theme.termFg, app.theme.panelBg)
      if not pty.alive: app.msg = "could not start " & app.termRequest
      app.termRequest = ""
    # Retire the terminal tab once its process has ended and we've moved off it.
    if app.hasTerminal and not pty.alive and not app.termActive:
      app.hasTerminal = false
    when defined(posix):
      app.termMaster = pty.master; app.termPid = pty.pid.int  # so a hot reload can hand it off
    block:                                    # drain the live pane's pty each frame
      let ap = activePtyPtr()
      if ap != nil: pump(ap[])
    poll(ctrl, app)                           # handle any wkbctl / agent request

    if app.reloadPending:                     # recompile finished -> snapshot & re-exec
      if pty.vt != nil and pty.alive:
        try:
          writeFile(termGridPath, pty.vt.serialize())
          putEnv("WKB_TERMGRID", termGridPath)
        except CatchableError: discard
      execReload(app)                         # execv; only returns on failure
      app.reloadPending = false

    var consumed = false
    if app.diffActive and app.focus != "session":
      # The diff occupies the editor pane. Esc/q closes it; other editor-directed
      # keys are swallowed so the hidden buffer isn't edited. Mouse events pass
      # through (so you can click the session pane), and once focus is the
      # session, this is skipped -- you keep talking to the terminal/Claude.
      if e.kind == KeyDownEvent and e.key in {KeyEsc, KeyQ}: closeDiff(app)
      if e.kind in {KeyDownEvent, TextInputEvent}: consumed = true
    if not consumed and suppressText:
      suppressText = false
      if e.kind == TextInputEvent: consumed = true   # the char after e.g. "C-c e"
    if not consumed:
      if app.searchActive:
        handleSearch(app, e); consumed = true
      elif app.paletteActive:
        handlePalette(app, e); consumed = true
      elif app.completionActive:
        consumed = handleCompletion(app, e)
    # Tab on a #+begin_src line folds/unfolds the block instead of indenting.
    if not consumed and app.focus == "editor" and not app.completionActive and
       e.kind == KeyDownEvent and e.key == KeyTab and app.ed.lang == langOrg:
      let ln = strutils.strip(app.ed.getLineText(app.ed.currentLine)).toLowerAscii
      if ln.startsWith("#+begin_src"):
        toggleFold(app); consumed = true; suppressText = true

    if not consumed and not app.paletteActive and not app.searchActive:
      if dispatch(app, e):
        consumed = true
        # A command/prefix ran from this keystroke; swallow the TextInput it may
        # also emit (e.g. M-x -> 'x', C-c e -> 'e') so it isn't typed anywhere.
        if e.kind == KeyDownEvent: suppressText = true

    # Vim modal editing (after commands, so bound chords still work).
    if not consumed and app.vimEnabled and app.focus == "editor" and
       not app.paletteActive and not app.completionActive and not app.searchActive:
      consumed = vimHandle(app, e)

    # Session-focused input goes straight to the live pane's pty (the standalone
    # terminal, or the current REPL session -- both are a Pty).
    if not consumed and not app.paletteActive and not app.completionActive and
       not app.searchActive and app.focus == "session":
      let ap = activePtyPtr()
      if ap != nil and ap[].alive:
        consumed = feedTerminalKey(ap[], e)

    if e.kind in {MouseMoveEvent, MouseDownEvent, MouseUpEvent}:
      lastMouse = (e.x, e.y)   # live proof of pointer delivery (XWayland check)

    if app.fontSize != fontSize:                 # zoom: re-open the fonts
      fontSize = app.fontSize
      font = openFont(fontPath, fontSize, metrics)
      bigFont = openFont(fontPath, fontSize * 3 div 2, bigMetrics)
      boldFont = openFont(facePath("Bold"), fontSize, emMetrics)
      italicFont = openFont(facePath("Italic"), fontSize, emMetrics)
      boldItalicFont = openFont(facePath("BoldItalic"), fontSize, emMetrics)
      captionFont = openFont(fontPath, fontSize + 2, emMetrics)
      lineH = metrics.lineHeight
      app.font = font; app.bigFont = bigFont
      app.ed.setFont(font); app.sess.setFont(font)
      app.objects.setFont(font); app.help.setFont(font)
      app.ed.bigFont = bigFont; applyEmphasisFonts(app.ed)
      for b in app.buffers.mitems:
        b.ed.setFont(font); b.ed.bigFont = bigFont; applyEmphasisFonts(b.ed)

    screen = getWindowLayout()
    let lay = if app.srcEdit: laySrc
              elif (app.sessions.len > 0 or app.hasTerminal) and not app.sessionHidden: layPlain
              else: layBare
    let cells = resolve(lay, screen.width, screen.height, lineH)

    if e.kind == MouseDownEvent:          # click a pane to focus it
      for nm in ["editor", "session", "objects", "help"]:
        if cells.hasKey(nm):
          let r = cells[nm]
          if e.x >= r.x and e.x < r.x + r.w and e.y >= r.y and e.y < r.y + r.h:
            app.focus = nm
      # click on the session tab bar: [x] to hide, or a chip to select
      if cells.hasKey("session"):
        let r = cells["session"]
        if e.y >= r.y and e.y < r.y + lineH:
          if e.x >= r.x + r.w - lineH:          # [x] hide the panel
            app.sessionHidden = true; app.focus = "editor"
          else:
            var cx = r.x + 4
            for k in app.tabKeys():
              let w = tabWidth(app, k, lineH)
              if e.x >= cx and e.x < cx + w: selectTab(app, k); break
              cx += w + 4
    # Chrome colors from the active theme (re-read each frame so a palette
    # theme-switch takes effect immediately).
    let bg = app.theme.windowBg
    let sessBg = app.theme.panelBg
    let statusBg = app.theme.statusBg
    let statusFg = app.theme.statusFg
    fillRect(rect(0, 0, screen.width, screen.height), bg)

    var editorRect = rect(0, 0, screen.width, screen.height)
    # Route: a wheel goes to the pane under the pointer; other unconsumed input
    # goes to the focused pane. Everything else gets noEvent.
    # The completion popup is NON-MODAL: it floats over the editor but must not
    # block typing (you keep typing and it refines). Only the palette and search
    # minibuffers are true modal overlays that capture editor input.
    let overlay = app.paletteActive or app.searchActive
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

    if cells.hasKey("editor") and app.diffActive:
      # Two-pane diff, drawn INTO the editor cell (the session/terminal pane
      # below stays live so you can keep interacting). Removed lines red (left),
      # added green (right); wheel over it scrolls; Esc/q closes.
      let r = cells["editor"]
      editorRect = r
      let charW = max(1, measureText(app.font, "0").w)
      fillRect(r, bg)
      fillRect(rect(r.x, r.y, r.w, lineH), app.theme.tabBarBg)
      discard drawText(app.font, r.x + 6, r.y,
        "DIFF  " & app.diffTitle & "     Esc/q close · wheel scroll",
        app.theme.chipActiveFg, app.theme.tabBarBg)
      let bodyY = r.y + lineH
      let rows = max(1, (r.h - lineH) div lineH)
      if e.kind == MouseWheelEvent and lastMouse.x >= r.x and lastMouse.x < r.x + r.w and
         lastMouse.y >= r.y and lastMouse.y < r.y + r.h:
        app.diffScroll += e.y * 3
      let total = app.diffL.len
      app.diffScroll = max(0, min(app.diffScroll, max(0, total - rows)))
      let colW = (r.w - 4) div 2
      let leftX = r.x
      let rightX = r.x + colW + 4
      let redFg = app.theme.ed.fg[TokenClass.Red]
      let greenFg = app.theme.ed.fg[TokenClass.Green]
      let removedBg = blend(bg, redFg, 22)
      let addedBg = blend(bg, greenFg, 22)
      let gapBg = blend(bg, app.theme.dimFg, 12)
      fillRect(rect(r.x + colW + 1, bodyY, 2, r.h - lineH), app.theme.dividerColor)
      var y = bodyY
      for idx in app.diffScroll ..< min(total, app.diffScroll + rows):
        let lk = app.diffLK[idx]; let rk = app.diffRK[idx]
        let lbg = if lk == '-': removedBg elif rk == '+': gapBg else: bg
        let rbg = if rk == '+': addedBg elif lk == '-': gapBg else: bg
        let lfg = if lk == '-': redFg else: app.theme.ed.fg[TokenClass.None]
        let rfg = if rk == '+': greenFg else: app.theme.ed.fg[TokenClass.None]
        fillRect(rect(leftX, y, colW, lineH), lbg)
        fillRect(rect(rightX, y, r.x + r.w - rightX, lineH), rbg)
        discard drawText(app.font, leftX + 4, y,
          (if lk == '-': "- " else: "  ") & app.diffL[idx], lfg, lbg)
        discard drawText(app.font, rightX + 4, y,
          (if rk == '+': "+ " else: "  ") & app.diffR[idx], rfg, rbg)
        y += lineH
    elif cells.hasKey("editor"):
      editorRect = cells["editor"]
      let act = app.ed.draw(evFor("editor"), editorRect, focused = app.focus == "editor" and not overlay)
      if act.kind == ctrlClick:              # Ctrl+click an org link -> open it
        app.ed.gotoPos(act.pos)
        openLink(app)
      elif e.kind == MouseDownEvent and e.button == LeftButton and
           not overlay and app.focus == "editor" and app.ed.lang == langOrg and
           e.x >= editorRect.x and e.x < editorRect.x + editorRect.w and
           e.y >= editorRect.y and e.y < editorRect.y + editorRect.h and
           linkAtCursor(app).len > 0:
        openLink(app)              # plain click on an org link follows it
      # Always-on completion: after a printable edit reaches the editor, refresh
      # the suggestion popup (LSP languages only; no popup while overlays show).
      if not overlay and app.focus == "editor" and app.docLang.len > 0:
        # Refresh (or open) the popup after a typed char / backspace; autoComplete
        # closes itself when there's nothing to show, so no explicit dismiss.
        let edited =
          (e.kind == TextInputEvent and not consumed) or
          (e.kind == KeyDownEvent and e.key == KeyBackspace)
        if edited: autoComplete(app)
    if cells.hasKey("session"):
      let r = cells["session"]
      fillRect(r, sessBg)
      let bh = lineH                       # top row = session tab bar
      # tab bar: one chip per tab (sessions + the terminal), then an [x] to hide.
      fillRect(rect(r.x, r.y, r.w, bh), app.theme.tabBarBg)
      var cx = r.x + 4
      let curKey = app.currentTabKey()
      for k in app.tabKeys():
        let active = k == curKey
        let chipBg = if active: app.theme.chipActiveBg else: app.theme.chipBg
        let chipFg = if active: app.theme.chipActiveFg else: app.theme.chipFg
        let label = " " & tabLabel(app, k) & " "
        let w = tabWidth(app, k, lineH)
        fillRect(rect(cx, r.y, w, bh), chipBg)
        discard drawText(app.font, cx + 2, r.y, label, chipFg, chipBg)
        cx += w + 4
      let xr = rect(r.x + r.w - bh, r.y, bh, bh)   # [x] hide button
      fillRect(xr, app.theme.closeBg)
      discard drawText(app.font, xr.x + bh div 3, r.y, "x", app.theme.closeFg, app.theme.closeBg)
      let body = rect(r.x, r.y + bh, r.w, max(lineH, r.h - bh))
      let rows = max(1, body.h div lineH)
      let charW = max(1, measureText(app.font, "0").w)
      let ap = activePtyPtr()
      var visText: seq[string]     # text of each drawn body row (for select/copy)
      var copyNow = false
      block termSelect:            # drag to select, copy on release
        if ap == nil: break termSelect
        let inBody = lastMouse.x >= body.x and lastMouse.x < body.x + body.w and
                     lastMouse.y >= body.y and lastMouse.y < body.y + body.h
        let sr = max(0, (lastMouse.y - body.y) div lineH)
        let sc = max(0, (lastMouse.x - body.x) div charW)
        if e.kind == MouseDownEvent and e.button == LeftButton and inBody:
          selecting = true; selHas = false; selA = (sr, sc); selB = (sr, sc)
        elif e.kind == MouseMoveEvent and selecting:
          selB = (sr, sc)
        elif e.kind == MouseUpEvent and selecting:
          selecting = false; selHas = selA != selB; copyNow = selHas
      if ap != nil and ap[].vt != nil:
        # Standalone terminal: a full screen-grid emulator (cursor-addressed
        # TUIs like claude render here). Colored cell runs + block cursor.
        let vt = ap[].vt
        if ap[].alive: setPtySize(ap[], rows, max(1, body.w div charW))
        if termRepaintFrames > 0:          # post-reload: repaint once sized
          nudgeRepaint(ap[]); dec termRepaintFrames
        setVtColors(ap[], app.theme.termFg, app.theme.panelBg)
        # Wheel: on the primary screen scroll our own scrollback; on the alt
        # screen (TUIs) hand the wheel to the app -- as an encoded mouse event
        # if it asked for mouse reporting, else as arrow keys ("alt scroll").
        let overBody = lastMouse.x >= body.x and lastMouse.x < body.x + body.w and
                       lastMouse.y >= body.y and lastMouse.y < body.y + body.h
        if e.kind == MouseWheelEvent and overBody and ap[].alive:
          if vt.mouseRep:
            let btn = if e.y > 0: 64 else: 65      # 64 = wheel up, 65 = wheel down
            let col = max(1, (lastMouse.x - body.x) div charW + 1)
            let row = max(1, (lastMouse.y - body.y) div lineH + 1)
            let ev = if vt.mouseSgr: "\e[<" & $btn & ";" & $col & ";" & $row & "M"
                     else: "\e[M" & $chr(32 + btn) & $chr(32 + col) & $chr(32 + row)
            for _ in 0 ..< 3 * abs(e.y): feed(ap[], ev)
          elif vt.inAlt:
            let arrow = if e.y > 0: "\e[A" else: "\e[B"
            for _ in 0 ..< 3 * abs(e.y): feed(ap[], arrow)
          else:
            vt.scrollView(e.y * 3)
        let atTail = vt.viewOffset == 0
        for ry in 0 ..< vt.rows:
          let vrow = vt.viewRow(ry)
          var cxp = 0
          while cxp < vt.cols:                  # coalesce same-attribute cells
            let c0 = vrow[cxp]
            var run = ""
            var cxe = cxp
            while cxe < vt.cols:
              let c = vrow[cxe]
              if c.fg != c0.fg or c.bg != c0.bg or c.inv != c0.inv: break
              run.add (if c.ch.len == 0: " " else: c.ch)
              inc cxe
            let fg = if c0.inv: c0.bg else: c0.fg
            let bg = if c0.inv: c0.fg else: c0.bg
            discard drawText(app.font, body.x + cxp * charW, body.y + ry * lineH, run, fg, bg)
            cxp = cxe
          var rowStr = ""                       # full-width row text (for selection)
          for c in vrow: rowStr.add (if c.ch.len == 0: " " else: c.ch)
          visText.add rowStr
        if ap[].alive and atTail:               # block cursor (inverse cell)
          let cc = vt.grid[vt.cy][vt.cx]
          let cxr = body.x + vt.cx * charW
          let cyr = body.y + vt.cy * lineH
          fillRect(rect(cxr, cyr, charW, lineH), app.theme.termFg)
          discard drawText(app.font, cxr, cyr, (if cc.ch.len == 0: " " else: cc.ch),
                           app.theme.panelBg, app.theme.termFg)
        if vt.viewOffset > 0:                    # scrollback indicator
          discard drawText(app.font, body.x + body.w - 7 * charW, body.y,
            "[+" & $vt.viewOffset & "]", app.theme.dimFg, app.theme.panelBg)
        if not ap[].alive:
          discard drawText(app.font, body.x + 4, body.y + (vt.rows) * lineH,
            "[process ended -- Esc-hide, reopen with M-x terminal]", app.theme.dimFg, sessBg)
      elif ap != nil:
        # REPL session: the ANSI-stripped, marker-filtered line-log + scrollback.
        let all = termLines(ap[].outbuf)
        if ap[].alive: setPtySize(ap[], rows, max(1, body.w div charW))
        if e.kind == MouseWheelEvent and
           lastMouse.x >= body.x and lastMouse.x < body.x + body.w and
           lastMouse.y >= body.y and lastMouse.y < body.y + body.h:
          app.termScroll += e.y * 3
        let maxScroll = max(0, all.len - rows)
        app.termScroll = max(0, min(app.termScroll, maxScroll))
        let stop = all.len - app.termScroll     # exclusive; tail when scroll==0
        let start = max(0, stop - rows)
        var y = body.y
        for i in start ..< stop:
          discard drawText(app.font, body.x + 4, y, all[i], app.theme.termFg, sessBg)
          visText.add all[i]
          y += lineH
        if app.termScroll > 0:
          discard drawText(app.font, body.x + body.w - 6 * charW, body.y,
            "[+" & $app.termScroll & "]", app.theme.dimFg, sessBg)
        if not ap[].alive:
          discard drawText(app.font, body.x + 4, y, "[session ended]", app.theme.dimFg, sessBg)
      else:
        discard drawText(app.font, body.x + 4, body.y,
          "no session yet -- run a src block (C-c C-c) or M-x terminal",
          app.theme.dimFg, sessBg)
      # selection highlight + copy-on-release (over whichever content was drawn)
      if (selecting or selHas or copyNow) and visText.len > 0:
        var a = selA
        var b = selB
        if (a.r, a.c) > (b.r, b.c): swap a, b
        var txt = ""
        for row in a.r .. b.r:
          if row < 0 or row >= visText.len: continue
          let line = visText[row]
          let cS = (if row == a.r: min(a.c, line.len) else: 0)
          let cE = (if row == b.r: min(b.c, line.len) else: line.len)
          if cE > cS:
            let hx = body.x + cS * charW
            fillRect(rect(hx, body.y + row * lineH, (cE - cS) * charW, lineH), app.theme.ed.selBg)
            discard drawText(app.font, hx, body.y + row * lineH,
                             line[cS ..< cE], app.theme.termFg, app.theme.ed.selBg)
          if copyNow:
            txt.add line[cS ..< max(cS, cE)].strip(leading = false, trailing = true)
            if row < b.r: txt.add "\n"
        if copyNow and txt.len > 0:
          putClipboardText(txt); app.msg = "copied " & $txt.len & " chars"
    if cells.hasKey("objects"):
      fillRect(cells["objects"], sessBg)
      discard app.objects.draw(evFor("objects"), cells["objects"], focused = app.focus == "objects")
    if cells.hasKey("help"):
      fillRect(cells["help"], sessBg)
      discard app.help.draw(evFor("help"), cells["help"], focused = app.focus == "help")
    for dn in dividerNames:
      if cells.hasKey(dn): fillRect(cells[dn], app.theme.dividerColor)
    if cells.hasKey("status") and app.searchActive:
      drawSearch(app, cells["status"], lineH)
    elif cells.hasKey("status"):
      let sr = cells["status"]
      fillRect(sr, statusBg)
      let name = if app.filePath.len > 0: extractFilename(app.filePath) else: "*scratch*"
      let dirty = if app.ed.changed: " [+]" else: ""
      let vimTag =
        if not app.vimEnabled: ""
        elif app.vimMode == vmInsert: "-- INSERT --   "
        else: "-- NORMAL --   "
      discard drawText(app.font, sr.x + 6, sr.y,
        "  wkbenchless   " & vimTag & name & dirty & "   " &
        $(app.ed.currentLine + 1) & ":" & $(app.ed.currentCol + 1) &
        "   " & app.msg,
        statusFg, statusBg)

    if app.completionActive:
      drawCompletion(app, editorRect, lineH)
    if app.paletteActive:
      drawPalette(app, editorRect, lineH)

    refresh()

  closePty(pty)
  for s in app.sessions.values: closeSession(s)
  for c in app.lsp.values: shutdownLsp(c)
  closeFont(font)

when isMainModule:
  main()
