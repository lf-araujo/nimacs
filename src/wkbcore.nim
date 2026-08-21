## wkbenchless core: the editor model that user config can touch DIRECTLY -- the point
## of the pure-Nim rewrite. There is no ABI boundary: the host (wkbenchless.nim) does
## rendering, the user config (wkbconfig.nim) imports this module and calls
## defcommand / bindkey / registerRepl / addHook against the exact same App and
## SynEdit types the host uses. Commands are Nim procs; keys and languages are
## data; hooks fire at editor events.

import uirelays              # vendored: src/vendor/uirelays (see config.nims path)
import widgets/synedit          # our patched SynEdit (langR/langOrg, inline images)
import wkbsession
import wkblsp                    # pure std/json LSP client -- portable, no GTK
import std/[tables, strutils, os, osproc, algorithm, times]
when defined(posix): import std/posix

export uirelays, synedit, wkbsession, wkblsp   # config sees Event/SynEdit/ReplSpec/LspClient/...
  # uirelays + `synedit` above come from the vendored tree in src/vendor/uirelays

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
    searchActive*: bool                   ## find / find-replace minibuffer shown
    searchMode*: SearchMode
    searchField*: SearchField             ## which minibuffer field is being edited
    searchQuery*: string                  ## the needle
    searchReplace*: string                ## replacement text (smReplace)
    searchMatches*: seq[int]              ## buffer offsets of every match
    searchIdx*: int                       ## index into searchMatches (current)
    searchCase*: bool                     ## case-sensitive matching
    focus*: string                        ## which pane gets keyboard events
    theme*: AppTheme                      ## active theme (chrome + editor)
    themeIdx*: int                        ## index into gThemes
    vimEnabled*: bool                     ## modal (vim) editing
    vimMode*: VimMode
    vimPending*: string                   ## pending operator/prefix (d, g, y)
    sessionHidden*: bool                  ## bottom panel hidden (x on the tab bar)
    termActive*: bool                     ## the standalone terminal is the current tab
    termRequest*: string                  ## command the host should run in the PTY
    hasTerminal*: bool                    ## a standalone terminal tab exists (alive)
    termLabel*: string                    ## its tab label ("claude", "bash", ...)
    termScroll*: int                      ## bottom-pane scrollback: lines up from tail
    termMaster*: cint                     ## host keeps this synced with the terminal pty
    termPid*: int                         ## (so a hot reload can hand the terminal off)
    reloadPending*: bool                  ## recompile done -> host snapshots + re-execs
    reloadBin*, reloadFile*: string       ## the freshly built binary + file to reopen
    reloadLine*: int                      ## cursor line to restore
    # two-pane diff view (Claude/agents push a before/after via wkbctl)
    diffActive*: bool
    diffTitle*: string
    diffL*, diffR*: seq[string]           ## aligned old / new lines
    diffLK*, diffRK*: seq[char]           ## per row: ' ' same, '-' removed, '+' added
    diffScroll*: int
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
  PaletteMode* = enum pmCommands, pmBuffers, pmFiles, pmThemes, pmOrg, pmRecent
  SearchMode* = enum smFind, smReplace
  SearchField* = enum sfQuery, sfReplace
  VimMode* = enum vmNormal, vmInsert
  BufferState* = object
    ed*: SynEdit
    filePath*, docLang*: string
  Base16* = array[16, Color]   ## base00..base0F, a standard base16 palette
  AppTheme* = object
    ## One theme drives BOTH the editor buffers (`ed`: a SynEdit Theme) and the
    ## host chrome (panels, status bar, tabs, terminal, palette). Built from a
    ## base16 palette by `base16Theme`, or hand-tuned in the config.
    name*: string
    ed*: Theme                 ## editor/buffer colors (synedit)
    srcBlockBg*: Color         ## org src-block shading in the editor
    windowBg*, panelBg*, tabBarBg*: Color
    statusBg*, statusFg*: Color
    chipBg*, chipFg*, chipActiveBg*, chipActiveFg*: Color
    termFg*, dimFg*, dividerColor*: Color
    boxBg*, boxSelBg*, boxFg*: Color        ## palette / completion popups
    closeBg*, closeFg*: Color               ## the [x] hide button

var
  gCommands*: OrderedTable[string, Command]
  gKeymap*: Table[string, string]         ## chord (or "C-c C-c") -> command name
  gRepls*: Table[string, ReplSpec]        ## langId -> interpreter spec
  gHooks*: Table[string, seq[Hook]]       ## event name -> hooks
  gObjectsQuery*: Table[string, string]   ## langId -> code listing the env
  gHelpQuery*: Table[string, string]      ## langId -> code, {word} substituted
  gRebuildCmd*: string                    ## shell command C-c r runs to rebuild
  gLspServers*: Table[string, string]     ## langId -> server command (argv, space-split)
  gThemes*: seq[AppTheme]                 ## themes the config registers (palette picks one)
  gExtraPaths*: seq[string]               ## dirs to prepend to PATH (config; ~ ok)
  gLoadLoginPath* = true                  ## seed PATH from the login shell at startup
  gClaudeCmd* = "claude --continue || claude"  ## command the `claude` action runs (config)
  gSshPersist* = "600"                    ## seconds an ssh master connection persists
  gInlineImageWidth* = 0                   ## default inline image width in px
                                           ## (org #+ATTR_* :width overrides it);
                                           ## 0 = use each image's native size
  gLatexDpi* = 140                         ## dvipng resolution for M-x latex-preview
                                           ## math images (higher = larger/crisper)

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

proc addExecPath*(dir: string) =
  ## Config helper: add a directory to PATH for sessions/terminals (~ expanded).
  gExtraPaths.add dir

proc setupExecPath*() =
  ## Make the login shell's PATH (plus gExtraPaths) the process PATH, so
  ## sessions, terminals, and findExe locate the user's executables even when
  ## wkbenchless was launched from a GUI with a stripped-down environment.
  ## Called once at startup, after configure() so gExtraPaths is set, before any
  ## session or terminal spawns. Order: extra paths first (highest priority),
  ## then the login shell's PATH, then whatever we already inherited.
  var parts: seq[string]
  proc addDir(d: string) =
    let e = (if d.startsWith("~"): expandTilde(d) else: d)
    if e.len > 0 and e notin parts: parts.add e
  for p in gExtraPaths: addDir(p)
  if gLoadLoginPath:
    let sh = getEnv("SHELL", "/bin/bash")
    try:
      let (outp, code) = execCmdEx(sh & " -lc 'printf %s \"$PATH\"'")
      if code == 0:
        for p in outp.strip.split(':'): addDir(p)
    except CatchableError: discard
  for p in getEnv("PATH").split(':'): addDir(p)
  if parts.len > 0: putEnv("PATH", parts.join(":"))

# -- themes: a base16 palette -> full editor + chrome theme ------------------
proc rgb*(hex: int): Color =
  ## 0xRRGGBB -> Color, so a config spells a palette the way base16 files do.
  color(uint8((hex shr 16) and 0xFF), uint8((hex shr 8) and 0xFF), uint8(hex and 0xFF))

