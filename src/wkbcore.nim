## wkbenchless core: the editor model that user config can touch DIRECTLY -- the point
## of the pure-Nim rewrite. There is no ABI boundary: the host (wkbenchless.nim) does
## rendering, the user config (wkbconfig.nim) imports this module and calls
## defcommand / bindkey / registerRepl / addHook against the exact same App and
## SynEdit types the host uses. Commands are Nim procs; keys and languages are
## data; hooks fire at editor events.

import uirelays
import vendor/synedit          # our patched copy of uirelays' SynEdit (adds langR/langOrg)
import wkbsession
import wkblsp                    # pure std/json LSP client -- portable, no GTK
import std/[tables, strutils, os, osproc, algorithm]
when defined(posix): import std/posix

export uirelays, synedit, wkbsession, wkblsp   # config sees Event/SynEdit/ReplSpec/LspClient/...
  # `synedit` above is src/vendor/synedit

type
  App* = object
    ed*, sess*, objects*, help*: SynEdit
    sessions*: Table[string, Session]     ## key: langId & "/" & sessionName
    curLang*, curSession*: string         ## the session objects/help track
    docLang*: string                      ## the buffer's LSP languageId ("" = none)
    lsp*: Table[string, LspClient]        ## langId -> language server
    font*: Font
    bigFont*: Font                        ## larger font for org headers/headings
    fontSize*: int                        ## desired editor font size (host applies)
    filePath*, msg*: string
    running*: bool
    srcEdit*: bool                        ## 4-quadrant (objects+help) vs plain
    pendingPrefix*: string
    buffers*: seq[BufferState]            ## all open buffers (snapshots)
    curBuf*: int                          ## index of the active buffer
    pendingKill*: bool                    ## a kill-buffer of a dirty buffer awaits confirm
    paletteActive*: bool
    paletteMode*: PaletteMode
    paletteQuery*: string
    paletteSel*: int
    paletteDir*: string                   ## current directory in pmFiles mode
    completionActive*: bool
    completionItems*: seq[string]
    completionSel*: int
    completionPrefix*: string
    focus*: string                        ## which pane gets keyboard events
    replInput*: string                    ## the session pane's live prompt line
    vimEnabled*: bool                     ## modal (vim) editing
    vimMode*: VimMode
    vimPending*: string                   ## pending operator/prefix (d, g, y)
    sessionHidden*: bool                  ## bottom panel hidden (x on the tab bar)
    termActive*: bool                     ## bottom panel shows the PTY terminal
    termRequest*: string                  ## command the host should run in the PTY
    # src-edit (org-edit-special / tangle): the buffer temporarily *becomes* the
    # extracted code; on exit it is spliced/detangled back into the org doc.
    editMode*: EditMode
    orgSaved*: seq[string]                ## the org document, by line
    orgFilePath*: string
    editRanges*: seq[tuple[a, b, indent: int]]  ## body ranges [a,b) in orgSaved
  Command* = object
    label*: string
    run*: proc(app: var App)
  Hook* = proc(app: var App)
  EditMode* = enum emNone, emBlock, emSession
  PaletteMode* = enum pmCommands, pmBuffers, pmFiles
  VimMode* = enum vmNormal, vmInsert
  BufferState* = object
    ed*: SynEdit
    filePath*, docLang*: string

var
  gCommands*: OrderedTable[string, Command]
  gKeymap*: Table[string, string]         ## chord (or "C-c C-c") -> command name
  gRepls*: Table[string, ReplSpec]        ## langId -> interpreter spec
  gHooks*: Table[string, seq[Hook]]       ## event name -> hooks
  gObjectsQuery*: Table[string, string]   ## langId -> code listing the env
  gHelpQuery*: Table[string, string]      ## langId -> code, {word} substituted
  gRebuildCmd*: string                    ## shell command C-c r runs to rebuild
  gLspServers*: Table[string, string]     ## langId -> server command (argv, space-split)

# -- registry (the config surface) -----------------------------------------
proc defcommand*(name, label: string; run: proc(app: var App)) =
  gCommands[name] = Command(label: label, run: run)
proc bindkey*(chord, name: string) = gKeymap[chord] = name
proc registerRepl*(langId: string; spec: ReplSpec) =
  gRepls[langId.toLowerAscii] = spec
proc addHook*(name: string; h: Hook) =
  gHooks.mgetOrPut(name, @[]).add h
proc runHooks*(app: var App; name: string) =
  if gHooks.hasKey(name):
    for h in gHooks[name]: h(app)

proc getSession*(app: var App; lang, name: string): Session =
  let key = lang.toLowerAscii & "/" & name
  if app.sessions.hasKey(key) and app.sessions[key] != nil:
    return app.sessions[key]
  if not gRepls.hasKey(lang.toLowerAscii): return nil
  let s = startSession(gRepls[lang.toLowerAscii])
  if s != nil: app.sessions[key] = s
  s

# -- keychords -------------------------------------------------------------
proc keyName*(k: KeyCode): string =
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
  else: ""

proc chordOf*(e: Event): string =
  if e.kind != KeyDownEvent: return ""
  let kn = keyName(e.key)
  if kn.len == 0: return ""
  if CtrlPressed in e.mods: result &= "C-"
  if AltPressed in e.mods: result &= "M-"
  if ShiftPressed in e.mods: result &= "S-"
  result &= kn

