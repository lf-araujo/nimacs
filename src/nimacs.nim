## nimacs: an Emacs-style text editor whose commands/keybindings are Nim
## code, redefinable and hot-reloadable while the app runs. See DESIGN.md.
##
## Architecture: this file is the *host* — the owlkettle/GTK app, compiled
## once, never reloaded. It owns the durable EditorKernel (buffer text,
## cursor, status) and the live Dispatch (command/keybinding tables). The
## reloadable half is `config.nim`, compiled to a `.so` on demand by
## `nimacs/dispatch`. This module never appears on the other side of that
## boundary — config.nim only ever sees `nimacs/kernel` + `nimacs/config_api`.
##
## EditorTextView below builds its own GtkTextView + GtkTextBuffer from raw
## GTK4 C bindings rather than using owlkettle's own TextView/TextBuffer
## wrappers: owlkettle's per-widget State types (e.g. TextViewState) are
## generated fresh by its `renderable` macro at each call site and are not
## reachable from outside owlkettle's own module, so subclassing an
## existing owlkettle widget from application code (to attach our own
## GtkEventControllerKey) isn't actually possible -- confirmed empirically,
## not assumed. owlkettle's raw GTK bindings (gtk_text_buffer_*,
## gtk_text_view_*) are public, though, so building the widget directly
## against those works fine and gives full control besides.

import std/[os, unicode, strutils, osproc, tempfiles, streams, tables]
import owlkettle
import owlkettle/adw
import owlkettle/bindings/gtk
import nimacs/[kernel, dispatch, hotcompile]

# Built-in example document shown when nimacs is launched without a file.
# Embedded at compile time (rather than read from disk at runtime) so it is
# always available regardless of where the binary ends up after `nimble install`.
const welcomeOrg = staticRead("../examples/welcome.org")

# -- Extra raw GTK bindings owlkettle doesn't expose itself --------------
proc gtk_text_view_get_buffer(textView: GtkWidget): GtkTextBuffer {.importc, cdecl.}
proc gtk_text_buffer_get_insert(buffer: GtkTextBuffer): pointer {.importc, cdecl.}
proc gtk_text_buffer_get_iter_at_mark(buffer: GtkTextBuffer; iter: ptr GtkTextIter; mark: pointer) {.importc, cdecl.}
proc gtk_event_controller_set_propagation_phase(controller: GtkEventController; phase: cint) {.importc, cdecl.}
proc gtk_event_controller_key_new(): GtkEventController {.importc, cdecl.}
const GtkPhaseCapture = 1.cint

# owlkettle's own FileChooserDialog/open() builds on GTK's legacy, now
# heavily-deprecated gtk_file_chooser_dialog_new -- confirmed by stack
# trace to SIGSEGV inside that constructor on this (very recent, 4.22)
# GTK4 version, in an isolated minimal reproduction with none of this
# project's own code involved. Using the modern, actively-maintained
# GtkFileDialog API (GTK >=4.10) directly instead, same as EditorTextView
# bypasses owlkettle's TextView for reasons noted above.
type
  GtkFileDialog = distinct pointer
  GAsyncReadyCallback = proc (sourceObject: pointer; res: pointer; userData: pointer) {.cdecl.}

proc gtk_file_dialog_new(): GtkFileDialog {.importc, cdecl.}
proc gtk_file_dialog_set_title(dialog: GtkFileDialog; title: cstring) {.importc, cdecl.}
proc gtk_file_dialog_open(dialog: GtkFileDialog; parent: GtkWidget; cancellable: pointer;
                          callback: GAsyncReadyCallback; userData: pointer) {.importc, cdecl.}
proc gtk_file_dialog_open_finish(dialog: GtkFileDialog; res: pointer; error: ptr GError): GFile {.importc, cdecl.}

proc `==`(a, b: GtkTextBuffer): bool {.borrow.}
  ## `GtkTextBuffer` is a `distinct pointer`; owlkettle's `renderable` macro
  ## needs `==` to detect changes between renders for the `gtkBuffer` field.

# -- Raw GtkTextBuffer helpers ---------------------------------------------

proc newGtkTextBuffer(): GtkTextBuffer =
  gtk_text_buffer_new(GtkTextTagTable(nil))

proc bufferText(buf: GtkTextBuffer): string =
  var a, b: GtkTextIter
  gtk_text_buffer_get_start_iter(buf, a.addr)
  gtk_text_buffer_get_end_iter(buf, b.addr)
  result = $gtk_text_buffer_get_text(buf, a.addr, b.addr, cbool(1))