proc nudged(c: Color; d: int): Color =
  ## Shift each channel toward the middle by `d` (for the src-block lift).
  proc n(v: int): uint8 = uint8(if v < 128: min(255, v + d) else: max(0, v - d))
  color(n(c.r.int), n(c.g.int), n(c.b.int))

proc base16Theme*(name: string; b: Base16): AppTheme =
  ## Derive a full theme from base16 slots using the standard styling guide:
  ## base00 bg .. base05 default fg; base08..0F the accent colors.
  result.name = name
  var t = default(Theme)
  for tc in low(TokenClass)..high(TokenClass): t.fg[tc] = b[0x5]   # default text
  t.fg[TokenClass.Keyword] = b[0xE]
  t.fg[TokenClass.Preprocessor] = b[0xE]
  t.fg[TokenClass.Directive] = b[0xC]
  t.fg[TokenClass.Comment] = b[0x3]
  t.fg[TokenClass.LongComment] = b[0x3]
  t.fg[TokenClass.MarkdownFence] = b[0x3]
  for tc in [TokenClass.StringLit, TokenClass.LongStringLit, TokenClass.CharLit,
             TokenClass.RawData, TokenClass.Backticks, TokenClass.Key]:
    t.fg[tc] = b[0xB]                                              # strings: green
  for tc in [TokenClass.DecNumber, TokenClass.BinNumber, TokenClass.HexNumber,
             TokenClass.OctNumber, TokenClass.FloatNumber, TokenClass.Value,
             TokenClass.Label, TokenClass.Reference]:
    t.fg[tc] = b[0x9]                                              # numbers: orange
  t.fg[TokenClass.EscapeSequence] = b[0xC]
  t.fg[TokenClass.RegularExpression] = b[0xC]
  t.fg[TokenClass.Link] = b[0xD]
  t.fg[TokenClass.Command] = b[0xD]     # function names / calls: blue
  t.fg[TokenClass.Rule] = b[0xA]
  for tc in [TokenClass.TagStart, TokenClass.TagStandalone, TokenClass.TagEnd,
             TokenClass.Assembler]:
    t.fg[tc] = b[0xA]
  t.fg[TokenClass.Green] = b[0xB]
  t.fg[TokenClass.Yellow] = b[0xA]
  t.fg[TokenClass.Red] = b[0x8]
  t.bg = b[0x0]
  t.selBg = b[0x2]
  t.bracketBg = b[0x3]
  t.cursorColor = b[0xD]
  t.lineNumColor = b[0x3]
  t.markerBg = b[0x2]
  t.scrollBarColor = b[0x2]
  t.scrollBarActiveColor = b[0x3]
  t.scrollTrackColor = b[0x1]
  t.activeLineBg = b[0x1]
  t.actionColor = b[0x2]
  t.closeColor = b[0xD]
  result.ed = t
  result.srcBlockBg = nudged(b[0x0], 8)
  # host chrome
  result.windowBg = b[0x0]; result.panelBg = b[0x0]; result.tabBarBg = b[0x1]
  result.statusBg = b[0x1]; result.statusFg = b[0x4]
  result.chipBg = b[0x1]; result.chipFg = b[0x5]
  result.chipActiveBg = b[0x2]; result.chipActiveFg = b[0xA]
  result.termFg = b[0x5]; result.dimFg = b[0x3]; result.dividerColor = b[0x2]
  result.boxBg = b[0x1]; result.boxSelBg = b[0x2]; result.boxFg = b[0x5]
  result.closeBg = b[0x8]; result.closeFg = b[0x0]

proc registerTheme*(name: string; palette: Base16) =
  ## Register a base16 theme (the config surface). First registered = default.
  gThemes.add base16Theme(name, palette)
proc registerTheme*(t: AppTheme) = gThemes.add t   # a fully hand-tuned theme

proc applyTheme*(app: var App; idx: int) =
  ## Point every editor + the chrome at gThemes[idx].
  if idx < 0 or idx >= gThemes.len: return
  app.themeIdx = idx
  app.theme = gThemes[idx]
  let t = app.theme
  template paint(e: untyped) =
    e.theme = t.ed
    e.srcBlockBg = t.srcBlockBg
  paint(app.ed); paint(app.sess); paint(app.objects); paint(app.help)
  for b in app.buffers.mitems: paint(b.ed)
  app.msg = "theme: " & t.name

proc applyThemeByName*(app: var App; name: string) =
  for i in 0 ..< gThemes.len:
    if gThemes[i].name == name: applyTheme(app, i); return

proc defaultBase16*(): Base16 =
  ## A built-in dark palette (One-Dark-ish) so the app is never unstyled even
  ## if the config registers no theme. The config normally overrides this.
  [ rgb(0x15171b), rgb(0x20242d), rgb(0x2e3440), rgb(0x545b6b),
    rgb(0xa0a6b0), rgb(0xc8ccd4), rgb(0xe0e3e8), rgb(0xf0f2f5),
    rgb(0xe06c75), rgb(0xd19a66), rgb(0xe5c07b), rgb(0x98c379),
    rgb(0x56b6c2), rgb(0x61afef), rgb(0xc678dd), rgb(0xbe5046) ]

# -- persisted UI state (XDG config dir; e.g. ~/.config/wkbenchless/state.cfg) --
var gState*: Table[string, string]

proc stateDir*(): string = getConfigDir() / "wkbenchless"
proc statePath*(): string = stateDir() / "state.cfg"

proc loadState*() =
  gState.clear()
  let p = statePath()
  if fileExists(p):
    for line in readFile(p).splitLines():
      let eq = line.find('=')
      if eq > 0: gState[strutils.strip(line[0 ..< eq])] = strutils.strip(line[eq + 1 .. ^1])

proc setState*(key, val: string) =
  ## Remember a key and write the state file (created under the XDG config dir).
  gState[key] = val
  try:
    createDir(stateDir())
    var s = ""
    for k, v in gState: s.add k & " = " & v & "\n"
    writeFile(statePath(), s)
  except CatchableError: discard

proc sshControlPath*(): string =
  ## A per-user/host/port master socket shared by the interactive login and the
  ## marker sessions, so a password host is authenticated ONCE.
  getHomeDir() / ".ssh" / "wkb-cm-%C"

proc remoteSpec(base: ReplSpec; host: string; dir = ""): ReplSpec =
  ## Wrap a REPL spec to run on `host` over ssh, so an org block executes on a
  ## remote machine and its output is captured the same way. `ssh -tt` forces a
  ## remote pty; the spec's env (PS1=, PYTHON_BASIC_REPL=1) is set remotely via
  ## `env`; ControlPath reuses an already-authenticated master (no password
  ## prompt). `dir` (if given) is the remote working directory (cd + exec).
  result = base
  let ctrl = @["ssh", "-tt",
               "-o", "ControlPath=" & sshControlPath(),
               "-o", "ControlMaster=auto",
               "-o", "ControlPersist=" & gSshPersist, host]
  var remote: seq[string]
  if base.env.len > 0:
    remote.add "env"
    for (k, v) in base.env: remote.add k & "=" & v
  remote.add base.argv
  if dir.len > 0:
    var cmd = "cd " & quoteShell(dir) & " && exec"
    for a in remote: cmd.add " " & quoteShell(a)
    result.argv = ctrl & @["sh", "-c", cmd]
  else:
    result.argv = ctrl & remote
  result.env = @[]           # applied remotely via `env` above, not locally