proc isPrefix*(chord: string): bool =
  for k in gKeymap.keys:
    if k.startsWith(chord & " "): return true

# -- buffers ---------------------------------------------------------------
proc bufName*(b: BufferState): string =
  if b.filePath.len > 0: extractFilename(b.filePath) else: "*scratch*"

proc extToLangId(ext: string): string =
  case ext.toLowerAscii
  of ".nim", ".nims": "nim"
  of ".py", ".pyw": "python"
  of ".r": "r"
  of ".c", ".h": "c"
  of ".cpp", ".cxx", ".hpp": "cpp"
  of ".js": "javascript"
  else: ""

proc syncActive*(app: var App) =
  ## Write the live active editor back into its buffer slot.
  if app.curBuf >= 0 and app.curBuf < app.buffers.len:
    app.buffers[app.curBuf] =
      BufferState(ed: app.ed, filePath: app.filePath, docLang: app.docLang)

proc activate(app: var App; idx: int) =
  let b = app.buffers[idx]
  app.ed = b.ed
  app.filePath = b.filePath
  app.docLang = b.docLang
  app.curBuf = idx

proc switchToBuffer*(app: var App; idx: int) =
  if idx < 0 or idx >= app.buffers.len or idx == app.curBuf: return
  app.syncActive()
  app.activate(idx)
  app.msg = "buffer: " & bufName(app.buffers[idx])

proc openFile*(app: var App; path: string) =
  for i, b in app.buffers:
    if b.filePath == path: switchToBuffer(app, i); return   # already open
  var ed = createSynEdit(app.font)
  ed.showLineNumbers = true
  ed.bigFont = app.bigFont
  ed.theme.fg[TokenClass.Link] = color(96, 160, 255)
  let ext = splitFile(path).ext
  ed.lang = fileExtToLanguage(ext)
  try: ed.loadFromFile(path)
  except CatchableError:
    app.msg = "could not open " & path; return
  app.syncActive()
  app.buffers.add BufferState(ed: ed, filePath: path, docLang: extToLangId(ext))
  app.activate(app.buffers.high)
  app.msg = "opened " & extractFilename(path)

# -- palette entries (commands / buffers / files) --------------------------
proc paletteEntries*(app: App): seq[tuple[id, label: string]] =
  let q = app.paletteQuery.toLowerAscii
  case app.paletteMode
  of pmCommands:
    for name, c in gCommands:
      if q.len == 0 or q in c.label.toLowerAscii: result.add (name, c.label)
  of pmBuffers:
    for i, b in app.buffers:
      let nm = bufName(b)
      if q.len == 0 or q in nm.toLowerAscii:
        let dirty = if b.ed.changed: " [+]" else: ""
        result.add ($i, nm & dirty & (if i == app.curBuf: "  (current)" else: ""))
  of pmFiles:
    result.add ("..", "../")
    var dirs, files: seq[tuple[id, label: string]]
    for kind, path in walkDir(app.paletteDir):
      let nm = extractFilename(path)
      if nm.startsWith("."): continue
      if q.len > 0 and q notin nm.toLowerAscii: continue
      if kind == pcDir: dirs.add (path, nm & "/")
      else: files.add (path, nm)
    dirs.sort(proc(a, b: (string, string)): int = cmp(a[1], b[1]))
    files.sort(proc(a, b: (string, string)): int = cmp(a[1], b[1]))
    result.add dirs; result.add files

# -- objects / help panes --------------------------------------------------
proc isWordChar(c: char): bool = c in {'a'..'z', 'A'..'Z', '0'..'9', '_', '.'}

proc wordAtCursor*(app: App): string =
  let line = app.ed.getLineText(app.ed.currentLine)
  if line.len == 0: return ""
  var a = min(app.ed.currentCol, line.len - 1)
  if not isWordChar(line[a]) and a > 0: dec a   # cursor just past a word
  if not isWordChar(line[a]): return ""
  var s = a
  while s > 0 and isWordChar(line[s - 1]): dec s
  var e = a
  while e + 1 < line.len and isWordChar(line[e + 1]): inc e
  line[s .. e]

proc cleanOverstrike(s: string): string =
  ## R's Rd2txt renders bold/underline as "X\bX" / "_\bX"; drop the first glyph
  ## and the backspace, keeping what follows.
  var i = 0
  while i < s.len:
    if i + 1 < s.len and s[i + 1] == '\b': i += 2
    else: result.add s[i]; inc i

proc refreshObjects*(app: var App) =
  let lang = (if app.curLang.len > 0: app.curLang else: "r").toLowerAscii
  if not gObjectsQuery.hasKey(lang):
    app.objects.setText("(no objects query for " & lang & ")"); return
  let s = getSession(app, lang, (if app.curSession.len > 0: app.curSession else: "default"))
  if s == nil: app.objects.setText("(no session)"); return
  let outp = s.runBlock(gObjectsQuery[lang])
  app.objects.setText("Objects [" & lang & "/" & app.curSession & "]\n" &
                      (if strutils.strip(outp).len > 0: outp else: "(none)"))

