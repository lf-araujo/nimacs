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

import std/[os, unicode, strutils]
import owlkettle
import owlkettle/adw
import owlkettle/bindings/gtk
import nimacs/[kernel, dispatch, hotcompile]

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
  gProseTag, gCodeTag: GtkTextTag
  gOrgMode = false
    ## Mirrors app.orgMode. bufferChangedCallback (a raw "changed" signal
    ## callback, connected in main() before the live AppState even exists)
    ## has no way to reach `app`, so it reads this instead. Both are only
    ## ever written together, in toggleOrgMode, so they can't drift.

proc gtk_text_tag_new(name: cstring): GtkTextTag {.importc, cdecl.}
proc gtk_text_tag_table_add(table: GtkTextTagTable; tag: GtkTextTag): cbool {.importc, cdecl.}

proc setFontFamily(tag: GtkTextTag; family: string) =
  var value: GValue
  discard g_value_init(value.addr, G_TYPE_STRING)
  g_value_set_string(value.addr, family.cstring)
  g_object_set_property(pointer(tag), "family".cstring, value.addr)

proc setupOrgTags(buf: GtkTextBuffer) =
  # Deliberately not gtk_text_buffer_create_tag -- that's a varargs C call
  # (like the file-chooser constructor that crashed earlier), and this GTK
  # version appears to mishandle at least some varargs FFI calls. This
  # path is fully fixed-arity: construct the tag directly, add it to the
  # buffer's tag table explicitly, no variadic call anywhere.
  let table = gtk_text_buffer_get_tag_table(buf)
  gProseTag = gtk_text_tag_new("nimacs-prose".cstring)
  gCodeTag = gtk_text_tag_new("nimacs-code".cstring)
  discard gtk_text_tag_table_add(table, gProseTag)
  discard gtk_text_tag_table_add(table, gCodeTag)
  gProseTag.setFontFamily("Sans")       # generic Pango alias -> system proportional font
  gCodeTag.setFontFamily("Monospace")   # generic Pango alias -> system monospace font

proc isBeginSrc(line: string): bool = line.strip().toLowerAscii().startsWith("#+begin_src")
proc isEndSrc(line: string): bool = line.strip().toLowerAscii() == "#+end_src"

proc retagOrgBlocks(buf: GtkTextBuffer) =
  var bufStart, bufEnd: GtkTextIter
  gtk_text_buffer_get_start_iter(buf, bufStart.addr)
  gtk_text_buffer_get_end_iter(buf, bufEnd.addr)
  gtk_text_buffer_remove_tag(buf, gProseTag, bufStart.addr, bufEnd.addr)
  gtk_text_buffer_remove_tag(buf, gCodeTag, bufStart.addr, bufEnd.addr)
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
    let isCodeLine = inSrc or isBeginSrc(lineText)
    gtk_text_buffer_apply_tag(buf, (if isCodeLine: gCodeTag else: gProseTag), lineStart.addr, lineEnd.addr)
    if isBeginSrc(lineText): inSrc = true
    elif isEndSrc(lineText): inSrc = false

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

proc handleKey(app: AppState, keyval: int, ctrl, shift: bool, cursorPos: int): bool =
  # Built-in bindings are host-level and always active, regardless of
  # whatever config.nim currently has bound -- rebinding them away would be
  # a footgun (e.g. losing the only way to trigger a reload).
  let chord = keychord(keyval, ctrl, shift)
  if chord == "": return false
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

        Label(text = app.status):
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
  if filePath != "" and fileExists(filePath):
    gtkBuffer.bufferText = readFile(filePath)

  setupOrgTags(gtkBuffer)
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
  )))

when isMainModule:
  main()