proc getSession*(app: var App; lang, name: string; dir = ""): Session =
  ## A session named "name@host" runs on `host` over ssh (remote REPL, in `dir`
  ## if given); a plain name runs locally. `dir` is used only when creating.
  let key = lang.toLowerAscii & "/" & name
  if app.sessions.hasKey(key) and app.sessions[key] != nil:
    return app.sessions[key]
  if not gRepls.hasKey(lang.toLowerAscii): return nil
  let base = gRepls[lang.toLowerAscii]
  let at = name.rfind('@')
  let spec = if at >= 0 and at < name.len - 1: remoteSpec(base, name[at + 1 .. ^1], dir)
             else: base
  let s = startSession(spec)
  if s != nil: app.sessions[key] = s
  s

const headerArgKeys = ["session", "dir", "results", "exports", "tangle", "eval",
  "var", "cache", "noweb", "comments", "padline", "hlines", "colnames",
  "rownames", "wrap", "file", "output-dir", "mkdirp", "ssh"]

proc parseSshDir*(v: string): tuple[host, path: string] =
  ## `/ssh:user@host:/path` -> (user@host, /path); a plain path -> ("", path).
  if v.startsWith("/ssh:"):
    let d = v[5 .. ^1]
    let c = d.find(':')
    if c >= 0: (d[0 ..< c], d[c + 1 .. ^1]) else: (d, "")
  else: ("", v)

proc headerArgTokens*(app: App; lang: string): seq[string] =
  ## Default header args for `lang` from `#+PROPERTY: header-args[:LANG| LANG] ...`
  ## lines (both "header-args:R" and the "header-args R" spacing are accepted;
  ## all-language props first, language-specific appended so they win).
  var allLang, langSpec: seq[string]
  for i in 0 ..< app.ed.getLineCount():
    let ln = strutils.strip(app.ed.getLineText(i))
    if not ln.toLowerAscii.startsWith("#+property:"): continue
    var rest = strutils.strip(ln[ln.find(':') + 1 .. ^1])
    if not rest.toLowerAscii.startsWith("header-args"): continue
    rest = strutils.strip(rest["header-args".len .. ^1])
    let toks = strutils.splitWhitespace(rest)
    if toks.len == 0: continue
    var propLang = ""
    var start = 0
    let key0 = toks[0].strip(chars = {':'}).toLowerAscii
    if not (toks[0].startsWith(":") and key0 in headerArgKeys):
      propLang = key0; start = 1                 # a language token (":R" or "R")
    if propLang.len == 0: allLang.add toks[start .. ^1]
    elif propLang == lang.toLowerAscii: langSpec.add toks[start .. ^1]
  allLang & langSpec

proc currentSession*(app: var App): Session =
  ## The session the bottom pane tracks as a live terminal, or nil.
  let key = app.curLang.toLowerAscii & "/" & app.curSession   # keys use lower-lang
  if app.sessions.hasKey(key): app.sessions[key] else: nil

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

proc recentFilesPath(): string = getCacheDir() / "wkbenchless" / "recent"

proc loadRecentFiles*(): seq[string] =
  try:
    for line in lines(recentFilesPath()):
      let p = strutils.strip(line)
      if p.len > 0 and fileExists(p): result.add p
  except CatchableError: discard

proc noteRecentFile*(path: string) =
  if path.len == 0: return
  let abs = try: absolutePath(path) except CatchableError: path
  var recent = loadRecentFiles()
  recent.insert(abs, 0)
  var seen: seq[string]
  for p in recent:
    if p notin seen: seen.add p
    if seen.len >= 30: break
  try:
    createDir(recentFilesPath().parentDir)
    writeFile(recentFilesPath(), seen.join("\n"))
  except CatchableError: discard

proc openFile*(app: var App; path: string) =
  noteRecentFile(path)
  for i, b in app.buffers:
    if b.filePath == path: switchToBuffer(app, i); return   # already open
  var ed = createSynEdit(app.font)
  ed.showLineNumbers = true
  ed.bigFont = app.bigFont
  ed.setEmphasisFonts(app.ed.boldFont, app.ed.italicFont,
                      app.ed.boldItalicFont, app.ed.captionFont)
  ed.theme.fg[TokenClass.Link] = color(96, 160, 255)
  let ext = splitFile(path).ext
  ed.lang = fileExtToLanguage(ext)
  try: ed.loadFromFile(path)
  except CatchableError:
    app.msg = "could not open " & path; return
  if ed.lang in {langOrg, langMarkdown}:
    ed.setRenderFlag(rfInlineImages)          # [[file:x.bmp]] / ![](x.bmp) inline
    ed.imageBaseDir = parentDir(path)         # resolve relative image paths here
    ed.imageDefaultWidth = gInlineImageWidth  # 0 = native size
  if ed.lang == langOrg:
    ed.foldAllPending = true
  app.syncActive()
  app.buffers.add BufferState(ed: ed, filePath: path, docLang: extToLangId(ext))
  app.activate(app.buffers.high)
  app.msg = "opened " & extractFilename(path)

# -- palette entries (commands / buffers / files) --------------------------
proc orgOutline*(app: App): seq[tuple[line: int; label: string]] =
  ## Navigable landmarks of the current org buffer: section headings, named /
  ## captioned src blocks, and figure / table captions. `line` is 0-based.
  var pendingName, pendingCaption = ""
  var pendingLine = -1
  let n = app.ed.getLineCount
  for i in 0 ..< n:
    let raw = app.ed.getLineText(i)
    let s = strutils.strip(raw)
    let low = s.toLowerAscii
    if s.startsWith("*"):
      var lvl = 0
      while lvl < s.len and s[lvl] == '*': inc lvl
      let title = strutils.strip(s[lvl .. ^1])
      result.add (i, repeat("  ", max(0, lvl - 1)) & "* " & title)
      pendingName = ""; pendingCaption = ""; pendingLine = -1
    elif low.startsWith("#+name:"):
      pendingName = strutils.strip(s["#+name:".len .. ^1])
      pendingLine = i
    elif low.startsWith("#+caption:"):
      pendingCaption = strutils.strip(s["#+caption:".len .. ^1])
      pendingLine = i
    elif low.startsWith("#+begin_src"):
      let parts = s.splitWhitespace()
      let lang = if parts.len >= 2: parts[1] else: ""
      let name = if pendingName.len > 0: pendingName
                 elif pendingCaption.len > 0: pendingCaption else: "(unnamed)"
      let jump = if pendingLine >= 0: pendingLine else: i
      result.add (jump, "  src[" & lang & "] " & name)
      pendingName = ""; pendingCaption = ""; pendingLine = -1
    elif low.startsWith("#+begin_") or low.startsWith("[[file:") or
         low.startsWith("#+results:"):
      if pendingCaption.len > 0:
        result.add ((if pendingLine >= 0: pendingLine else: i),
                    "  caption: " & pendingCaption)
      pendingName = ""; pendingCaption = ""; pendingLine = -1
    elif s.len == 0:
      pendingName = ""; pendingCaption = ""; pendingLine = -1

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
  of pmThemes:
    for i in 0 ..< gThemes.len:
      let nm = gThemes[i].name
      if q.len == 0 or q in nm.toLowerAscii:
        result.add ($i, nm & (if i == app.themeIdx: "  (current)" else: ""))
  of pmOrg:
    for (line, label) in orgOutline(app):
      if q.len == 0 or q in label.toLowerAscii:
        result.add ($line, label)
  of pmRecent:
    for p in loadRecentFiles():
      let nm = extractFilename(p)
      if q.len == 0 or q in p.toLowerAscii:
        result.add (p, nm & "    " & p.parentDir)

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
  let outp = s.runBlock(gObjectsQuery[lang], quiet = true)   # keep off the terminal
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
  let outp = cleanOverstrike(s.runBlock(gHelpQuery[lang].replace("{word}", w), quiet = true))
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