proc `bufferText=`(buf: GtkTextBuffer, text: string) =
  gtk_text_buffer_set_text(buf, text.cstring, text.len.cint)

proc placeCursorAt(buf: GtkTextBuffer, offset: int) =
  var it: GtkTextIter
  gtk_text_buffer_get_iter_at_offset(buf, it.addr, offset.cint)
  gtk_text_buffer_place_cursor(buf, it.addr)

proc liveCursorOffset(buf: GtkTextBuffer): int =
  var iter: GtkTextIter
  gtk_text_buffer_get_iter_at_mark(buf, iter.addr, gtk_text_buffer_get_insert(buf))
  result = int(gtk_text_iter_get_offset(iter.addr))

# -- Org-babel mode: proportional prose, monospace code blocks ------------
# No org parser here -- BabelHub (~/Downloads/BabelHub, a prior related
# project) confirmed a plain line scanner is enough for "which regions are
# code" (its src/exports.ts and src/srcedit.ts both just regex-match
# #+begin_src line by line, no AST). Font-family is set on plain GTK text
# tags via the exact pattern owlkettle's own TextBuffer.registerTag uses
# internally (widgets.nim:2358): gtk_text_buffer_create_tag with zero
# properties (name + immediate NULL -- the simplest possible varargs call),
# then g_object_set_property (fixed 3-arg signature, no varargs at all) to
# set "family". Deliberately not reusing owlkettle's TextBuffer wrapper
# itself, same reason as EditorTextView above.

var
  gProseTag, gCodeTag, gHeadingTag, gLinkTag, gHiddenTag: GtkTextTag
  gOrgMode = false
    ## Mirrors app.orgMode. bufferChangedCallback (a raw "changed" signal
    ## callback, connected in main() before the live AppState even exists)
    ## has no way to reach `app`, so it reads this instead. Both are only
    ## ever written together, in toggleOrgMode, so they can't drift.

proc gtk_text_tag_new(name: cstring): GtkTextTag {.importc, cdecl.}
proc gtk_text_tag_table_add(table: GtkTextTagTable; tag: GtkTextTag): cbool {.importc, cdecl.}
proc gtk_text_buffer_get_iter_at_line_offset(buffer: GtkTextBuffer; iter: ptr GtkTextIter;
                                              lineNum: cint; charOffset: cint) {.importc, cdecl.}

proc setStringProp(tag: GtkTextTag; prop, val: string) =
  var v: GValue
  discard g_value_init(v.addr, G_TYPE_STRING)
  g_value_set_string(v.addr, val.cstring)
  g_object_set_property(pointer(tag), prop.cstring, v.addr)

proc setIntProp(tag: GtkTextTag; prop: string; val: int) =
  var v: GValue
  discard g_value_init(v.addr, G_TYPE_INT)
  g_value_set_int(v.addr, cint(val))
  g_object_set_property(pointer(tag), prop.cstring, v.addr)

proc setBoolProp(tag: GtkTextTag; prop: string; val: bool) =
  var v: GValue
  discard g_value_init(v.addr, G_TYPE_BOOLEAN)
  g_value_set_boolean(v.addr, cbool(ord(val)))
  g_object_set_property(pointer(tag), prop.cstring, v.addr)

proc setupOrgTags(buf: GtkTextBuffer) =
  # Deliberately not gtk_text_buffer_create_tag -- that's a varargs C call
  # (like the file-chooser constructor that crashed earlier), and this GTK
  # version appears to mishandle at least some varargs FFI calls. This
  # path is fully fixed-arity: construct each tag directly, add it to the
  # buffer's tag table explicitly, no variadic call anywhere.
  let table = gtk_text_buffer_get_tag_table(buf)
  gProseTag = gtk_text_tag_new("nimacs-prose".cstring)
  gCodeTag = gtk_text_tag_new("nimacs-code".cstring)
  gHeadingTag = gtk_text_tag_new("nimacs-heading".cstring)
  gLinkTag = gtk_text_tag_new("nimacs-link".cstring)
  gHiddenTag = gtk_text_tag_new("nimacs-hidden".cstring)
  for tag in [gProseTag, gCodeTag, gHeadingTag, gLinkTag, gHiddenTag]:
    discard gtk_text_tag_table_add(table, tag)
  gProseTag.setStringProp("family", "Sans")        # generic Pango alias -> system proportional font
  gCodeTag.setStringProp("family", "Monospace")     # generic Pango alias -> system monospace font
  gHeadingTag.setStringProp("family", "Sans")
  gHeadingTag.setIntProp("weight", 700)             # PANGO_WEIGHT_BOLD
  gHeadingTag.setIntProp("size", 14 * 1024)         # Pango units (1/1024 pt) -- "size" confirmed working
                                                     # via isolated test; "scale" (double prop) was not
  gLinkTag.setStringProp("foreground", "#2563eb")
  gLinkTag.setIntProp("underline", 1)               # PANGO_UNDERLINE_SINGLE
  gHiddenTag.setBoolProp("invisible", true)