proc showHelp*(app: var App) =
  let w = wordAtCursor(app)
  if w.len == 0: app.msg = "no word at cursor"; return
  let lang = (if app.curLang.len > 0: app.curLang else: "r").toLowerAscii
  if not gHelpQuery.hasKey(lang):
    app.help.setText("(no help query for " & lang & ")"); return
  let s = getSession(app, lang, (if app.curSession.len > 0: app.curSession else: "default"))
  if s == nil: app.help.setText("(no session)"); return
  let outp = cleanOverstrike(s.runBlock(gHelpQuery[lang].replace("{word}", w)))
  app.help.setText("Help: " & w & "\n\n" & outp)
  app.msg = "help: " & w

# -- LSP completion --------------------------------------------------------
proc prefixBeforeCursor(app: App): string =
  let line = app.ed.getLineText(app.ed.currentLine)
  let upto = min(app.ed.currentCol, line.len)
  var s = upto
  while s > 0 and isWordChar(line[s - 1]): dec s
  line[s ..< upto]

proc getLspClient*(app: var App; lang: string): LspClient =
  let key = lang.toLowerAscii
  if app.lsp.hasKey(key) and app.lsp[key] != nil: return app.lsp[key]
  if not gLspServers.hasKey(key): return nil
  let root = if app.filePath.len > 0: parentDir(app.filePath) else: getCurrentDir()
  let c = startLsp(gLspServers[key], uriOf(root))
  if c != nil: app.lsp[key] = c
  c

proc lspComplete*(app: var App) =
  if app.docLang.len == 0:
    app.msg = "no LSP language (open a source file)"; return
  let c = getLspClient(app, app.docLang)
  if c == nil:
    app.msg = "no LSP server for " & app.docLang & " (not installed?)"; return
  let uri = if app.filePath.len > 0: uriOf(app.filePath) else: "file:///wkbenchless-scratch"
  c.syncDoc(uri, app.docLang, app.ed.fullText())
  let items = c.completion(uri, app.ed.currentLine, app.ed.currentCol)
  if items.len == 0: app.msg = "no completions"; return
  let pre = prefixBeforeCursor(app)
  var filtered: seq[string]
  for it in items:
    if pre.len == 0 or it.toLowerAscii.startsWith(pre.toLowerAscii): filtered.add it
  app.completionItems = if filtered.len > 0: filtered else: items
  app.completionPrefix = pre
  app.completionSel = 0
  app.completionActive = true
  app.msg = $app.completionItems.len & " completions"

proc completionAccept*(app: var App) =
  app.completionActive = false
  if app.completionSel < 0 or app.completionSel >= app.completionItems.len: return
  let label = app.completionItems[app.completionSel]
  for _ in 0 ..< app.completionPrefix.len: app.ed.backspace(false)
  app.ed.insertText(label)
  app.msg = "inserted " & label

# -- built-in commands -----------------------------------------------------
proc dedentBody(lines: seq[string]): string =
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

proc runLine*(app: var App) =
  let line = app.ed.getLineText(app.ed.currentLine)
  if strutils.strip(line).len == 0: return
  app.curLang = "r"; app.curSession = "default"
  let s = getSession(app, "r", "default")
  if s == nil: app.msg = "could not start R (on PATH?)"; return
  let outp = s.runBlock(line)
  app.sess.appendOutput("> " & line & "\n")
  if outp.len > 0: app.sess.appendOutput(outp & "\n")
  app.msg = "ran line"
  refreshObjects(app)

proc replSubmit*(app: var App) =
  ## Run the session pane's prompt line in the current session (the same one the
  ## blocks use, so state is shared) and echo the result.
  let line = app.replInput
  app.replInput = ""
  if strutils.strip(line).len == 0: return
  let lang = if app.curLang.len > 0: app.curLang else: "r"
  let s = getSession(app, lang, (if app.curSession.len > 0: app.curSession else: "default"))
  app.sess.appendOutput(lang & "> " & line & "\n")
  if s == nil: app.sess.appendOutput("(no " & lang & " session)\n"); return
  let outp = s.runBlock(line)
  if outp.len > 0: app.sess.appendOutput(outp & "\n")
  refreshObjects(app)

proc saveCmd*(app: var App) =
  if app.filePath.len > 0:
    app.ed.saveToFile(app.filePath); app.ed.markSaved()
    app.msg = "saved"
    app.runHooks("after-save")
  else: app.msg = "no file (pass a path on the command line)"

proc quitCmd*(app: var App) = app.running = false

proc zoomIn*(app: var App) =
  app.fontSize = min(48, app.fontSize + 1); app.msg = "font " & $app.fontSize
proc zoomOut*(app: var App) =
  app.fontSize = max(8, app.fontSize - 1); app.msg = "font " & $app.fontSize
proc zoomReset*(app: var App) =
  app.fontSize = 15; app.msg = "font " & $app.fontSize

proc openPalette(app: var App; mode: PaletteMode) =
  app.paletteMode = mode
  app.paletteActive = true
  app.paletteQuery = ""
  app.paletteSel = 0

proc paletteCmd*(app: var App) = openPalette(app, pmCommands)

proc listBuffers*(app: var App) =
  if app.editMode != emNone: app.msg = "exit src-edit first (C-c e)"; return
  app.syncActive()                       # reflect the live active buffer
  openPalette(app, pmBuffers)