proc autoComplete*(app: var App) =
  ## Non-intrusive completion refresh for always-on mode: no "no completions"
  ## noise, dismisses itself when there's nothing (useful) to show.
  if app.docLang.len == 0: app.completionActive = false; return
  let pre = prefixBeforeCursor(app)
  if pre.len < 2:                     # wait for a couple of chars before firing
    app.completionActive = false; return
  let c = getLspClient(app, app.docLang)
  if c == nil: app.completionActive = false; return
  let uri = if app.filePath.len > 0: uriOf(app.filePath) else: "file:///wkbenchless-scratch"
  c.syncDoc(uri, app.docLang, app.ed.fullText())
  let items = c.completion(uri, app.ed.currentLine, app.ed.currentCol)
  var filtered: seq[string]
  for it in items:
    if it.toLowerAscii.startsWith(pre.toLowerAscii) and it != pre: filtered.add it
  if filtered.len == 0: app.completionActive = false; return
  app.completionItems = filtered
  app.completionPrefix = pre
  app.completionSel = 0
  app.completionActive = true

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
  ## Send the current editor line to the CURRENT session (the one the bottom
  ## pane tracks). Does NOT spin up a default R session on a stray Ctrl+Enter --
  ## run a src block (C-c C-c) first to establish a session.
  let line = app.ed.getLineText(app.ed.currentLine)
  if strutils.strip(line).len == 0: return
  let s = currentSession(app)
  if s == nil:
    app.msg = "no active session -- run a src block (C-c C-c) first"
    return
  discard s.runBlock(line)          # output scrolls live in the session terminal
  app.msg = "ran line in " & app.curLang & "/" & app.curSession
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

proc orgNavCmd*(app: var App) =
  if app.editMode != emNone: app.msg = "exit src-edit first (C-c e)"; return
  openPalette(app, pmOrg)

proc openRecentCmd*(app: var App) =
  if app.editMode != emNone: app.msg = "exit src-edit first (C-c e)"; return
  if loadRecentFiles().len == 0: app.msg = "no recent files"; return
  openPalette(app, pmRecent)

proc themeCmd*(app: var App) =
  if gThemes.len == 0: app.msg = "no themes registered (see wkbconfig)"; return
  openPalette(app, pmThemes)
  app.paletteSel = app.themeIdx        # reopen on the currently-active theme

proc listBuffers*(app: var App) =
  if app.editMode != emNone: app.msg = "exit src-edit first (C-c e)"; return
  app.syncActive()                       # reflect the live active buffer
  openPalette(app, pmBuffers)

proc openFileCmd*(app: var App) =
  if app.editMode != emNone: app.msg = "exit src-edit first (C-c e)"; return
  app.paletteDir = if app.filePath.len > 0: parentDir(app.filePath) else: getCurrentDir()
  openPalette(app, pmFiles)

# -- find / replace --------------------------------------------------------
proc recomputeMatches*(app: var App) =
  ## Rescan the buffer for the current needle, refresh the highlight markers,
  ## and pick the match nearest the cursor as current.
  app.searchMatches.setLen 0
  app.ed.clearMarkers()
  if app.searchQuery.len == 0:
    app.searchIdx = -1
    return
  let hay = if app.searchCase: app.ed.fullText else: app.ed.fullText.toLowerAscii
  let needle = if app.searchCase: app.searchQuery else: app.searchQuery.toLowerAscii
  var start = 0
  while true:
    let p = hay.find(needle, start)
    if p < 0: break
    app.searchMatches.add p
    app.ed.addMarker(p, p + needle.len - 1, app.theme.ed.selBg)
    start = p + max(1, needle.len)
  if app.searchMatches.len == 0:
    app.searchIdx = -1
    return
  let cur = app.ed.cursor
  app.searchIdx = 0
  for i, p in app.searchMatches:
    if p >= cur: app.searchIdx = i; break
    app.searchIdx = i

proc gotoCurrentMatch*(app: var App) =
  if app.searchIdx < 0 or app.searchIdx >= app.searchMatches.len: return
  app.ed.gotoPos(app.searchMatches[app.searchIdx])
  app.msg = "match " & $(app.searchIdx + 1) & "/" & $app.searchMatches.len

proc searchNext*(app: var App) =
  if app.searchMatches.len == 0: app.msg = "no matches"; return
  app.searchIdx = (app.searchIdx + 1) mod app.searchMatches.len
  app.gotoCurrentMatch()

proc searchPrev*(app: var App) =
  if app.searchMatches.len == 0: app.msg = "no matches"; return
  app.searchIdx = (app.searchIdx - 1 + app.searchMatches.len) mod app.searchMatches.len
  app.gotoCurrentMatch()

proc endSearch*(app: var App) =
  app.searchActive = false
  app.ed.clearMarkers()

proc openFind*(app: var App) =
  if app.editMode != emNone: app.msg = "exit src-edit first (C-c e)"; return
  app.searchActive = true
  app.searchMode = smFind
  app.searchField = sfQuery
  app.searchQuery = ""
  app.searchReplace = ""
  app.searchIdx = -1
  app.searchMatches.setLen 0
  app.ed.clearMarkers()

proc openReplace*(app: var App) =
  openFind(app)
  app.searchMode = smReplace

proc replaceCurrent*(app: var App) =
  ## Replace the current match, then rescan (offsets shift) and advance.
  if app.searchIdx < 0 or app.searchIdx >= app.searchMatches.len:
    app.msg = "no match"; return
  let p = app.searchMatches[app.searchIdx]
  app.ed.selectRange(p, p + app.searchQuery.len - 1)
  app.ed.deleteSelection()
  app.ed.gotoPos(p)
  app.ed.insertText(app.searchReplace)
  app.ed.markChanged()
  app.recomputeMatches()
  app.gotoCurrentMatch()