proc isBeginSrc(line: string): bool = strutils.strip(line).toLowerAscii().startsWith("#+begin_src")
proc isEndSrc(line: string): bool = strutils.strip(line).toLowerAscii() == "#+end_src"

proc isHeading(line: string): bool =
  ## Org headlines start at column 0 (unlike src blocks, which may be
  ## indented) with one or more literal `*` immediately followed by a
  ## space -- `* Title`, `** Subtitle`, etc.
  if line.len == 0 or line[0] != '*': return false
  var i = 0
  while i < line.len and line[i] == '*': inc i
  i < line.len and line[i] == ' '

type LinkMatch = tuple[matchStart, matchEnd, visStart, visEnd: int]
  ## [matchStart, matchEnd) is the whole `[[...]]` span; [visStart, visEnd)
  ## is the portion that stays visible (the description if present, else
  ## the URL) -- everything else in the match gets hidden.

proc findLinks(line: string): seq[LinkMatch] =
  ## Hand-rolled scanner for org's `[[url]]` / `[[url][description]]` link
  ## syntax -- no regex engine needed (and no new dependency to debug in
  ## this environment) for a syntax this simple to bracket-match.
  var i = 0
  while i < line.len - 1:
    if line[i] == '[' and line[i + 1] == '[':
      let matchStart = i
      var j = i + 2
      var urlEnd = -1
      while j < line.len:
        if line[j] == ']': urlEnd = j; break
        inc j
      if urlEnd == -1: break  # unterminated -- stop scanning this line
      if urlEnd + 1 < line.len and line[urlEnd + 1] == ']':
        result.add((matchStart, urlEnd + 2, matchStart + 2, urlEnd))  # [[url]] -- url itself stays visible
        i = urlEnd + 2
      elif urlEnd + 1 < line.len and line[urlEnd + 1] == '[':
        var k = urlEnd + 2
        var descEnd = -1
        while k < line.len:
          if line[k] == ']': descEnd = k; break
          inc k
        if descEnd == -1: break
        if descEnd + 1 < line.len and line[descEnd + 1] == ']':
          result.add((matchStart, descEnd + 2, urlEnd + 2, descEnd))  # [[url][desc]] -- only desc stays visible
          i = descEnd + 2
        else:
          inc i
      else:
        inc i
    else:
      inc i

proc retagLinks(buf: GtkTextBuffer; lineNum: int; lineText: string) =
  for m in findLinks(lineText):
    var prefixStart, visStart, visEnd, suffixEnd: GtkTextIter
    gtk_text_buffer_get_iter_at_line_offset(buf, prefixStart.addr, cint(lineNum), cint(m.matchStart))
    gtk_text_buffer_get_iter_at_line_offset(buf, visStart.addr, cint(lineNum), cint(m.visStart))
    gtk_text_buffer_get_iter_at_line_offset(buf, visEnd.addr, cint(lineNum), cint(m.visEnd))
    gtk_text_buffer_get_iter_at_line_offset(buf, suffixEnd.addr, cint(lineNum), cint(m.matchEnd))
    gtk_text_buffer_apply_tag(buf, gHiddenTag, prefixStart.addr, visStart.addr)
    gtk_text_buffer_apply_tag(buf, gLinkTag, visStart.addr, visEnd.addr)
    gtk_text_buffer_apply_tag(buf, gHiddenTag, visEnd.addr, suffixEnd.addr)