proc openFileCmd*(app: var App) =
  if app.editMode != emNone: app.msg = "exit src-edit first (C-c e)"; return
  app.paletteDir = if app.filePath.len > 0: parentDir(app.filePath) else: getCurrentDir()
  openPalette(app, pmFiles)

proc orgLinkAt(line: string; col: int): string =
  ## The TARGET of the [[TARGET]] / [[TARGET][DESC]] link under `col`, or "".
  var i = 0
  while i < line.len - 1:
    if line[i] == '[' and line[i + 1] == '[':
      let start = i
      var j = i + 2
      while j < line.len - 1 and not (line[j] == ']' and line[j + 1] == ']'): inc j
      if j < line.len - 1:
        let endB = j + 1
        if col >= start and col <= endB:
          let inner = line[start + 2 ..< j]
          let sep = inner.find("][")
          return if sep >= 0: inner[0 ..< sep] else: inner
        i = endB + 1
        continue
    inc i

proc openLink*(app: var App) =
  ## Open the org link at the cursor with the system tool (browser / file
  ## manager / viewer), like Emacs org-open-at-point.
  let target = orgLinkAt(app.ed.getLineText(app.ed.currentLine), app.ed.currentCol)
  if target.len == 0: app.msg = "no link at cursor"; return
  var t = target
  if t.startsWith("file:"): t = t[5 .. ^1]
  if t.find("://") < 0 and not t.startsWith("mailto:") and
     not isAbsolute(t) and app.filePath.len > 0:
    t = parentDir(app.filePath) / t      # resolve relative file links
  when defined(windows):
    discard execShellCmd("start \"\" " & quoteShell(t))
  else:
    let opener = when defined(macosx): "open" else: "xdg-open"
    discard execShellCmd(opener & " " & quoteShell(t) & " &")
  app.msg = "opening " & target

proc killBuffer*(app: var App) =
  if app.editMode != emNone: app.msg = "exit src-edit first (C-c e)"; return
  if app.buffers.len <= 1: app.msg = "can't kill the last buffer"; return
  app.syncActive()
  if app.ed.changed and not app.pendingKill:   # guard unsaved work
    app.pendingKill = true
    app.msg = "unsaved -- kill-buffer again to discard, or C-s to save"
    return
  app.pendingKill = false
  let killed = bufName(app.buffers[app.curBuf])
  app.buffers.delete(app.curBuf)
  app.activate(max(0, app.curBuf - 1))
  app.msg = "killed " & killed

proc toggleSrcEdit*(app: var App) =
  ## Show/hide the objects+help right column (the "src-edit environment").
  app.srcEdit = not app.srcEdit
  if app.srcEdit: refreshObjects(app)
  app.msg = "src-edit: " & (if app.srcEdit: "on" else: "off")

# -- src-edit: org-edit-special + session tangle ---------------------------
proc commonIndent(lines: seq[string]): int =
  result = high(int)
  for ln in lines:
    if strutils.strip(ln).len == 0: continue
    var n = 0
    while n < ln.len and ln[n] in {' ', '\t'}: inc n
    result = min(result, n)
  if result == high(int): result = 0

proc langToExt(lang: string): string =
  case lang.toLowerAscii
  of "r": ".R"
  of "python": ".py"
  of "nim": ".nim"
  of "julia": ".jl"
  of "bash", "sh": ".sh"
  else: ".txt"

proc headerLangSession(header: string): (string, string) =
  let hdr = strutils.splitWhitespace(header)
  let lang = if hdr.len >= 2: hdr[1] else: ""
  var sess = "default"
  var k = 2
  while k < hdr.len:
    if hdr[k] == ":session" and k + 1 < hdr.len: sess = hdr[k + 1]
    inc k
  (lang, sess)

proc findBlockAt(app: App; cur: int): tuple[b, e: int; header: string] =
  result = (-1, -1, "")
  let total = app.ed.getLineCount()
  for i in countdown(cur, 0):
    let low = strutils.strip(app.ed.getLineText(i)).toLowerAscii
    if low.startsWith("#+begin_src"):
      result.b = i; result.header = strutils.strip(app.ed.getLineText(i)); break
    if low.startsWith("#+end_src") and i < cur: return
  if result.b < 0: return
  for i in result.b + 1 ..< total:
    if strutils.strip(app.ed.getLineText(i)).toLowerAscii.startsWith("#+end_src"):
      result.e = i; break
  if result.e < 0 or cur > result.e: result = (-1, -1, "")

const blockSentinel = "#--- wkbenchless block "