proc replaceAll*(app: var App) =
  if app.searchQuery.len == 0: return
  var n = 0
  while app.searchMatches.len > 0:
    let p = app.searchMatches[0]
    app.ed.selectRange(p, p + app.searchQuery.len - 1)
    app.ed.deleteSelection()
    app.ed.gotoPos(p)
    app.ed.insertText(app.searchReplace)
    inc n
    app.recomputeMatches()
  app.ed.markChanged()
  app.msg = "replaced " & $n
  app.endSearch()

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

proc lineStartOffset(app: App; line: int): int =
  ## Buffer offset of the first char of `line` (0-based) via a single scan.
  let txt = app.ed.fullText
  var off = 0
  var n = 0
  while off < txt.len and n < line:
    if txt[off] == '\L': inc n
    inc off
  off

proc blockStartLineAtCursor(app: App): int =
  ## Line index of the #+begin_src that opens the block the cursor sits in, -1.
  let cur = app.ed.currentLine
  var i = cur
  while i >= 0:
    let low = strutils.strip(app.ed.getLineText(i)).toLowerAscii
    if low.startsWith("#+begin_src"): return i
    if low.startsWith("#+end_src") and i < cur: return -1
    dec i
  -1

proc toggleFold*(app: var App) =
  if app.ed.lang != langOrg: app.msg = "folding is for org files"; return
  let line = blockStartLineAtCursor(app)
  if line < 0: app.msg = "not on a src block"; return
  let off = lineStartOffset(app, line)
  app.ed.toggleFold(off)
  app.msg = if app.ed.isFolded(off): "folded" else: "unfolded"

proc scrollRight*(app: var App) = app.ed.hScroll = min(app.ed.hScroll + 8, 400)
proc scrollLeft*(app: var App) = app.ed.hScroll = max(app.ed.hScroll - 8, 0)

proc foldAllSrc*(app: var App) =
  if app.ed.lang == langOrg: app.ed.foldAllBlocks(); app.msg = "all blocks folded"
proc unfoldAllSrc*(app: var App) =
  if app.ed.lang == langOrg: app.ed.unfoldAll(); app.msg = "all blocks unfolded"

proc linkAtCursor*(app: App): string =
  ## The org link target under the cursor, or "" (for plain-click activation).
  orgLinkAt(app.ed.getLineText(app.ed.currentLine), app.ed.currentCol)

const editableExts = [".org", ".md", ".markdown", ".txt", ".text", ".nim", ".nims",
  ".py", ".pyw", ".r", ".jl", ".el", ".lisp", ".c", ".h", ".cpp", ".hpp", ".cc",
  ".js", ".ts", ".json", ".yaml", ".yml", ".toml", ".cfg", ".conf", ".ini", ".sh",
  ".bash", ".zsh", ".tex", ".bib", ".csv", ".tsv", ".html", ".css", ".xml", ".rs",
  ".go", ".lua", ".vim", ".sql", ".rmd", ".qmd", ".log"]

proc openExternally(target: string) =
  when defined(windows):
    discard execShellCmd("start \"\" " & quoteShell(target))
  else:
    let opener = when defined(macosx): "open" else: "xdg-open"
    discard execShellCmd(opener & " " & quoteShell(target) & " &")

proc openLink*(app: var App) =
  ## Follow the org link at the cursor. A file link to a text/source file opens
  ## IN wkbenchless (like org-open-at-point in Emacs); a URL, mailto, or a
  ## non-text file (pdf, image, ...) hands off to the system opener. `file:` is
  ## optional -- a bare relative/absolute path is treated as a file link too.
  let target = orgLinkAt(app.ed.getLineText(app.ed.currentLine), app.ed.currentCol)
  if target.len == 0: app.msg = "no link at cursor"; return

  # URLs and mailto go straight to the system handler.
  if target.find("://") >= 0 or target.startsWith("mailto:"):
    openExternally(target); app.msg = "opening " & target; return

  var t = target
  if t.startsWith("file:"): t = t[5 .. ^1]
  # an org `::anchor` selects a line number or a heading within the file
  var anchor = ""
  let ai = t.find("::")
  if ai >= 0: (anchor = t[ai + 2 .. ^1]; t = t[0 ..< ai])
  t = expandTilde(t)
  if not isAbsolute(t) and app.filePath.len > 0:
    t = parentDir(app.filePath) / t      # resolve relative to the current file

  if not fileExists(t):
    app.msg = "link target not found: " & t; return
  if t.splitFile.ext.toLowerAscii in editableExts:
    openFile(app, t)                     # open in the editor
    if anchor.len > 0:
      try: app.ed.gotoLine(parseInt(anchor.strip(chars = {'*', ' '})) - 1, 0)
      except ValueError: discard         # (heading anchors: jump left to future work)
    app.msg = "opened " & extractFilename(t)
  else:
    openExternally(t); app.msg = "opening " & extractFilename(t)

# -- CriticMarkup (tracked changes), cf. org-tracked-docx --------------------
proc applyCriticMarkup*(text: string; accept: bool): string =
  ## Resolve every CriticMarkup token. accept: keep insertions & the NEW side of
  ## a substitution, drop deletions. reject: the opposite. Comments are dropped
  ## either way; a highlight always keeps its text (only the wrapper goes).
  ##   {++ins++}  {--del--}  {~~old~>new~~}  {>>comment<<}  {==highlight==}
  result = newStringOfCap(text.len)
  var i = 0
  proc closeOf(o, c: char): int =
    ## Index of the '}' ending `<o><o> ... <c><c>}` starting at i, or -1.
    var q = i + 3
    while q + 2 < text.len:
      if text[q] == c and text[q+1] == c and text[q+2] == '}': return q + 2
      inc q
    -1
  while i < text.len:
    if i + 4 < text.len and text[i] == '{':
      let a = text[i+1]; let b = text[i+2]
      if a == b and a in {'+', '-', '=', '~'}:
        let e = closeOf(a, a)
        if e >= 0:
          let inner = text[i+3 ..< e-2]
          case a
          of '+': (if accept: result.add inner)
          of '-': (if not accept: result.add inner)
          of '=': result.add inner
          of '~':
            let arrow = inner.find("~>")
            if arrow >= 0: result.add (if accept: inner[arrow+2 .. ^1] else: inner[0 ..< arrow])
            else: result.add inner
          else: discard
          i = e + 1; continue
      elif a == '>' and b == '>':          # {>>comment<<} -- asymmetric close
        let e = closeOf('<', '<')
        if e >= 0: (i = e + 1; continue)   # drop the comment entirely
    result.add text[i]; inc i

proc collectLatexHeader(app: App): string =
  ## Extra preamble from the buffer's `#+LATEX_HEADER:` lines (org convention),
  ## so user macros / packages are available to previews.
  for i in 0 ..< app.ed.getLineCount():
    let s = strutils.strip(app.ed.getLineText(i))
    if s.toLowerAscii.startsWith("#+latex_header:"):
      result.add strutils.strip(s[s.find(':') + 1 .. ^1]) & "\n"