proc retagOrgBlocks(buf: GtkTextBuffer) =
  var bufStart, bufEnd: GtkTextIter
  gtk_text_buffer_get_start_iter(buf, bufStart.addr)
  gtk_text_buffer_get_end_iter(buf, bufEnd.addr)
  for tag in [gProseTag, gCodeTag, gHeadingTag, gLinkTag, gHiddenTag]:
    gtk_text_buffer_remove_tag(buf, tag, bufStart.addr, bufEnd.addr)
  if not gOrgMode:
    return  # toggled off -- tags cleared above, plain view, nothing more to do

  let lineCount = int(gtk_text_buffer_get_line_count(buf))
  var inSrc = false
  for lineNum in 0 ..< lineCount:
    var lineStart, lineEnd: GtkTextIter
    gtk_text_buffer_get_iter_at_line(buf, lineStart.addr, cint(lineNum))
    if lineNum + 1 < lineCount:
      gtk_text_buffer_get_iter_at_line(buf, lineEnd.addr, cint(lineNum + 1))
    else:
      gtk_text_buffer_get_end_iter(buf, lineEnd.addr)
    let lineText = $gtk_text_buffer_get_text(buf, lineStart.addr, lineEnd.addr, cbool(0))
    # Delimiter lines are tagged as code too, matching org-mode's own
    # behavior of fixed-pitching the whole block including its markers.
    # isEndSrc must be checked before `inSrc` itself -- the end marker line
    # is still *inside* the block (inSrc is still true when we reach it),
    # so checking `inSrc or ...` first would always match and this branch,
    # where inSrc actually gets reset, would never run -- inSrc would get
    # stuck true forever after the first code block in the document.
    if isEndSrc(lineText):
      gtk_text_buffer_apply_tag(buf, gCodeTag, lineStart.addr, lineEnd.addr)
      inSrc = false
    elif inSrc or isBeginSrc(lineText):
      gtk_text_buffer_apply_tag(buf, gCodeTag, lineStart.addr, lineEnd.addr)
      if isBeginSrc(lineText): inSrc = true
    elif isHeading(lineText):
      gtk_text_buffer_apply_tag(buf, gHeadingTag, lineStart.addr, lineEnd.addr)
    else:
      gtk_text_buffer_apply_tag(buf, gProseTag, lineStart.addr, lineEnd.addr)
      retagLinks(buf, lineNum, lineText)

proc bufferChangedCallback(buf: GtkTextBuffer; userData: pointer) {.cdecl.} =
  if gOrgMode:
    retagOrgBlocks(buf)

# -- EditorTextView: a GtkTextView we build ourselves, with a key-press ----
# interceptor. A ref-object holds the live closure; its address is handed
# to g_signal_connect as the callback's `data`, mirroring owlkettle's own
# CustomWidget pattern for exactly the same reason (a cdecl callback can't
# capture a Nim closure directly).

type
  KeyHandlerObj = object
    onKeyPress: proc (keyval: int, ctrl, shift: bool, cursorPos: int): bool
  KeyHandler = ref KeyHandlerObj

proc keyPressedCallback(controller: GtkEventController; keyval, keycode: cuint;
                         state: GdkModifierType; data: pointer): cbool {.cdecl.} =
  let h = cast[ptr KeyHandlerObj](data)
  if h.onKeyPress.isNil:
    return cbool(0)
  let ctrl = GDK_CONTROL_MASK in state
  let shift = GDK_SHIFT_MASK in state
  let widget = gtk_event_controller_get_widget(controller)
  let buf = gtk_text_view_get_buffer(widget)
  result = cbool(ord(h.onKeyPress(int(keyval), ctrl, shift, buf.liveCursorOffset())))

renderable EditorTextView of BaseWidget:
  gtkBuffer: GtkTextBuffer
  monospace: bool = false
  cursorVisible: bool = true
  editable: bool = true
  acceptsTab: bool = true
  handler {.private, onlyState.}: KeyHandler

  proc onKeyPress(keyval: int, ctrl, shift: bool, cursorPos: int): bool

  hooks:
    beforeBuild:
      state.internalWidget = gtk_text_view_new()
    build:
      state.handler = KeyHandler()
      let controller = gtk_event_controller_key_new()
      gtk_event_controller_set_propagation_phase(controller, GtkPhaseCapture)
      discard g_signal_connect(controller, "key-pressed", keyPressedCallback, state.handler[].addr)
      gtk_widget_add_controller(state.internalWidget, controller)
    connectEvents:
      state.handler.onKeyPress =
        if state.onKeyPress.isNil: nil else: state.onKeyPress.callback

  hooks gtkBuffer:
    property:
      gtk_text_view_set_buffer(state.internalWidget, state.gtkBuffer)

  hooks monospace:
    property:
      gtk_text_view_set_monospace(state.internalWidget, cbool(ord(state.monospace)))

  hooks cursorVisible:
    property:
      gtk_text_view_set_cursor_visible(state.internalWidget, cbool(ord(state.cursorVisible)))

  hooks editable:
    property:
      gtk_text_view_set_editable(state.internalWidget, cbool(ord(state.editable)))

  hooks acceptsTab:
    property:
      gtk_text_view_set_accepts_tab(state.internalWidget, cbool(ord(state.acceptsTab)))