proc srcEditEnter(app: var App; sessionWide: bool) =
  let cb = findBlockAt(app, app.ed.currentLine)
  if cb.b < 0: app.msg = "not in a src block"; return
  let (lang, sess) = headerLangSession(cb.header)
  let total = app.ed.getLineCount()
  app.editRanges = @[]
  if not sessionWide:
    var body: seq[string]
    for i in cb.b + 1 ..< cb.e: body.add app.ed.getLineText(i)
    app.editRanges.add (a: cb.b + 1, b: cb.e, indent: commonIndent(body))
  else:
    var i = 0
    while i < total:
      if strutils.strip(app.ed.getLineText(i)).toLowerAscii.startsWith("#+begin_src"):
        let (l2, s2) = headerLangSession(strutils.strip(app.ed.getLineText(i)))
        var e2 = -1
        for j in i + 1 ..< total:
          if strutils.strip(app.ed.getLineText(j)).toLowerAscii.startsWith("#+end_src"):
            e2 = j; break
        if e2 < 0: break
        if l2.toLowerAscii == lang.toLowerAscii and s2 == sess:
          var body: seq[string]
          for k in i + 1 ..< e2: body.add app.ed.getLineText(k)
          app.editRanges.add (a: i + 1, b: e2, indent: commonIndent(body))
        i = e2 + 1
      else: inc i
  if app.editRanges.len == 0: app.msg = "no blocks for that session"; return

  app.orgSaved = @[]
  for i in 0 ..< total: app.orgSaved.add app.ed.getLineText(i)
  app.orgFilePath = app.filePath

  var tang: seq[string]
  for idx, r in app.editRanges:
    if sessionWide: tang.add blockSentinel & $idx & " ---"
    var body: seq[string]
    for i in r.a ..< r.b: body.add app.orgSaved[i]
    tang.add dedentBody(body)
  let text = tang.join("\n")

  let ext = langToExt(lang)
  let tmp = getTempDir() / ("wkbenchless-edit" & ext)
  try: writeFile(tmp, text) except CatchableError: discard
  app.filePath = tmp
  app.ed.lang = fileExtToLanguage(ext)   # before setText, so it highlights right
  app.ed.setText(text)
  app.docLang = lang.toLowerAscii
  app.curLang = lang.toLowerAscii; app.curSession = sess
  app.editMode = if sessionWide: emSession else: emBlock
  app.srcEdit = true
  refreshObjects(app)
  app.msg = (if sessionWide: "src-edit session '" & sess & "'" else: "src-edit block") &
            " (" & $app.editRanges.len & ")"

proc srcEditExit*(app: var App) =
  if app.editMode == emNone: return
  let edLines = app.ed.fullText().split('\n')
  var bodies: seq[seq[string]]
  if app.editMode == emBlock:
    bodies.add edLines
  else:
    var cur: seq[string]
    var started = false
    for ln in edLines:
      if strutils.strip(ln).startsWith(blockSentinel):
        if started: bodies.add cur
        cur = @[]; started = true
      elif started: cur.add ln
    if started: bodies.add cur
  # trim a trailing blank line off each body (fullText ends with \n)
  for b in bodies.mitems:
    while b.len > 0 and strutils.strip(b[^1]).len == 0: b.setLen(b.len - 1)

  var org = app.orgSaved
  for idx in countdown(app.editRanges.high, 0):
    if idx >= bodies.len: continue
    let r = app.editRanges[idx]
    var reindented: seq[string]
    for ln in bodies[idx]:
      reindented.add (if strutils.strip(ln).len == 0: "" else: spaces(r.indent) & ln)
    org[r.a ..< r.b] = reindented

  app.filePath = app.orgFilePath
  app.ed.lang = langOrg           # set lang BEFORE setText: setText highlights now
  app.ed.setText(org.join("\n"))
  app.docLang = ""
  app.editMode = emNone
  app.srcEdit = false
  app.editRanges = @[]
  app.msg = "src-edit: spliced back"

proc srcEditBlock*(app: var App) =
  if app.editMode != emNone: srcEditExit(app) else: srcEditEnter(app, false)
proc srcEditSession*(app: var App) =
  if app.editMode != emNone: srcEditExit(app) else: srcEditEnter(app, true)

proc sessionKeys*(app: App): seq[string] =
  for k in app.sessions.keys: result.add k
  sort(result)

proc switchSession*(app: var App) =
  ## Cycle the current session (the one the pane/objects/help track).
  let keys = app.sessionKeys()
  if keys.len == 0: app.msg = "no sessions yet"; return
  let curKey = app.curLang & "/" & app.curSession
  var i = -1
  for k, name in keys:
    if name == curKey: i = k
  let nk = keys[(i + 1) mod keys.len]
  let parts = nk.split('/')
  app.curLang = parts[0]
  app.curSession = if parts.len > 1: parts[1] else: "default"
  app.focus = "session"
  refreshObjects(app)
  app.msg = "session: " & nk

proc setSession*(app: var App; key: string) =
  ## Make `key` ("lang/name") the current session (e.g. clicking a session tab).
  let parts = key.split('/')
  app.curLang = parts[0]
  app.curSession = if parts.len > 1: parts[1] else: "default"
  app.focus = "session"
  refreshObjects(app)
  app.msg = "session: " & key

proc newTerminal*(app: var App) =
  ## Start (or reuse) a bash shell session and switch the pane to it.
  discard getSession(app, "bash", "term")
  app.curLang = "bash"; app.curSession = "term"
  app.focus = "session"
  app.sess.appendOutput("-- bash terminal --\n")
  app.msg = "terminal: bash/term"

proc focusNext*(app: var App) =
  const order = ["editor", "session", "objects", "help"]
  var i = 0
  for k, name in order:
    if name == app.focus: i = k
  app.focus = order[(i + 1) mod order.len]
  app.msg = "focus: " & app.focus