proc renderLatexFragment(inner, header, outPng: string): bool =
  ## Compile one display-math fragment to `outPng` via latex -> dvipng (black on
  ## white). Returns false if the toolchain is missing or compilation fails.
  let tmp = getTempDir() / "wkbenchless-ltx"
  try: createDir(tmp) except CatchableError: return false
  let tex = tmp / "frag.tex"
  writeFile(tex,
    "\\documentclass[12pt]{article}\n" &
    "\\usepackage{amsmath,amssymb,amsfonts}\n" & header &
    "\\pagestyle{empty}\n\\begin{document}\n\\[\n" & inner &
    "\n\\]\n\\end{document}\n")
  let (_, c1) = execCmdEx("latex -interaction=nonstopmode -halt-on-error " &
                          quoteShell(tex), workingDir = tmp)
  if c1 != 0: return false
  let (_, c2) = execCmdEx("dvipng -q -T tight -D " & $gLatexDpi &
                          " -bg White -o " & quoteShell(outPng) & " " &
                          quoteShell(tmp / "frag.dvi"), workingDir = tmp)
  result = c2 == 0 and fileExists(outPng)

proc latexPreview*(app: var App) =
  ## Toggle inline LaTeX previews (org-latex-preview style). On enable, render
  ## every whole-line display-math fragment ($$..$$, \[..\], \(..\), $..$) to a
  ## cached PNG the buffer then shows in place; the source returns while the
  ## cursor is on that line, or when toggled off.
  let on = rfLatexPreview notin app.ed.flags
  app.ed.setRenderFlag(rfLatexPreview, on)
  if not on:
    app.msg = "latex preview off"; return
  if findExe("latex").len == 0 or findExe("dvipng").len == 0:
    app.ed.setRenderFlag(rfLatexPreview, false)
    app.msg = "latex preview needs `latex` and `dvipng` on PATH"; return
  let header = collectLatexHeader(app)
  try: createDir(getCacheDir() / "wkbenchless" / "ltximg") except CatchableError: discard
  var made, failed = 0
  for i in 0 ..< app.ed.getLineCount():
    var inner = ""
    if parseMathLine(app.ed.getLineText(i), inner):
      let outPng = ltxCachePath(app.ed.getLineText(i))
      if not fileExists(outPng):
        if renderLatexFragment(inner, header, outPng): inc made else: inc failed
  app.msg = "latex preview on (" & $made & " rendered" &
            (if failed > 0: ", " & $failed & " failed" else: "") & ")"

proc cancelOverlays*(app: var App) =
  ## Keyboard-quit (C-g): dismiss the command palette / find minibuffer overlays.
  app.paletteActive = false
  app.searchActive = false
  app.msg = ""

proc toggleInlineImages*(app: var App) =
  ## Toggle inline rendering of whole-line image links ([[file:x.bmp]] /
  ## ![](x.bmp)) in the current buffer, resolving relative paths against the
  ## file's directory (or the cwd for an unsaved buffer).
  let on = rfInlineImages notin app.ed.flags
  app.ed.setRenderFlag(rfInlineImages, on)
  app.ed.imageBaseDir =
    if app.filePath.len > 0: parentDir(app.filePath) else: getCurrentDir()
  app.ed.imageDefaultWidth = gInlineImageWidth
  app.msg = "inline images " & (if on: "on" else: "off")

proc criticAcceptAll*(app: var App) =
  if app.ed.lang != langOrg: app.msg = "CriticMarkup is for org files"; return
  app.ed.setText(applyCriticMarkup(app.ed.fullText(), accept = true))
  app.ed.markChanged(); app.msg = "accepted all tracked changes"

proc criticRejectAll*(app: var App) =
  if app.ed.lang != langOrg: app.msg = "CriticMarkup is for org files"; return
  app.ed.setText(applyCriticMarkup(app.ed.fullText(), accept = false))
  app.ed.markChanged(); app.msg = "rejected all tracked changes"

# -- two-pane diff (for agents to show before/after) -------------------------
proc lineDiff(a, b: seq[string]): tuple[l, r: seq[string]; lk, rk: seq[char]] =
  ## LCS line alignment: each output row is (left, right) with a kind --
  ## ' ' unchanged, '-' removed (right blank), '+' added (left blank).
  let n = a.len; let m = b.len
  var dp = newSeq[seq[int]](n + 1)
  for i in 0 .. n: dp[i] = newSeq[int](m + 1)
  for i in countdown(n - 1, 0):
    for j in countdown(m - 1, 0):
      dp[i][j] = if a[i] == b[j]: dp[i+1][j+1] + 1 else: max(dp[i+1][j], dp[i][j+1])
  var i = 0; var j = 0
  while i < n and j < m:
    if a[i] == b[j]:
      result.l.add a[i]; result.r.add b[j]; result.lk.add ' '; result.rk.add ' '; inc i; inc j
    elif dp[i+1][j] >= dp[i][j+1]:
      result.l.add a[i]; result.r.add ""; result.lk.add '-'; result.rk.add ' '; inc i
    else:
      result.l.add ""; result.r.add b[j]; result.lk.add ' '; result.rk.add '+'; inc j
  while i < n: (result.l.add a[i]; result.r.add ""; result.lk.add '-'; result.rk.add ' '; inc i)
  while j < m: (result.l.add ""; result.r.add b[j]; result.lk.add ' '; result.rk.add '+'; inc j)

proc showDiff*(app: var App; oldText, newText, title: string) =
  ## Populate and open the side-by-side diff view.
  let d = lineDiff(oldText.splitLines(), newText.splitLines())
  app.diffL = d.l; app.diffR = d.r; app.diffLK = d.lk; app.diffRK = d.rk
  app.diffTitle = if title.len > 0: title else: "diff"
  app.diffScroll = 0
  app.diffActive = true
  app.focus = "diff"
  var adds, dels = 0
  for k in d.lk: (if k == '-': inc dels)
  for k in d.rk: (if k == '+': inc adds)
  app.msg = "diff: " & app.diffTitle & "  +" & $adds & " -" & $dels & "  (Esc to close)"

proc closeDiff*(app: var App) =
  app.diffActive = false
  app.diffL = @[]; app.diffR = @[]; app.diffLK = @[]; app.diffRK = @[]
  if app.focus == "diff": app.focus = "editor"

proc diffBuffer*(app: var App) =
  ## Diff the current buffer against its saved on-disk version.
  if app.filePath.len == 0 or not fileExists(app.filePath):
    app.msg = "no saved file to diff against"; return
  showDiff(app, readFile(app.filePath), app.ed.fullText(),
           extractFilename(app.filePath) & " (disk -> buffer)")

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

const terminalTabKey* = "·terminal"   # sentinel tab key for the standalone terminal

proc sessionKeys*(app: App): seq[string] =
  for k in app.sessions.keys: result.add k
  sort(result)

proc tabKeys*(app: App): seq[string] =
  ## Every bottom-pane tab, in order: the REPL sessions, then the standalone
  ## terminal (if one is open). Used for rendering, clicking, and cycling.
  result = app.sessionKeys()
  if app.hasTerminal: result.add terminalTabKey

proc currentTabKey*(app: App): string =
  ## Which tab the pane is showing right now.
  if app.termActive: terminalTabKey else: app.curLang.toLowerAscii & "/" & app.curSession