# -- Keychord translation --------------------------------------------------
# Only chords with an explicit modifier are ever routed to the reloadable
# command table (see keychord below); a bare unmodified keypress always
# builds a chord too, but since config.nim's example bindings are all
# Ctrl-prefixed, an unbound bare-letter chord simply misses the table and
# falls through to GTK's own native self-insert -- exactly the "everything
# through the keymap, unbound falls back to plain insert" behavior.

proc keychord(keyval: int, ctrl, shift: bool): string =
  let cp = gdk_keyval_to_unicode(keyval.cuint)
  if cp == 0:
    return ""  # non-printable (arrows, Escape, ...) -- never routed, always native
  let ch = ($Rune(cp)).toLowerAscii()
  result = ""
  if ctrl: result &= "C-"
  if shift: result &= "S-"
  result &= ch

# -- App ---------------------------------------------------------------

viewable App:
  gtkBuffer: GtkTextBuffer
  status: string
  filePath: string
  configPath: string
  configSearchPaths: seq[string]
  dispatch: Dispatch
  orgMode: bool
  pendingPrefix: string  ## partial key sequence, e.g. "C-c" awaiting its second chord

proc toggleOrgMode(app: AppState, state: bool) =
  app.orgMode = state
  gOrgMode = state
  retagOrgBlocks(app.gtkBuffer)  # apply/clear immediately, don't wait for the next edit
  app.status = if state: "Org babel mode on" else: "Org babel mode off"

proc saveFile(app: AppState) =
  if app.filePath == "":
    app.status = "No file -- pass a path on the command line to enable saving"
    return
  writeFile(app.filePath, app.gtkBuffer.bufferText)
  app.status = "Saved " & app.filePath

proc doReload(app: AppState) =
  let (ok, msg) = app.dispatch.reloadConfig(app.configPath, app.configSearchPaths)
  app.status = msg
  discard ok

proc editConfig(app: AppState) =
  # Single-buffer editor -- "edit config" means load config.nim's text into
  # the one buffer we have and repoint filePath at it, so Ctrl+S saves back
  # to config.nim directly. Whatever was in the buffer before is not saved
  # first (matches this project's current no-multiple-buffers scope).
  app.gtkBuffer.bufferText = readFile(app.configPath)
  app.filePath = app.configPath
  app.status = "Editing " & app.configPath & " -- C-s to save, then Reload Config"

proc fileOpenCallback(sourceObject: pointer; res: pointer; userData: pointer) {.cdecl.} =
  # Runs asynchronously, outside owlkettle's own event-dispatch machinery
  # (same situation as handleKey) -- app.redraw() is needed explicitly.
  let app = cast[AppState](userData)
  var err: GError = nil
  let file = gtk_file_dialog_open_finish(GtkFileDialog(sourceObject), res, err.addr)
  if pointer(file) != nil:
    let path = $g_file_get_path(file)
    if fileExists(path):
      app.gtkBuffer.bufferText = readFile(path)
      app.filePath = path
      app.status = "Opened " & path
  # else: user cancelled -- err is set to "Dismissed by user", not a real
  # failure, so there's nothing to report.
  discard app.redraw()

proc openFile(app: AppState) =
  let dialog = gtk_file_dialog_new()
  gtk_file_dialog_set_title(dialog, "Open File".cstring)
  let parentWindow = app.unwrapInternalWidget()
  gtk_file_dialog_open(dialog, parentWindow, nil, fileOpenCallback, cast[pointer](app))

proc runCommand(app: AppState, cursorPos: int, cmd: CommandProc) =
  var k = EditorKernel(
    text: app.gtkBuffer.bufferText,
    cursorPos: cursorPos,
    status: "",
  )
  cmd(k.addr)
  app.gtkBuffer.bufferText = k.text
  app.gtkBuffer.placeCursorAt(k.cursorPos)
  if k.status != "":
    app.status = k.status

# -- Org-babel execution: run a src block, capture output, write #+RESULTS --
# C-c C-c on a `#+begin_src R ... #+end_src` block runs the body through
# Rscript and inserts (or replaces) a `#+RESULTS:` block right after the
# block, one `: `-prefixed line per output line -- exactly how org-mode
# renders `:results output`. Synchronous, matching org-babel's own C-c C-c:
# the UI blocks until Rscript returns. Only R is wired up so far.

proc lineOfOffset(text: string; offset: int): int =
  ## 0-based index of the line containing character `offset`.
  let stop = min(offset, text.len)
  for i in 0 ..< stop:
    if text[i] == '\n': inc result