proc babelExecute*(app: var App) =
  let total = app.ed.getLineCount()
  let cur = app.ed.currentLine
  var b = -1
  var header = ""
  for i in countdown(cur, 0):
    let low = strutils.strip(app.ed.getLineText(i)).toLowerAscii
    if low.startsWith("#+begin_src"):
      b = i; header = strutils.strip(app.ed.getLineText(i)); break
    if low.startsWith("#+end_src") and i < cur: break
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
  app.curLang = lang; app.curSession = sessName
  let s = getSession(app, lang, sessName)
  if s == nil: app.msg = "no session for '" & lang & "'"; return
  let outp = s.runBlock(dedentBody(bodyLines))
  app.sess.appendOutput("# " & (if lang.len > 0: lang else: "?") &
                        " [" & sessName & "]\n" & outp & "\n")

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
  refreshObjects(app)
  app.runHooks("after-babel")

proc detectRebuildCmd*(): string =
  ## The command C-c r runs to rebuild wkbenchless. Prefer a toolchain bundled under
  ## <appdir>/toolchain so hot-reload needs no system compiler: a Nim under
  ## toolchain/nim/bin (it finds its own stdlib beside it) and, if present, zig
  ## as the hermetic C backend (single binary, ships its own libc, cross-
  ## compiles -- the user's pick over tcc). Falls back to the system `nim`.
  let base = "c --hints:off -o:wkbenchless src/wkbenchless.nim"
  let dir = getAppDir()
  let bnim = dir / "toolchain" / "nim" / "bin" / "nim"
  let bzig = dir / "toolchain" / "zig" / "zig"
  let nimExe = if fileExists(bnim): bnim.quoteShell else: "nim"
  if fileExists(bzig):
    let cc = (bzig & " cc").quoteShell     # Nim drives zig as a clang-alike
    result = nimExe & " " & "--cc:clang --clang.exe:" & cc &
             " --clang.linkerexe:" & cc & " " & base
  else:
    result = nimExe & " " & base

proc recompileConfig*(app: var App) =
  ## Hot-reload the config the honest way for compiled Nim (the xmonad model):
  ## rebuild the binary -- which recompiles wkbconfig.nim with it -- and, on
  ## success, re-exec ourselves, handing off the current file and cursor line.
  ## A compile error is shown in the session pane and nothing is replaced.
  when not defined(posix):
    app.msg = "recompile: only implemented on POSIX so far"
    return
  else:
    app.msg = "recompiling..."
    let dir = getAppDir()
    if gRebuildCmd.len == 0: gRebuildCmd = detectRebuildCmd()
    let (outp, code) = execCmdEx(gRebuildCmd, workingDir = dir)
    if code != 0:
      app.sess.appendOutput("-- recompile FAILED --\n$ " & gRebuildCmd & "\n" &
                            outp & "\n")
      app.msg = "recompile failed (see session pane)"
      return
    # persist the buffer so edits survive the exec
    var fileArg = app.filePath
    if fileArg.len == 0:
      fileArg = getTempDir() / "wkbenchless-scratch.txt"
      writeFile(fileArg, app.ed.fullText())
    elif app.ed.changed:
      app.ed.saveToFile(app.filePath); app.ed.markSaved()
    let line = app.ed.currentLine
    for s in app.sessions.values: closeSession(s)   # reap child REPLs first
    # Exec the freshly built binary by its known path, NOT getAppFilename():
    # the rebuild replaced our on-disk file, so /proc/self/exe now reads
    # ".../wkbenchless (deleted)", which would make execv fail with ENOENT. `dir` was
    # captured before the build, and the rebuild writes `-o:wkbenchless` into it.
    let bin = dir / "wkbenchless"
    if not fileExists(bin):
      app.msg = "recompile: built binary not found at " & bin; return
    let argv = allocCStringArray(@[bin, fileArg, "--goto", $line])
    discard execv(bin.cstring, argv)
    app.msg = "recompile: exec failed (" & bin & ")"   # only if execv failed

proc editConfig*(app: var App) =
  ## Open src/wkbconfig.nim in the editor (edit, then reload-config / C-c r).
  if app.editMode != emNone: app.msg = "exit src-edit first (C-c e)"; return
  let p = getAppDir() / "src" / "wkbconfig.nim"
  if not fileExists(p): app.msg = "config not found: " & p; return
  app.filePath = p
  app.ed.lang = fileExtToLanguage(".nim")
  app.ed.loadFromFile(p)
  app.docLang = "nim"
  app.msg = "editing config -- reload with C-c r (or M-x reload-config)"

proc reloadConfig*(app: var App) =
  ## Rebuild (recompiling wkbconfig.nim into the binary) and restart.
  recompileConfig(app)

# -- terminal / panel ------------------------------------------------------
proc openTerminal*(app: var App; cmd: string) =
  ## Ask the host to run `cmd` in the thread-free PTY terminal (bottom panel).
  app.termActive = true
  app.sessionHidden = false
  app.termRequest = cmd
  app.focus = "session"
  app.msg = "terminal: " & cmd

proc showPanel*(app: var App) =
  app.sessionHidden = false; app.focus = "session"; app.msg = "panel shown"