proc selectTab*(app: var App; key: string) =
  ## Make `key` the current tab. Selecting a session turns the terminal off (and
  ## vice versa) -- the two were previously independent, so switching was
  ## invisible while the terminal was active.
  app.focus = "session"
  app.termScroll = 0                    # a freshly selected tab starts at the tail
  if key == terminalTabKey:
    app.termActive = true
    app.msg = "terminal: " & app.termLabel
    return
  app.termActive = false
  let parts = key.split('/')
  app.curLang = parts[0]
  app.curSession = if parts.len > 1: parts[1] else: "default"
  refreshObjects(app)
  app.msg = "session: " & key

proc setSession*(app: var App; key: string) = selectTab(app, key)

proc switchSession*(app: var App) =
  ## Cycle to the next bottom-pane tab (sessions and the terminal alike).
  let keys = app.tabKeys()
  if keys.len == 0: app.msg = "no sessions yet"; return
  let cur = app.currentTabKey()
  var i = -1
  for k, name in keys:
    if name == cur: i = k
  selectTab(app, keys[(i + 1) mod keys.len])

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

proc openTerminal*(app: var App; cmd: string)   # forward decl (defined below)

proc sshMasterUp(host: string): bool =
  ## Is there a live, authenticated ssh master connection to `host`?
  let (_, code) = execCmdEx("ssh -O check -o ControlPath=" &
    quoteShell(sshControlPath()) & " " & quoteShell(host) & " 2>/dev/null")
  code == 0

proc ensureSshMaster(app: var App; host: string): bool =
  ## True if a master to `host` is up. Otherwise open a terminal to log in (where
  ## the password prompt actually works) and return false -- the user authenticates
  ## once, then re-runs the block, and the marker session reuses the master.
  if sshMasterUp(host): return true
  try: createDir(getHomeDir() / ".ssh") except CatchableError: discard
  openTerminal(app, "ssh -tt -o ControlMaster=auto -o ControlPath=" & sshControlPath() &
                    " -o ControlPersist=" & gSshPersist & " " & host)
  app.msg = "log in to " & host & " in the terminal, then run the block again"
  false

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
  var sessName, host, dir = ""
  # Parse :session / :ssh / :dir from a token list; only fill unset fields (so
  # the BLOCK header wins over document #+PROPERTY defaults, applied after).
  proc apply(toks: seq[string]) =
    var k = 0
    while k < toks.len:
      if toks[k] == ":session" and k + 1 < toks.len and sessName.len == 0:
        sessName = toks[k + 1]
      elif toks[k] == ":ssh" and k + 1 < toks.len and host.len == 0:
        host = toks[k + 1]
      elif toks[k] == ":dir" and k + 1 < toks.len and dir.len == 0 and host.len == 0:
        let (h, p) = parseSshDir(toks[k + 1])
        if h.len > 0: host = h
        dir = p
      inc k
  apply(strutils.splitWhitespace(header)[2 .. ^1])   # the block header first
  apply(headerArgTokens(app, lang))                  # then document defaults
  if sessName.len == 0: sessName = "default"
  if host.len > 0 and '@' notin sessName: sessName = sessName & "@" & host
  if host.len > 0 and not ensureSshMaster(app, host): return   # authenticate first

  var bodyLines: seq[string]
  for i in b + 1 ..< e: bodyLines.add app.ed.getLineText(i)
  app.curLang = lang.toLowerAscii; app.curSession = sessName   # keys are lower-lang
  # `dir` (remote cwd) is parsed from :dir only to recover the host; running the
  # block IN that dir is deferred -- for now we just send code and capture results.
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

proc writeHandoff(app: var App): string =
  ## Preserve live REPL sessions and the terminal across the re-exec: clear
  ## FD_CLOEXEC on each pty master so it survives execv (the child processes stay
  ## alive on the slave side), and record fd+pid+identity in a temp file the new
  ## image adopts. Returns the file path ("" if nothing to hand off).
  when defined(posix):
    var blob = ""
    for key, s in app.sessions:
      if s != nil and s.pty.alive:
        discard fcntl(s.pty.master, F_SETFD, 0.cint)     # clear CLOEXEC
        let parts = key.split('/')
        blob.add "S\t" & $s.pty.master & "\t" & $s.pty.pid & "\t" &
                 parts[0] & "\t" & (if parts.len > 1: parts[1] else: "default") & "\n"
    if app.termMaster >= 0 and app.hasTerminal:
      discard fcntl(app.termMaster, F_SETFD, 0.cint)
      blob.add "T\t" & $app.termMaster & "\t" & $app.termPid & "\t" &
               app.termLabel & "\t" & $app.termActive & "\n"
    if blob.len == 0: return ""
    let path = getTempDir() / ("wkbenchless-handoff." & $getpid())
    writeFile(path, blob)
    path
  else: ""

proc adoptHandoff*(app: var App): tuple[master: cint; pid: int; label: string; active: bool] =
  ## If a hot reload handed off sessions/terminal (WKB_HANDOFF), rebuild the REPL
  ## sessions here and return the terminal's inherited fd/pid for the host to
  ## adopt. Called once at startup after configure() (so gRepls is populated).
  result = (master: cint(-1), pid: 0, label: "", active: false)
  when defined(posix):
    let path = getEnv("WKB_HANDOFF")
    if path.len == 0 or not fileExists(path): return
    let blob = readFile(path)
    removeFile(path); delEnv("WKB_HANDOFF")
    for line in blob.splitLines():
      let f = line.split('\t')
      if f.len < 5: continue
      let fd = cint(parseInt(f[1]))
      discard fcntl(fd, F_SETFL, O_NONBLOCK)
      discard fcntl(fd, F_SETFD, FD_CLOEXEC)             # re-arm for the next reload
      if f[0] == "S" and gRepls.hasKey(f[3]):
        app.sessions[f[3] & "/" & f[4]] =
          Session(pty: Pty(master: fd, pid: Pid(parseInt(f[2]))), spec: gRepls[f[3]])
      elif f[0] == "T":
        result = (master: fd, pid: parseInt(f[2]), label: f[3], active: f[4] == "true")

proc nimblePkgSourceDir(): string =
  ## For a binary put on PATH by `nimble install <github-url>` (which lands in
  ## ~/.nimble/bin while the sources live under ~/.nimble/pkgs2/<pkg>-<hash>/):
  ## the newest wkbenchless-* package dir that actually carries the source.
  for base in [getHomeDir() / ".nimble" / "pkgs2",
               getHomeDir() / ".nimble" / "pkgs"]:
    if not dirExists(base): continue
    var best = ""
    var bestT: times.Time
    for kind, path in walkDir(base):
      if kind == pcDir and lastPathPart(path).startsWith("wkbenchless-") and
         fileExists(path / "src" / "wkbenchless.nim"):
        let t = getLastModificationTime(path / "src" / "wkbenchless.nim")
        if best.len == 0 or t > bestT: best = path; bestT = t
    if best.len > 0: return best