proc runRscript(code: string): tuple[ok: bool, output: string] =
  ## Write `code` to a temp .R file and run it with Rscript, capturing
  ## stdout and stderr merged (so warnings/messages land in the results too).
  let path = genTempPath("nimacs-babel-", ".R")
  writeFile(path, code)
  defer: removeFile(path)
  try:
    let output = execProcess("Rscript", args = ["--vanilla", path],
                             options = {poStdErrToStdOut, poUsePath})
    result = (true, output)
  except OSError:
    result = (false, "Rscript not found on PATH -- install R to run src blocks")

# -- Persistent R sessions (`:session` header arg) -------------------------
# A `#+begin_src R :session foo` block runs against a long-lived R process
# (one per session name), so variables, loaded packages, and options carry
# across blocks -- matching org-babel's `:session` semantics. Blocks with no
# `:session` keep using the one-shot runRscript path above.
#
# Protocol: an R driver (.nimacs_run) injected at session startup reads a
# block from a temp file, sinks both output and messages into a buffer while
# evaluating it in the global env (so errors are caught and the session
# survives), then replays that buffer to stdout bracketed by BOR/EOR markers.
# The host writes ".nimacs_run(path)" to the process's stdin and reads its
# stdout until the EOR marker. Verified against R interactively; see the
# scratch harness this was built from.

const rSessionMarkerBegin = "__NIMACS_BOR__"
const rSessionMarkerEnd = "__NIMACS_END__"
const rSessionDriver = """
.nimacs_run <- function(path) {
  cat(""" & '"' & rSessionMarkerBegin & '"' & """, "\n", sep = "")
  con <- textConnection("._nimacs_buf", "w")
  sink(con); sink(con, type = "message")
  options(warn = 1)
  tryCatch(source(path, echo = FALSE, print.eval = TRUE, spaced = FALSE, max.deparse.length = Inf),
           error = function(e) cat("Error:", conditionMessage(e), "\n"))
  sink(type = "message"); sink(); close(con)
  cat(._nimacs_buf, sep = "\n")
  cat("\n", """ & '"' & rSessionMarkerEnd & '"' & """, "\n", sep = "")
  flush(stdout())
}
"""

var gRSessions: Table[string, Process]  ## session name -> live R process

proc getRSession(name: string): Process =
  ## Return the running R process for `name`, spawning (and priming with the
  ## driver) a fresh one if none exists or the previous one has exited.
  if gRSessions.hasKey(name) and gRSessions[name].running:
    return gRSessions[name]
  let p = startProcess("R", args = ["--interactive", "--quiet", "--no-save", "--no-restore"],
                       options = {poUsePath, poStdErrToStdOut})
  p.inputStream.write(rSessionDriver & "\n")
  p.inputStream.flush()
  gRSessions[name] = p
  p

proc runInSession(name, code: string): tuple[ok: bool, output: string] =
  var p: Process
  try:
    p = getRSession(name)
  except OSError:
    return (false, "R not found on PATH -- install R to run :session src blocks")
  let path = genTempPath("nimacs-babel-", ".R")
  writeFile(path, code)
  p.inputStream.write(".nimacs_run(\"" & path & "\")\n")
  p.inputStream.flush()
  let outStream = p.outputStream
  var collecting = false
  var lines: seq[string]
  while true:
    var line: string
    if not outStream.readLine(line): break  # process died before EOR
    if line == rSessionMarkerEnd: break
    if collecting: lines.add(line)
    if line == rSessionMarkerBegin: collecting = true
  removeFile(path)
  while lines.len > 0 and strutils.strip(lines[^1]) == "": lines.setLen(lines.len - 1)
  (true, lines.join("\n"))

proc shutdownRSessions() =
  ## Ask every live session to quit cleanly, then release its handle. Called
  ## once the app's window closes so no R processes are left behind.
  for name, p in gRSessions:
    if p.running:
      try:
        p.inputStream.write("quit(save=\"no\")\n")
        p.inputStream.flush()
      except IOError, OSError:
        discard
      discard p.waitForExit()
    p.close()
  gRSessions.clear()