proc togglePanel*(app: var App) =
  app.sessionHidden = not app.sessionHidden
  if not app.sessionHidden: app.focus = "session"
  app.msg = "panel " & (if app.sessionHidden: "hidden" else: "shown")

# -- vim mode --------------------------------------------------------------
proc vimGoto(app: var App; line, col: int) =
  let ln = clamp(line, 0, max(0, app.ed.getLineCount() - 1))
  let ll = app.ed.getLineText(ln).len
  app.ed.gotoLine(ln, clamp(col, 0, ll))

proc vimMove(app: var App; dLine, dCol: int) =
  vimGoto(app, app.ed.currentLine + dLine, app.ed.currentCol + dCol)

proc vimFirstNonBlank(app: var App) =
  let line = app.ed.getLineText(app.ed.currentLine)
  var i = 0
  while i < line.len and line[i] in {' ', '\t'}: inc i
  vimGoto(app, app.ed.currentLine, i)

proc vimToEol(app: var App; append = false) =
  let ll = app.ed.getLineText(app.ed.currentLine).len
  vimGoto(app, app.ed.currentLine, if append: ll else: max(0, ll - 1))

proc isVimWord(c: char): bool = c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}

proc vimWordForward(app: var App) =
  let line = app.ed.getLineText(app.ed.currentLine)
  var i = app.ed.currentCol
  if i < line.len and isVimWord(line[i]):
    while i < line.len and isVimWord(line[i]): inc i
  while i < line.len and line[i] in {' ', '\t'}: inc i
  if i >= line.len and app.ed.currentLine < app.ed.getLineCount() - 1:
    vimGoto(app, app.ed.currentLine + 1, 0)
  else:
    vimGoto(app, app.ed.currentLine, i)

proc vimWordBackward(app: var App) =
  let line = app.ed.getLineText(app.ed.currentLine)
  var i = app.ed.currentCol - 1
  while i > 0 and line[i] in {' ', '\t'}: dec i
  while i > 0 and isVimWord(line[i - 1]): dec i
  vimGoto(app, app.ed.currentLine, max(0, i))

proc vimDeleteN(app: var App; n: int) =
  for _ in 0 ..< max(0, n): app.ed.deleteKey()

proc vimDeleteToEol(app: var App) =
  vimDeleteN(app, app.ed.getLineText(app.ed.currentLine).len - app.ed.currentCol)

proc vimDeleteWord(app: var App) =
  let line = app.ed.getLineText(app.ed.currentLine)
  var i = app.ed.currentCol
  if i < line.len and isVimWord(line[i]):
    while i < line.len and isVimWord(line[i]): inc i
  while i < line.len and line[i] in {' ', '\t'}: inc i
  vimDeleteN(app, i - app.ed.currentCol)

proc vimYankLine(app: var App) =
  putClipboardText(app.ed.getLineText(app.ed.currentLine) & "\n")

proc vimNormalChar(app: var App; c: char) =
  case app.vimPending
  of "d":
    app.vimPending = ""
    case c
    of 'd': vimYankLine(app); app.ed.deleteLine()
    of 'w': vimDeleteWord(app)
    of '$': vimDeleteToEol(app)
    else: discard
    return
  of "g":
    app.vimPending = ""
    if c == 'g': vimGoto(app, 0, 0)
    return
  of "y":
    app.vimPending = ""
    if c == 'y': vimYankLine(app)
    return
  else: discard
  case c
  of 'h': vimMove(app, 0, -1)
  of 'l': vimMove(app, 0, 1)
  of 'j': vimMove(app, 1, 0)
  of 'k': vimMove(app, -1, 0)
  of 'w': vimWordForward(app)
  of 'b': vimWordBackward(app)
  of '0': vimGoto(app, app.ed.currentLine, 0)
  of '$': vimToEol(app)
  of '^': vimFirstNonBlank(app)
  of 'G': vimGoto(app, app.ed.getLineCount() - 1, 0)
  of 'g': app.vimPending = "g"
  of 'd': app.vimPending = "d"
  of 'y': app.vimPending = "y"
  of 'D': vimDeleteToEol(app)
  of 'x': app.ed.deleteKey()
  of 'i': app.vimMode = vmInsert
  of 'I': vimFirstNonBlank(app); app.vimMode = vmInsert
  of 'a': vimMove(app, 0, 1); app.vimMode = vmInsert
  of 'A': vimToEol(app, append = true); app.vimMode = vmInsert
  of 'o': app.ed.insertLineBelow(); app.vimMode = vmInsert
  of 'O': app.ed.insertLineAbove(); app.vimMode = vmInsert
  of 'u': app.ed.undo()
  of 'p': app.ed.insertText(getClipboardText())
  else: discard