proc resolveBuildDir(): string =
  ## Directory to run the reload rebuild in -- one that actually has src/.
  ## In order: alongside the binary (working tree, or an install that kept its
  ## source); the git checkout this binary was compiled from; else the nimble
  ## package source dir (installed via a github URL). Falls back to getAppDir()
  ## so the caller's existing "no src -> fail" message still fires if all miss.
  if dirExists(getAppDir() / "src"): return getAppDir()
  const SourceRoot = currentSourcePath().parentDir.parentDir  # <repo>/src/.. = <repo>
  if dirExists(SourceRoot / ".git") and dirExists(SourceRoot / "src"):
    return SourceRoot
  let nimbleSrc = nimblePkgSourceDir()
  if nimbleSrc.len > 0: return nimbleSrc
  if dirExists(SourceRoot / "src"): return SourceRoot   # last resort: no .git, still there
  return getAppDir()

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
    # Rebuild from a directory that actually has the source (see resolveBuildDir).
    # When the binary was `nimble install`ed, getAppDir() can be a binary-only
    # dir with no src/, where rebuilding fails silently. This self-heals: a
    # successful reload re-execs the freshly built binary from the resolved dir.
    let dir = resolveBuildDir()
    if gRebuildCmd.len == 0: gRebuildCmd = detectRebuildCmd()
    let (outp, code) = execCmdEx(gRebuildCmd, workingDir = dir)
    if code != 0:
      stderr.write("-- recompile FAILED --\n$ " & gRebuildCmd & "\n" & outp & "\n")
      # surface the first real error line in the status bar
      var firstErr = ""
      for ln in outp.splitLines():
        if "Error:" in ln or " error:" in ln: firstErr = strutils.strip(ln); break
      app.msg = "recompile failed" & (if firstErr.len > 0: " -- " & firstErr else: " (see launch terminal)")
      return
    # persist the buffer so edits survive the exec
    var fileArg = app.filePath
    if fileArg.len == 0:
      fileArg = getTempDir() / "wkbenchless-scratch.txt"
      writeFile(fileArg, app.ed.fullText())
    elif app.ed.changed:
      app.ed.saveToFile(app.filePath); app.ed.markSaved()
    let line = app.ed.currentLine
    # Hand the live sessions + terminal off to the new image instead of killing
    # them: their pty masters survive execv (CLOEXEC cleared) and, because execv
    # keeps our PID, we stay the parent of those child processes.
    let handoff = writeHandoff(app)
    # Exec the freshly built binary by its known path, NOT getAppFilename():
    # the rebuild replaced our on-disk file, so /proc/self/exe now reads
    # ".../wkbenchless (deleted)", which would make execv fail with ENOENT. `dir` was
    # captured before the build, and the rebuild writes `-o:wkbenchless` into it.
    let bin = dir / "wkbenchless"
    if not fileExists(bin):
      app.msg = "recompile: built binary not found at " & bin; return
    if handoff.len > 0: putEnv("WKB_HANDOFF", handoff)
    # Defer the execv to the host: it owns the terminal's screen grid, which it
    # snapshots (so a TUI looks identical after reload) just before re-exec.
    app.reloadBin = bin; app.reloadFile = fileArg; app.reloadLine = line
    app.reloadPending = true

proc execReload*(app: var App) =
  ## Re-exec the freshly built binary, restoring the file + cursor. Called by the
  ## host after it has stashed the terminal grid (WKB_TERMGRID) and sessions.
  when defined(posix):
    let argv = allocCStringArray(@[app.reloadBin, app.reloadFile, "--goto", $app.reloadLine])
    discard execv(app.reloadBin.cstring, argv)
    app.msg = "recompile: exec failed (" & app.reloadBin & ")"   # only if execv failed
    app.reloadPending = false

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
var gTerminalDir*: string   ## config override for the terminal cwd ("" = auto)

proc projectRoot*(app: App): string =
  ## The nearest ancestor of the current file that contains .git (else the
  ## file's dir, else the cwd).
  var cur = if app.filePath.len > 0: parentDir(app.filePath) else: getCurrentDir()
  let startDir = cur
  while cur.len > 1:
    if dirExists(cur / ".git"): return cur
    let up = parentDir(cur)
    if up == cur: break
    cur = up
  startDir

proc terminalDir*(app: App): string =
  ## Where a new terminal starts: config gTerminalDir if set, else project root.
  if gTerminalDir.len > 0: expandTilde(gTerminalDir) else: projectRoot(app)

proc openTerminal*(app: var App; cmd: string) =
  ## Ask the host to run `cmd` in the thread-free PTY terminal (bottom panel),
  ## and register it as a selectable tab.
  app.termActive = true
  app.hasTerminal = true
  app.termLabel = cmd.splitWhitespace()[0]   # "claude", "bash", ...
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
  defcommand("theme", "Theme: pick a base16 / sixteen color theme", themeCmd)
  defcommand("list-buffers", "List / switch buffers", listBuffers)
  defcommand("open-file", "Open file (browse)", openFileCmd)
  defcommand("find", "Find in buffer", openFind)
  defcommand("replace", "Find & replace in buffer", openReplace)
  defcommand("org-nav", "Org: navigate headings / named blocks / captions", orgNavCmd)
  defcommand("recent-files", "Open a recent file", openRecentCmd)
  defcommand("toggle-fold", "Org: fold / unfold this src block", toggleFold)
  defcommand("fold-all", "Org: fold all src blocks", foldAllSrc)
  defcommand("unfold-all", "Org: unfold all src blocks", unfoldAllSrc)
  defcommand("scroll-right", "Scroll the view right (wide tables)", scrollRight)
  defcommand("scroll-left", "Scroll the view left", scrollLeft)
  defcommand("kill-buffer", "Kill the current buffer", killBuffer)
  defcommand("zoom-in", "Increase font size", zoomIn)
  defcommand("zoom-out", "Decrease font size", zoomOut)
  defcommand("zoom-reset", "Reset font size", zoomReset)
  defcommand("open-link", "Open org link at cursor", openLink)
  defcommand("toggle-inline-images", "Images: toggle inline [[file:x.png]] rendering", toggleInlineImages)
  defcommand("latex-preview", "LaTeX: toggle inline previews of display math", latexPreview)
  defcommand("cancel", "Cancel / dismiss the palette or find overlay (C-g)", cancelOverlays)
  defcommand("criticmarkup-accept-all", "CriticMarkup: accept all tracked changes", criticAcceptAll)
  defcommand("criticmarkup-reject-all", "CriticMarkup: reject all tracked changes", criticRejectAll)
  defcommand("diff-buffer", "Diff: buffer vs saved file (two panes)", diffBuffer)
  defcommand("close-diff", "Diff: close the diff view", closeDiff)
  defcommand("toggle-vim", "Toggle vim (modal) editing", toggleVim)
  defcommand("terminal", "Open a bash terminal in the bottom panel",
             proc(app: var App) = openTerminal(app, "bash --norc"))
  defcommand("claude", "Open claude in the bottom panel (continues last chat)",
             proc(app: var App) = openTerminal(app, gClaudeCmd))
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