proc executeSrcBlock(app: AppState; cursorPos: int) =
  let text = app.gtkBuffer.bufferText
  let lines = text.split('\n')
  let cursorLine = lineOfOffset(text, cursorPos)

  # Find the enclosing #+begin_src by scanning up; bail if we cross an
  # #+end_src first -- that means the cursor sits below a block, not in one.
  var beginIdx = -1
  var i = cursorLine
  while i >= 0:
    if i < cursorLine and isEndSrc(lines[i]): break
    if isBeginSrc(lines[i]): beginIdx = i; break
    dec i
  if beginIdx == -1:
    app.status = "C-c C-c: not inside a #+begin_src block"
    return

  # Find its #+end_src scanning down.
  var endIdx = -1
  var j = beginIdx + 1
  while j < lines.len:
    if isEndSrc(lines[j]): endIdx = j; break
    if isBeginSrc(lines[j]): break  # next block starts -- this one is unterminated
    inc j
  if endIdx == -1 or cursorLine > endIdx:
    app.status = "C-c C-c: not inside a terminated #+begin_src block"
    return

  # Language token: `#+begin_src R :results output` -> "r".
  let beginTokens = strutils.splitWhitespace(strutils.strip(lines[beginIdx]))
  let lang = if beginTokens.len >= 2: beginTokens[1].toLowerAscii() else: ""
  if lang != "r":
    app.status = "C-c C-c: only R src blocks are supported (got '" &
      (if lang == "": "none" else: lang) & "')"
    return

  # Header args after the language token, e.g. `:session foo :results output`.
  # `:session name` runs in a persistent process; `:session` alone uses the
  # session named "default"; absent, each run is a one-shot Rscript.
  var sessionName = ""
  var t = 2
  while t < beginTokens.len:
    if beginTokens[t] == ":session":
      sessionName =
        if t + 1 < beginTokens.len and not beginTokens[t + 1].startsWith(":"):
          beginTokens[t + 1]
        else:
          "default"
    inc t

  let code = lines[beginIdx + 1 ..< endIdx].join("\n")
  let (ok, rawOut) =
    if sessionName != "": runInSession(sessionName, code)
    else: runRscript(code)
  if not ok:
    app.status = rawOut
    return

  # Build the results block: `#+RESULTS:` then one `: `-prefixed line per
  # output line. Trailing whitespace/newlines from Rscript are trimmed first.
  var resultLines = @["#+RESULTS:"]
  let trimmed = strutils.strip(rawOut, leading = false, trailing = true)
  if trimmed.len > 0:
    for outLine in trimmed.split('\n'):
      resultLines.add(": " & outLine)

  # Splice the results in after #+end_src, replacing any existing #+RESULTS
  # block (the `#+RESULTS:` line plus the `:`-prefixed lines under it), so
  # re-running updates in place rather than stacking a second block.
  var afterIdx = endIdx + 1
  var scan = afterIdx
  while scan < lines.len and strutils.strip(lines[scan]) == "": inc scan
  if scan < lines.len and strutils.strip(lines[scan]).toLowerAscii().startsWith("#+results:"):
    var q = scan + 1
    while q < lines.len and lines[q].len > 0 and lines[q][0] == ':': inc q
    afterIdx = q

  var newLines: seq[string]
  newLines.add(lines[0 .. endIdx])
  newLines.add("")            # blank line between the block and its results
  newLines.add(resultLines)
  if afterIdx <= lines.high:
    newLines.add(lines[afterIdx .. ^1])

  # Cursor to the start of the #+RESULTS: line (index endIdx+2 in newLines:
  # lines[0..endIdx], then the blank, then the results header) so it scrolls
  # into view after running.
  var resultsOffset = 0
  for k in 0 ..< endIdx + 2:
    resultsOffset += newLines[k].len + 1

  app.gtkBuffer.bufferText = newLines.join("\n")
  app.gtkBuffer.placeCursorAt(resultsOffset)
  let where = if sessionName != "": "R session :" & sessionName else: "R (one-shot)"
  app.status = "Executed " & where & " -- " & $(resultLines.len - 1) & " result line(s)"

proc handleKey(app: AppState, keyval: int, ctrl, shift: bool, cursorPos: int): bool =
  # Built-in bindings are host-level and always active, regardless of
  # whatever config.nim currently has bound -- rebinding them away would be
  # a footgun (e.g. losing the only way to trigger a reload).
  let chord = keychord(keyval, ctrl, shift)
  if chord == "": return false

  # Two-key prefix sequences: C-c starts one, the next chord completes it.
  # Currently the only completion is `C-c C-c` -> run the src block at point.
  if app.pendingPrefix == "C-c":
    app.pendingPrefix = ""
    if chord == "C-c":
      app.executeSrcBlock(cursorPos)
      discard app.redraw()
      return true
    # any other chord: prefix abandoned, fall through to normal handling

  if chord == "C-c":
    app.pendingPrefix = "C-c"
    app.status = "C-c-"
    discard app.redraw()
    return true

  if chord == "C-S-r":
    app.doReload()
  elif chord == "C-s":
    app.saveFile()
  else:
    let cmd = app.dispatch.lookup(chord)
    if cmd == nil:
      return false
    app.runCommand(cursorPos, cmd)
  # Unlike owlkettle's own declarative event hooks (e.g. Button.clicked),
  # this callback is wired directly to a raw GtkEventControllerKey outside
  # owlkettle's event-dispatch machinery, so nothing auto-redraws after it
  # runs -- app.status changes in memory but the status Label never
  # repaints without this.
  discard app.redraw()
  result = true