proc vimHandle*(app: var App; e: Event): bool =
  ## True if consumed. Insert mode consumes only Esc (typing flows to the
  ## editor); normal mode consumes everything.
  if app.vimMode == vmInsert:
    if e.kind == KeyDownEvent and e.key == KeyEsc:
      app.vimMode = vmNormal
      vimGoto(app, app.ed.currentLine, max(0, app.ed.currentCol - 1))
      return true
    return false
  case e.kind
  of TextInputEvent:
    var c = '\0'
    for ch in e.text:
      if ch != '\0': c = ch; break
    if c != '\0': vimNormalChar(app, c)
    return true
  of KeyDownEvent:
    case e.key
    of KeyEsc: app.vimPending = ""
    of KeyLeft: vimMove(app, 0, -1)
    of KeyRight: vimMove(app, 0, 1)
    of KeyUp: vimMove(app, -1, 0)
    of KeyDown, KeyEnter: vimMove(app, 1, 0)
    of KeyBackspace: vimMove(app, 0, -1)
    of KeyR:
      if CtrlPressed in e.mods: app.ed.redo()
    else: discard
    return true
  else: return false

proc toggleVim*(app: var App) =
  app.vimEnabled = not app.vimEnabled
  app.vimMode = vmNormal
  app.vimPending = ""
  app.msg = "vim mode " & (if app.vimEnabled: "on (NORMAL)" else: "off")

proc registerBuiltins*() =
  gRepls["r"] = rSpec
  gRepls["python"] = pySpec
  gRepls["bash"] = bashSpec
  gRebuildCmd = detectRebuildCmd()   # config may override before first C-c r

  gLspServers["nim"] = "nimlangserver"
  gLspServers["python"] = "pylsp"
  gLspServers["r"] = "R --no-echo -e languageserver::run()"
  gObjectsQuery["bash"] = "compgen -v | sort | head -60\n"

  gObjectsQuery["r"] =
    "local({ ns <- ls(envir=.GlobalEnv); " &
    "if (length(ns)==0) cat('(none)\\n') else " &
    "for (n in ns) cat(n, '  <', paste(class(get(n, envir=.GlobalEnv)), collapse=','), '>\\n', sep='') })\n"
  gObjectsQuery["python"] =
    "print('\\n'.join(f'{k}  <{type(v).__name__}>' " &
    "for k,v in list(globals().items()) if not k.startswith('_')) or '(none)')\n"

  gHelpQuery["r"] =
    "local({ h <- tryCatch(utils:::.getHelpFile(as.character(help('{word}'))), " &
    "error=function(e) NULL); if (is.null(h)) cat('no help for {word}\\n') else tools::Rd2txt(h) })\n"
  gHelpQuery["python"] =
    "import pydoc as _pd\n" &
    "try:\n    print(_pd.render_doc('{word}', renderer=_pd.plaintext))\n" &
    "except Exception as _e:\n    print('no help for {word}:', _e)\n"

  defcommand("save", "Save", saveCmd)
  defcommand("quit", "Quit", quitCmd)
  defcommand("run-line", "Run current line in session", runLine)
  defcommand("babel-execute", "Org-babel: run this src block", babelExecute)
  defcommand("comment-toggle", "Comment: toggle line", proc(app: var App) = app.ed.toggleComment())
  defcommand("undo", "Undo", proc(app: var App) = app.ed.undo())
  defcommand("redo", "Redo", proc(app: var App) = app.ed.redo())
  defcommand("palette", "Command palette", paletteCmd)
  defcommand("list-buffers", "List / switch buffers", listBuffers)
  defcommand("open-file", "Open file (browse)", openFileCmd)
  defcommand("kill-buffer", "Kill the current buffer", killBuffer)
  defcommand("zoom-in", "Increase font size", zoomIn)
  defcommand("zoom-out", "Decrease font size", zoomOut)
  defcommand("zoom-reset", "Reset font size", zoomReset)
  defcommand("open-link", "Open org link at cursor", openLink)
  defcommand("toggle-vim", "Toggle vim (modal) editing", toggleVim)
  defcommand("terminal", "Open a bash terminal in the bottom panel",
             proc(app: var App) = openTerminal(app, "bash --norc"))
  defcommand("claude", "Open claude in the bottom panel (best-effort)",
             proc(app: var App) = openTerminal(app, "claude"))
  defcommand("show-panel", "Show the bottom panel", showPanel)
  defcommand("toggle-panel", "Show/hide the bottom panel", togglePanel)
  defcommand("recompile", "Recompile config & restart", recompileConfig)
  defcommand("refresh-objects", "Objects: refresh from session", refreshObjects)
  defcommand("show-help", "Help: for word at cursor", showHelp)
  defcommand("complete", "LSP: complete at cursor", lspComplete)
  defcommand("toggle-src-edit", "Toggle objects/help (src-edit)", toggleSrcEdit)
  defcommand("src-edit-block", "Src-edit: this block (org-edit-special)", srcEditBlock)
  defcommand("src-edit-session", "Src-edit: tangle this session's blocks", srcEditSession)
  defcommand("focus-next", "Focus next pane", focusNext)
  defcommand("switch-session", "Switch to next session", switchSession)
  defcommand("new-terminal", "New bash terminal session", newTerminal)
  defcommand("edit-config", "Edit config file", editConfig)
  defcommand("reload-config", "Reload config (recompile & restart)", reloadConfig)
  # The full keymap lives in wkbconfig.nim so every binding is visible and
  # editable in one place (M-x edit-config, then C-c r). These two are a
  # recovery net kept here: a config that removes its binds can still open the
  # palette (and from there reload-config/edit-config) and quit.
  bindkey("M-x", "palette")
  bindkey("C-q", "quit")
