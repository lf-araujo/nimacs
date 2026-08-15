## focim core: the editor model that user config can touch DIRECTLY -- the point
## of the pure-Nim rewrite. There is no ABI boundary: the host (focim.nim) does
## rendering, the user config (focimconfig.nim) imports this module and calls
## defcommand / bindkey / registerRepl / addHook against the exact same App and
## SynEdit types the host uses. Commands are Nim procs; keys and languages are
## data; hooks fire at editor events.

import uirelays
import widgets/synedit
import focimsession
import std/[tables, strutils]

export uirelays, synedit, focimsession   # config sees Event/KeyCode/SynEdit/ReplSpec/...

type
  App* = object
    ed*, sess*: SynEdit
    sessions*: Table[string, Session]     ## key: langId & "/" & sessionName
    font*: Font
    filePath*, msg*: string
    running*: bool
    pendingPrefix*: string
    paletteActive*: bool
    paletteQuery*: string
    paletteSel*: int
  Command* = object
    label*: string
    run*: proc(app: var App)
  Hook* = proc(app: var App)

var
  gCommands*: OrderedTable[string, Command]
  gKeymap*: Table[string, string]         ## chord (or "C-c C-c") -> command name
  gRepls*: Table[string, ReplSpec]        ## langId -> interpreter spec
  gHooks*: Table[string, seq[Hook]]       ## event name -> hooks

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

proc paletteFiltered*(app: App): seq[(string, string)] =
  let q = app.paletteQuery.toLowerAscii
  for name, c in gCommands:
    if q.len == 0 or q in c.label.toLowerAscii: result.add (name, c.label)

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
  let s = getSession(app, "r", "default")
  if s == nil: app.msg = "could not start R (on PATH?)"; return
  let outp = s.runBlock(line)
  app.sess.appendOutput("> " & line & "\n")
  if outp.len > 0: app.sess.appendOutput(outp & "\n")
  app.msg = "ran line"

proc saveCmd*(app: var App) =
  if app.filePath.len > 0:
    app.ed.saveToFile(app.filePath); app.ed.markSaved()
    app.msg = "saved"
    app.runHooks("after-save")
  else: app.msg = "no file (pass a path on the command line)"

proc quitCmd*(app: var App) = app.running = false
proc paletteCmd*(app: var App) =
  app.paletteActive = true; app.paletteQuery = ""; app.paletteSel = 0

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
  app.runHooks("after-babel")

proc registerBuiltins*() =
  gRepls["r"] = rSpec
  defcommand("save", "Save", saveCmd)
  defcommand("quit", "Quit", quitCmd)
  defcommand("run-line", "Run current line in session", runLine)
  defcommand("babel-execute", "Org-babel: run this src block", babelExecute)
  defcommand("comment-toggle", "Comment: toggle line", proc(app: var App) = app.ed.toggleComment())
  defcommand("undo", "Undo", proc(app: var App) = app.ed.undo())
  defcommand("redo", "Redo", proc(app: var App) = app.ed.redo())
  defcommand("palette", "Command palette", paletteCmd)
  bindkey("C-s", "save")
  bindkey("C-q", "quit")
  bindkey("C-Enter", "run-line")
  bindkey("C-c C-c", "babel-execute")
  bindkey("C-/", "comment-toggle")
  bindkey("C-z", "undo")
  bindkey("C-y", "redo")
  bindkey("C-S-p", "palette")