method view(app: AppState): Widget =
  result = gui:
    Window:
      title = "nimacs"
      defaultSize = (900, 650)

      HeaderBar {.addTitlebar.}:
        Button {.addLeft.}:
          style = [ButtonFlat]
          tooltip = "Open a file"
          Icon(name = "document-open-symbolic")
          proc clicked() = app.openFile()

        Button {.addLeft.}:
          style = [ButtonFlat]
          tooltip = "Save (Ctrl+S)"
          Icon(name = "document-save-symbolic")
          proc clicked() = app.saveFile()

        Button {.addLeft.}:
          style = [ButtonFlat]
          tooltip = "Edit config.nim"
          Icon(name = "document-edit-symbolic")
          proc clicked() = app.editConfig()

        Button {.addLeft.}:
          style = [ButtonSuggested]
          tooltip = "Reload Config (Ctrl+Shift+R)"
          Icon(name = "view-refresh-symbolic")
          proc clicked() = app.doReload()

        ToggleButton {.addLeft.}:
          tooltip = "Org babel mode (proportional prose, monospace code blocks)"
          state = app.orgMode
          Icon(name = "format-text-rich-symbolic")
          proc changed(state: bool) = app.toggleOrgMode(state)

      Box(orient = OrientY):
        ScrolledWindow {.expand: true.}:
          EditorTextView:
            margin = 12
            gtkBuffer = app.gtkBuffer
            monospace = true
            cursorVisible = true
            editable = true
            acceptsTab = true
            proc onKeyPress(keyval: int, ctrl, shift: bool, cursorPos: int): bool =
              app.handleKey(keyval, ctrl, shift, cursorPos)

        Label(text = app.status) {.expand: false.}:
          margin = 6
          xalign = 0.0

proc setupIconTheme() =
  # GTK looks up icon themes (Adwaita, for the header-bar button icons) via
  # XDG_DATA_DIRS/share/icons. Not set by default, and the conda env's own
  # icon theme lives under $CONDA_PREFIX/share -- without this, the icons
  # silently fail to resolve (no crash, just blank buttons).
  let condaPrefix = getEnv("CONDA_PREFIX")
  if condaPrefix.len > 0:
    let existing = getEnv("XDG_DATA_DIRS")
    let dirs = condaPrefix / "share" & (if existing.len > 0: ":" & existing else: ":/usr/local/share:/usr/share")
    putEnv("XDG_DATA_DIRS", dirs)

proc main() =
  setupIconTheme()
  let args = commandLineParams()
  let filePath = if args.len > 0: args[0] else: ""
  let gtkBuffer = newGtkTextBuffer()
  var startInOrgMode = false
  if filePath != "" and fileExists(filePath):
    gtkBuffer.bufferText = readFile(filePath)
  elif filePath == "":
    # No file given -- load the built-in example so the editor isn't blank,
    # with Org babel mode on so its R src block renders monospace.
    gtkBuffer.bufferText = welcomeOrg
    startInOrgMode = true

  setupOrgTags(gtkBuffer)
  gOrgMode = startInOrgMode
  retagOrgBlocks(gtkBuffer)  # apply org tags to the initial text before first draw
  discard g_signal_connect_data(pointer(gtkBuffer), "changed".cstring,
    cast[pointer](bufferChangedCallback), nil, nil, G_CONNECT_AFTER)

  let projectRoot = getAppDir()
  let configPath = projectRoot / "config.nim"
  let searchPaths = @[projectRoot / "src"]

  let dispatch = newDispatch(cacheKey())
  let (ok, msg) = dispatch.reloadConfig(configPath, searchPaths)
  let initialStatus = if ok: msg else: "config load failed: " & msg

  # `gui(...)` is the DSL entry point -- it's what translates the
  # `field = value` syntax into the widget's real hasX/valX pairs, so the
  # App constructor must be wrapped in it too, not called plainly.
  adw.brew(gui(App(
    gtkBuffer = gtkBuffer,
    status = initialStatus,
    filePath = filePath,
    configPath = configPath,
    configSearchPaths = searchPaths,
    dispatch = dispatch,
    orgMode = startInOrgMode,
  )))

  # brew() returns once the window closes -- tear down any R sessions we
  # spawned so no background R processes are left running.
  shutdownRSessions()

when isMainModule:
  main()
