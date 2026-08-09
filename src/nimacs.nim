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

import std/[os, unicode, strutils, osproc, tempfiles, tables, posix, algorithm]

when not declared(posix_openpt):
  proc posix_openpt(flags: cint): cint {.importc, header: "<stdlib.h>".}
when not declared(grantpt):
  proc grantpt(fd: cint): cint {.importc, header: "<stdlib.h>".}
when not declared(unlockpt):
  proc unlockpt(fd: cint): cint {.importc, header: "<stdlib.h>".}
when not declared(ptsname):
  proc ptsname(fd: cint): cstring {.importc, header: "<stdlib.h>".}
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

# -- GtkSourceView FFI -----------------------------------------------------
# Bound directly against the runtime soname (no pkg-config/dev files needed,
# and none are installed on Solus anyway). GtkSourceBuffer is-a GtkTextBuffer
# and GtkSourceView is-a GtkTextView, so every existing helper, tag, and hook
# keeps working -- we only swap the two constructors and add highlighting
# setup. Style schemes are compiled into the .so; only the .lang language
# definitions must be shipped (see setupSourceHighlighting). Verified against
# libgtksourceview-5.so.0 with the vendored def/R/nim specs.
const sourceLib = "libgtksourceview-5.so.0"
proc gtk_source_buffer_new(table: pointer): GtkTextBuffer {.importc, cdecl, dynlib: sourceLib.}
proc gtk_source_view_new(): GtkWidget {.importc, cdecl, dynlib: sourceLib.}
proc gtk_source_language_manager_new(): pointer {.importc, cdecl, dynlib: sourceLib.}
proc gtk_source_language_manager_set_search_path(lm: pointer; dirs: cstringArray) {.importc, cdecl, dynlib: sourceLib.}
proc gtk_source_language_manager_get_language(lm: pointer; id: cstring): pointer {.importc, cdecl, dynlib: sourceLib.}
proc gtk_source_buffer_set_language(buf: GtkTextBuffer; lang: pointer) {.importc, cdecl, dynlib: sourceLib.}
proc gtk_source_buffer_set_highlight_syntax(buf: GtkTextBuffer; highlight: cbool) {.importc, cdecl, dynlib: sourceLib.}
proc gtk_source_style_scheme_manager_get_default(): pointer {.importc, cdecl, dynlib: sourceLib.}
proc gtk_source_style_scheme_manager_get_scheme(sm: pointer; id: cstring): pointer {.importc, cdecl, dynlib: sourceLib.}
proc gtk_source_buffer_set_style_scheme(buf: GtkTextBuffer; scheme: pointer) {.importc, cdecl, dynlib: sourceLib.}
proc gtk_source_view_get_completion(view: GtkWidget): pointer {.importc, cdecl, dynlib: sourceLib.}
proc gtk_source_completion_words_new(title: cstring): pointer {.importc, cdecl, dynlib: sourceLib.}
proc gtk_source_completion_words_register(words: pointer; buf: GtkTextBuffer) {.importc, cdecl, dynlib: sourceLib.}
proc gtk_source_completion_add_provider(completion: pointer; provider: pointer) {.importc, cdecl, dynlib: sourceLib.}
proc gtk_source_view_set_show_line_numbers(view: GtkWidget; show: cbool) {.importc, cdecl, dynlib: sourceLib.}
proc gtk_source_view_set_highlight_current_line(view: GtkWidget; highlight: cbool) {.importc, cdecl, dynlib: sourceLib.}
proc gtk_source_view_set_auto_indent(view: GtkWidget; enable: cbool) {.importc, cdecl, dynlib: sourceLib.}
proc gtk_source_view_set_show_right_margin(view: GtkWidget; show: cbool) {.importc, cdecl, dynlib: sourceLib.}
proc gtk_source_view_set_right_margin_position(view: GtkWidget; pos: cuint) {.importc, cdecl, dynlib: sourceLib.}
# Search & replace (GtkSourceSearchContext highlights and iterates matches).
proc gtk_source_search_settings_new(): pointer {.importc, cdecl, dynlib: sourceLib.}
proc gtk_source_search_settings_set_search_text(settings: pointer; text: cstring) {.importc, cdecl, dynlib: sourceLib.}
proc gtk_source_search_settings_set_wrap_around(settings: pointer; wrap: cbool) {.importc, cdecl, dynlib: sourceLib.}
proc gtk_source_search_context_new(buffer: GtkTextBuffer; settings: pointer): pointer {.importc, cdecl, dynlib: sourceLib.}
proc gtk_source_search_context_set_highlight(context: pointer; highlight: cbool) {.importc, cdecl, dynlib: sourceLib.}
proc gtk_source_search_context_forward(context: pointer; iter, matchStart, matchEnd: ptr GtkTextIter; hasWrapped: ptr cbool): cbool {.importc, cdecl, dynlib: sourceLib.}
proc gtk_source_search_context_backward(context: pointer; iter, matchStart, matchEnd: ptr GtkTextIter; hasWrapped: ptr cbool): cbool {.importc, cdecl, dynlib: sourceLib.}
proc gtk_source_search_context_replace(context: pointer; matchStart, matchEnd: ptr GtkTextIter; replace: cstring; replaceLength: int; error: ptr pointer): cbool {.importc, cdecl, dynlib: sourceLib.}
proc gtk_source_search_context_replace_all(context: pointer; replace: cstring; replaceLength: int; error: ptr pointer): cuint {.importc, cdecl, dynlib: sourceLib.}
# Core GTK: scroll the view to a match (owlkettle already binds select_range,
# get_selection_bounds, get_iter_at_offset, place_cursor).
proc gtk_text_view_scroll_to_iter(view: GtkWidget; iter: ptr GtkTextIter; withinMargin: cdouble; useAlign: cbool; xalign, yalign: cdouble): cbool {.importc, cdecl.}

# -- VTE terminal FFI ------------------------------------------------------
# Runtime-bound like GtkSourceView (no dev/pkg-config files). VteTerminal is-a
# GtkWidget, so it drops straight into the owlkettle widget tree.
const vteLib = "libvte-2.91-gtk4.so.0"
proc vte_terminal_new(): GtkWidget {.importc, cdecl, dynlib: vteLib.}
proc vte_terminal_set_scrollback_lines(term: GtkWidget; lines: clong) {.importc, cdecl, dynlib: vteLib.}
proc vte_terminal_set_size(term: GtkWidget; columns, rows: clong) {.importc, cdecl, dynlib: vteLib.}
proc vte_terminal_feed_child(term: GtkWidget; text: cstring; length: int) {.importc, cdecl, dynlib: vteLib.}
proc vte_terminal_feed(term: GtkWidget; data: pointer; length: int) {.importc, cdecl, dynlib: vteLib.}
proc vte_terminal_reset(term: GtkWidget; clearTabstops, clearHistory: cbool) {.importc, cdecl, dynlib: vteLib.}
# GLib fd watch (libglib, already linked) to pump the session PTY into VTE.
proc g_unix_fd_add(fd: cint; condition: cint; function: pointer; userData: pointer): cuint {.importc, cdecl.}
proc g_source_remove(tag: cuint): cbool {.importc, cdecl.}

# The terminal displays one session at a time (latest); these track it.
var gTerminalVte = GtkWidget(nil)   ## the live VTE widget, or nil when closed
var gTerminalMaster: cint = -1      ## displayed session's PTY master fd
var gTerminalSession = ""           ## displayed session name

# -- App CSS (header-bar height, and a hook for future theming) -------------
# Core GTK symbols, linked against the same libgtk-4 owlkettle already uses.
proc gtk_css_provider_new(): pointer {.importc, cdecl.}
proc gtk_css_provider_load_from_data(provider: pointer; data: cstring; length: int) {.importc, cdecl.}
proc gtk_css_provider_load_from_string(provider: pointer; css: cstring) {.importc, cdecl.}
proc gdk_display_get_default(): pointer {.importc, cdecl.}
proc gtk_style_context_add_provider_for_display(display: pointer; provider: pointer; priority: cuint) {.importc, cdecl.}

# -- Unsaved-changes confirmation (AdwAlertDialog) --------------------------
# libadwaita's modern alert dialog is fixed-arity (unlike the varargs
# GtkAlertDialog this codebase avoids). Linked via libadwaita (owlkettle/adw).
proc adw_alert_dialog_new(heading, body: cstring): pointer {.importc, cdecl.}
proc adw_alert_dialog_add_response(dialog: pointer; id, label: cstring) {.importc, cdecl.}
proc adw_alert_dialog_set_response_appearance(dialog: pointer; id: cstring; appearance: cint) {.importc, cdecl.}
proc adw_alert_dialog_set_default_response(dialog: pointer; id: cstring) {.importc, cdecl.}
proc adw_alert_dialog_set_close_response(dialog: pointer; id: cstring) {.importc, cdecl.}
proc adw_dialog_present(dialog: pointer; parent: GtkWidget) {.importc, cdecl.}
# owlkettle exposes get_modified but not set_modified; bind it ourselves.
proc gtk_text_buffer_set_modified(buffer: GtkTextBuffer; setting: cbool) {.importc, cdecl.}
# Light/dark detection, to pick a header icon colour with real contrast.
proc adw_style_manager_get_default(): pointer {.importc, cdecl.}
proc adw_style_manager_get_dark(manager: pointer): cbool {.importc, cdecl.}

var gCssLoaded = false
proc loadAppCss() =
  ## Install the app stylesheet display-wide at APPLICATION priority (600),
  ## which overrides the Adwaita theme. Idempotent; needs GTK initialised, so
  ## it's called from a widget build hook rather than before brew().
  if gCssLoaded: return
  let display = gdk_display_get_default()
  if display == nil: return
  # Force a header foreground with contrast: dark icons on a light header,
  # light icons on a dark one -- fixes symbolic icons rendering near-invisible.
  let dark = adw_style_manager_get_dark(adw_style_manager_get_default()) != cbool(0)
  let fg = if dark: "#f0f0f0" else: "#2e2e2e"
  # Slim, compact header bar. min-height on the headerbar alone isn't enough --
  # the buttons' own min-height drives the height -- and button sizes must stay
  # non-zero or the icons get requested at size 0 and fail.
  let css =
    "headerbar { min-height: 26px; padding-top: 0; padding-bottom: 0; }\n" &
    "headerbar button, headerbar .toggle {\n" &
    "  min-height: 22px; min-width: 22px; padding: 1px 8px;\n" &
    "  margin-top: 2px; margin-bottom: 2px; color: " & fg & ";\n" &
    "}\n" &
    "headerbar button image { color: " & fg & "; }\n"
  let provider = gtk_css_provider_new()
  gtk_css_provider_load_from_string(provider, css.cstring)
  gtk_style_context_add_provider_for_display(display, provider, 600)
  gCssLoaded = true

var gEditorView = GtkWidget(nil)  ## the live GtkSourceView, for scroll-to-match
var gFontPt = 11              ## editor font size in points, adjusted by zoom
var gZoomProvider: pointer = nil
proc applyZoom() =
  ## Set the editor font size via a dedicated CSS provider (priority 601, above
  ## the app stylesheet). Called from key handlers, so GTK is initialised.
  let display = gdk_display_get_default()
  if display == nil: return
  if gZoomProvider == nil:
    gZoomProvider = gtk_css_provider_new()
    gtk_style_context_add_provider_for_display(display, gZoomProvider, 601)
  gtk_css_provider_load_from_string(gZoomProvider,
    ("textview { font-size: " & $gFontPt & "pt; }").cstring)

# -- Raw GtkTextBuffer helpers ---------------------------------------------

proc newGtkTextBuffer(): GtkTextBuffer =
  # A GtkSourceBuffer (subclass of GtkTextBuffer) so code files can be syntax
  # highlighted; for org/plain buffers it behaves exactly like a plain one.
  gtk_source_buffer_new(nil)

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
  gTitleTag, gMetaTag: GtkTextTag  ## #+TITLE: (large) and #+AUTHOR:/#+DATE: (medium)
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
  gTitleTag = gtk_text_tag_new("nimacs-title".cstring)
  gMetaTag = gtk_text_tag_new("nimacs-meta".cstring)
  for tag in [gProseTag, gCodeTag, gHeadingTag, gLinkTag, gHiddenTag, gTitleTag, gMetaTag]:
    discard gtk_text_tag_table_add(table, tag)
  gProseTag.setStringProp("family", "Sans")        # generic Pango alias -> system proportional font
  gCodeTag.setStringProp("family", "Monospace")     # generic Pango alias -> system monospace font
  # Shade the whole block (delimiter lines included, since they're tagged as
  # code too) so it reads as a distinct panel rather than blending into the
  # prose. paragraph-background fills the full line width, not just the glyph
  # runs. Tuned for a light theme for now; the GtkSourceView work will make
  # this follow the Adwaita light/dark scheme.
  gCodeTag.setStringProp("paragraph-background", "#f0f2f4")
  gHeadingTag.setStringProp("family", "Sans")
  gHeadingTag.setIntProp("weight", 700)             # PANGO_WEIGHT_BOLD
  gHeadingTag.setIntProp("size", 14 * 1024)         # Pango units (1/1024 pt) -- "size" confirmed working
                                                     # via isolated test; "scale" (double prop) was not
  gLinkTag.setStringProp("foreground", "#2563eb")
  gLinkTag.setIntProp("underline", 1)               # PANGO_UNDERLINE_SINGLE
  gHiddenTag.setBoolProp("invisible", true)
  # #+TITLE: large & bold; #+AUTHOR:/#+DATE: medium & muted -- document header.
  gTitleTag.setStringProp("family", "Sans")
  gTitleTag.setIntProp("weight", 700)
  gTitleTag.setIntProp("size", 22 * 1024)
  gMetaTag.setStringProp("family", "Sans")
  gMetaTag.setIntProp("size", 15 * 1024)
  gMetaTag.setStringProp("foreground", "#666666")

proc isBeginSrc(line: string): bool = strutils.strip(line).toLowerAscii().startsWith("#+begin_src")
proc isEndSrc(line: string): bool = strutils.strip(line).toLowerAscii() == "#+end_src"
proc isTitleLine(line: string): bool = strutils.strip(line).toLowerAscii().startsWith("#+title:")
proc isMetaLine(line: string): bool =
  let s = strutils.strip(line).toLowerAscii()
  s.startsWith("#+author:") or s.startsWith("#+date:") or s.startsWith("#+subtitle:")

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
  for tag in [gProseTag, gCodeTag, gHeadingTag, gLinkTag, gHiddenTag, gTitleTag, gMetaTag]:
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
    elif isTitleLine(lineText):
      gtk_text_buffer_apply_tag(buf, gTitleTag, lineStart.addr, lineEnd.addr)
    elif isMetaLine(lineText):
      gtk_text_buffer_apply_tag(buf, gMetaTag, lineStart.addr, lineEnd.addr)
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

# -- Unsaved-changes guard on window close ---------------------------------
# Decoupled from AppState (it runs before those types are defined): the buffer
# and window are reached through the single editor view, and the current file
# path is mirrored into a global at each load. GtkTextBuffer tracks its own
# modified flag; we clear it after every load/save.
var gMainWindow = GtkWidget(nil)
var gFilePath = ""
var gCloseHandlerInstalled = false

proc currentBuffer(): GtkTextBuffer = gtk_text_view_get_buffer(gEditorView)

proc onDialogResponse(dialog: pointer; responseId: cstring; data: pointer) {.cdecl.} =
  case $responseId
  of "discard":
    gtk_text_buffer_set_modified(currentBuffer(), cbool(0))  # let the re-close through
    gtk_window_close(gMainWindow)
  of "save":
    if gFilePath.len > 0:
      writeFile(gFilePath, currentBuffer().bufferText)
      gtk_text_buffer_set_modified(currentBuffer(), cbool(0))
      gtk_window_close(gMainWindow)
    # else: scratch buffer with no path -- can't save; leave the window open
  else: discard  # cancel -- stay open

proc showUnsavedDialog() =
  let dialog = adw_alert_dialog_new("Discard unsaved changes?".cstring,
    "This buffer has unsaved changes.".cstring)
  adw_alert_dialog_add_response(dialog, "cancel".cstring, "Cancel".cstring)
  adw_alert_dialog_add_response(dialog, "discard".cstring, "Discard".cstring)
  adw_alert_dialog_add_response(dialog, "save".cstring, "Save".cstring)
  adw_alert_dialog_set_response_appearance(dialog, "discard".cstring, cint(2))  # ADW_RESPONSE_DESTRUCTIVE
  adw_alert_dialog_set_response_appearance(dialog, "save".cstring, cint(1))     # ADW_RESPONSE_SUGGESTED
  adw_alert_dialog_set_default_response(dialog, "save".cstring)
  adw_alert_dialog_set_close_response(dialog, "cancel".cstring)                 # Esc / click-away = cancel
  discard g_signal_connect(dialog, "response", onDialogResponse, nil)
  adw_dialog_present(dialog, gMainWindow)

proc onCloseRequest(window: GtkWidget; data: pointer): cbool {.cdecl.} =
  ## Return TRUE to block the close and ask, if the buffer has unsaved edits.
  if pointer(gEditorView) == nil: return cbool(0)
  if gtk_text_buffer_get_modified(currentBuffer()) == cbool(0): return cbool(0)
  showUnsavedDialog()
  cbool(1)

proc onEditorRealize(widget: GtkWidget; data: pointer) {.cdecl.} =
  ## Once the editor is in the widget tree, hook the toplevel's close-request.
  if gCloseHandlerInstalled: return
  gMainWindow = gtk_widget_get_root(widget)
  discard g_signal_connect(gMainWindow, "close-request", onCloseRequest, nil)
  gCloseHandlerInstalled = true

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
  wordsProvider {.private, onlyState.}: pointer  ## GtkSourceCompletionWords, registered per buffer
  completionSetup {.private, onlyState.}: bool   ## wired once, after the buffer exists

  proc onKeyPress(keyval: int, ctrl, shift: bool, cursorPos: int): bool

  hooks:
    beforeBuild:
      # GtkSourceView (is-a GtkTextView), so all the gtk_text_view_* hooks
      # below still apply; the buffer set via the gtkBuffer hook is a
      # GtkSourceBuffer, which is what actually drives highlighting.
      state.internalWidget = gtk_source_view_new()
    build:
      loadAppCss()  # once, now that GTK is initialised
      gEditorView = state.internalWidget  # single editor -- remember it for search scrolling
      # Standard code-editor affordances (all GtkSourceView built-ins).
      gtk_source_view_set_show_line_numbers(state.internalWidget, cbool(1))
      gtk_source_view_set_highlight_current_line(state.internalWidget, cbool(1))
      gtk_source_view_set_auto_indent(state.internalWidget, cbool(1))
      gtk_source_view_set_show_right_margin(state.internalWidget, cbool(1))
      gtk_source_view_set_right_margin_position(state.internalWidget, cuint(80))
      state.handler = KeyHandler()
      let controller = gtk_event_controller_key_new()
      gtk_event_controller_set_propagation_phase(controller, GtkPhaseCapture)
      discard g_signal_connect(controller, "key-pressed", keyPressedCallback, state.handler[].addr)
      gtk_widget_add_controller(state.internalWidget, controller)
      # Install the unsaved-changes guard once the view joins the window.
      discard g_signal_connect(state.internalWidget, "realize", onEditorRealize, nil)
    connectEvents:
      state.handler.onKeyPress =
        if state.onKeyPress.isNil: nil else: state.onKeyPress.callback

  hooks gtkBuffer:
    property:
      gtk_text_view_set_buffer(state.internalWidget, state.gtkBuffer)
      # Buffer-word completion: wire it once, now that the buffer exists.
      # GtkSourceView supplies the popup UI; the words provider offers
      # identifiers already present in the buffer (Ctrl+Space, and as-you-type).
      if not state.completionSetup:
        state.completionSetup = true
        let completion = gtk_source_view_get_completion(state.internalWidget)
        state.wordsProvider = gtk_source_completion_words_new("Words".cstring)
        gtk_source_completion_add_provider(completion, state.wordsProvider)
        gtk_source_completion_words_register(state.wordsProvider, state.gtkBuffer)

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
  searchActive: bool     ## find/replace bar shown
  searchQuery: string
  replaceText: string
  terminalActive: bool   ## bottom R terminal pane shown
  paletteActive: bool    ## command palette overlay shown
  paletteQuery: string
  paletteSelected: int

proc toggleOrgMode(app: AppState, state: bool) =
  app.orgMode = state
  gOrgMode = state
  retagOrgBlocks(app.gtkBuffer)  # apply/clear immediately, don't wait for the next edit
  app.status = if state: "Org babel mode on" else: "Org babel mode off"

# -- GtkSourceView highlighting setup --------------------------------------
# The vendored .lang specs are embedded at compile time and written to a
# cache dir at runtime, so highlighting works regardless of where the binary
# ends up (`nimble install` doesn't copy data/). Style schemes need no files
# -- they're built into libgtksourceview-5.

const defLangSpec = staticRead("../data/gtksourceview/language-specs/def.lang")
const rLangSpec = staticRead("../data/gtksourceview/language-specs/R.lang")
const nimLangSpec = staticRead("../data/gtksourceview/language-specs/nim.lang")

proc langSpecDir(d: Dispatch): string =
  ## Materialise the embedded .lang specs (plus any config-provided ones) into
  ## a cache dir and return it.
  result = getCacheDir() / "nimacs" / "language-specs"
  createDir(result)
  writeFile(result / "def.lang", defLangSpec)
  writeFile(result / "R.lang", rLangSpec)
  writeFile(result / "nim.lang", nimLangSpec)
  for (id, xml) in d.configLangSpecs:   # languages registered from config.nim
    writeFile(result / (id & ".lang"), xml)

proc langIdForFile(d: Dispatch; path: string): string =
  ## GtkSourceView language id for a file, or "" for org/plain (which keep the
  ## custom org tagging / no highlighting). Config-registered extensions extend
  ## the built-in R/Nim mapping.
  let ext = path.splitFile.ext.toLowerAscii
  case ext
  of ".r": "r"
  of ".nim", ".nims", ".nimble": "nim"
  else: d.langIdForExt(ext)

proc setupSourceHighlighting(buf: GtkTextBuffer; filePath: string; d: Dispatch) =
  ## Point the buffer at a GtkSourceView language + style scheme based on the
  ## file's extension. Called on startup and whenever the open file changes,
  ## so switching between a code file and an org/plain file updates cleanly.
  let langId = langIdForFile(d, filePath)
  if langId == "":
    gtk_source_buffer_set_language(buf, nil)
    gtk_source_buffer_set_highlight_syntax(buf, cbool(0))
    gtk_source_buffer_set_style_scheme(buf, nil)  # drop any scheme background
    return
  let lm = gtk_source_language_manager_new()
  var dirs = allocCStringArray([langSpecDir(d)])
  gtk_source_language_manager_set_search_path(lm, dirs)
  deallocCStringArray(dirs)
  let lang = gtk_source_language_manager_get_language(lm, langId.cstring)
  if lang == nil:
    return
  gtk_source_buffer_set_language(buf, lang)
  gtk_source_buffer_set_highlight_syntax(buf, cbool(1))
  # Adwaita (light) for now, to match the light-tuned org code-block shade;
  # theme-aware light/dark selection is a follow-up.
  let sm = gtk_source_style_scheme_manager_get_default()
  let scheme = gtk_source_style_scheme_manager_get_scheme(sm, "Adwaita".cstring)
  if scheme != nil:
    gtk_source_buffer_set_style_scheme(buf, scheme)

proc saveFile(app: AppState) =
  if app.filePath == "":
    app.status = "No file -- pass a path on the command line to enable saving"
    return
  writeFile(app.filePath, app.gtkBuffer.bufferText)
  gtk_text_buffer_set_modified(app.gtkBuffer, cbool(0))  # clean again -> no close prompt
  app.status = "Saved " & app.filePath

proc rebuildReplSpecs(d: Dispatch)  # forward decl; defined with the REPL engine below

proc doReload(app: AppState) =
  let (ok, msg) = app.dispatch.reloadConfig(app.configPath, app.configSearchPaths)
  if ok: rebuildReplSpecs(app.dispatch)  # pick up any bindRepl session specs
  app.status = msg

proc editConfig(app: AppState) =
  # Single-buffer editor -- "edit config" means load config.nim's text into
  # the one buffer we have and repoint filePath at it, so Ctrl+S saves back
  # to config.nim directly. Whatever was in the buffer before is not saved
  # first (matches this project's current no-multiple-buffers scope).
  app.gtkBuffer.bufferText = readFile(app.configPath)
  app.filePath = app.configPath
  gFilePath = app.configPath
  gtk_text_buffer_set_modified(app.gtkBuffer, cbool(0))  # freshly loaded -> clean
  setupSourceHighlighting(app.gtkBuffer, app.configPath, app.dispatch)  # config.nim -> Nim highlighting
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
      gFilePath = path
      gtk_text_buffer_set_modified(app.gtkBuffer, cbool(0))  # freshly loaded -> clean
      setupSourceHighlighting(app.gtkBuffer, path, app.dispatch)  # re-detect language for the new file
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

# -- Persistent REPL sessions on a PTY (shared with the terminal pane) -------
# Each `:session name` is an interactive interpreter spawned on a pseudo-terminal
# we own. Owning the master fd lets C-c C-c drive it (send code, capture output
# between markers into #+RESULTS) while the terminal pane displays the *same*
# process. A ReplSpec makes this generic across languages (R/Python/bash built
# in; all validated in a standalone PTY harness):
#   prime  -- one line defining a run-helper that prints the markers. The marker
#             literals are split (e.g. paste0("__NIMACS","_BOR__")) so they never
#             appear contiguously in the helper's *echo*, which would desync us.
#   ready  -- prints a distinct token so we can read past the banner + prime echo.
#   run    -- a marker-free call to the helper ({file} -> the block's temp file).
#   quit   -- graceful shutdown command.

const rMarkerBegin = "__NIMACS_BOR__"
const rMarkerEnd = "__NIMACS_END__"

const rDriver =
  ".nimacs_run <- function(path) { cat(paste0(\"__NIMACS\",\"_BOR__\"),\"\\n\"); " &
  "con <- textConnection(\"._nimacs_buf\",\"w\"); sink(con); sink(con,type=\"message\"); options(warn=1); " &
  "tryCatch(source(path,echo=FALSE,print.eval=TRUE,spaced=FALSE,max.deparse.length=Inf), " &
  "error=function(e) cat(\"Error:\",conditionMessage(e),\"\\n\")); sink(type=\"message\"); sink(); close(con); " &
  "cat(._nimacs_buf,sep=\"\\n\"); cat(paste0(\"\\n__NIMACS\",\"_END__\"),\"\\n\"); flush(stdout()) }\n"
const pyDriver =
  "exec(\"def _nrun(p):\\n import traceback\\n print('__NIMACS''_BOR__')\\n try:\\n" &
  "  exec(open(p).read(), globals())\\n except BaseException:\\n  traceback.print_exc()\\n" &
  " print('__NIMACS''_END__')\")\n"
const bashDriver =
  "_nrun() { printf '%s\\n' \"__NIMACS\"\"_BOR__\"; source \"$1\"; printf '%s\\n' \"__NIMACS\"\"_END__\"; }\n"

type
  ReplSpec = object
    exe: string          ## resolved interpreter path (findExe of argv[0])
    argv: cstringArray   ## full command for execv
    prime, ready, run, quit: string
  RSession = ref object
    master: cint     ## PTY master fd we read/write
    pid: Pid         ## the interpreter child
    watchId: cuint   ## GLib source id of the terminal display watch (0 = none)
    log: string      ## rolling transcript, replayed when the terminal reopens
    spec: ReplSpec   ## how to run/quit this session

const sessionLogCap = 200_000  ## keep the last ~200 KB of transcript

var gReplSpecs: Table[string, ReplSpec]  ## langId -> how to run an interactive session
var gRSessions: Table[string, RSession]  ## sessionKey -> live session
var gLatestSession = ""                  ## key of the most recently used session

proc mkSpec(argv: seq[string]; prime, ready, run, quit: string): ReplSpec =
  ReplSpec(exe: findExe(argv[0]), argv: allocCStringArray(argv),
           prime: prime, ready: ready, run: run, quit: quit)

proc registerBuiltinRepls() =
  gReplSpecs["r"] = mkSpec(@["R", "--no-save", "--no-restore", "--quiet"],
    rDriver, "cat(paste0(\"NIMACSx\",\"READY\"),\"\\n\")\n", ".nimacs_run(\"{file}\")\n", "q('no')\n")
  gReplSpecs["python"] = mkSpec(@["env", "PYTHON_BASIC_REPL=1", "python3", "-q"],
    pyDriver, "print('NIMACSx''READY')\n", "_nrun(\"{file}\")\n", "exit()\n")
  gReplSpecs["bash"] = mkSpec(@["bash"],
    bashDriver, "printf '%s\\n' \"NIMACSx\"\"READY\"\n", "_nrun \"{file}\"\n", "exit\n")

proc rebuildReplSpecs(d: Dispatch) =
  ## Reset to the built-ins plus whatever config.nim registered via bindRepl.
  ## Run after every config (re)load. Running sessions keep their own spec copy.
  gReplSpecs.clear()
  registerBuiltinRepls()
  for (lang, f) in d.configRepls:
    let argv = strutils.splitWhitespace(f.command)
    if argv.len > 0:
      gReplSpecs[lang.toLowerAscii] = mkSpec(argv, f.prime, f.ready, f.run, f.quit)

proc sessionKey(lang, name: string): string = lang & "\x1f" & name

proc appendSessionLog(key, data: string) =
  if key.len == 0 or not gRSessions.hasKey(key): return
  let s = gRSessions[key]
  s.log.add(data)
  if s.log.len > sessionLogCap:
    s.log = s.log[s.log.len - sessionLogCap .. ^1]

proc ptyWrite(fd: cint; s: string) =
  var off = 0
  while off < s.len:
    let n = write(fd, unsafeAddr s[off], s.len - off)
    if n <= 0: break
    off += n

proc ptyReadUntil(fd: cint; token: string): string =
  ## Blocking read until `token` appears; returns everything read.
  var b: array[4096, char]
  while token notin result:
    let n = read(fd, addr b[0], b.len)
    if n <= 0: break
    for i in 0 ..< n: result.add(b[i])

proc sessionAlive(s: RSession): bool = kill(s.pid, cint(0)) == 0

proc spawnSession(spec: ReplSpec): RSession =
  ## fork/exec the interpreter on a fresh PTY, then prime the driver.
  if spec.exe.len == 0: raise newException(OSError, "interpreter not found on PATH")
  let master = posix_openpt(O_RDWR or O_NOCTTY)
  if master < 0: raise newException(OSError, "posix_openpt failed")
  discard grantpt(master); discard unlockpt(master)
  let sname = $ptsname(master)
  let pid = fork()
  if pid == 0:  # child: attach stdio to the slave, exec the interpreter
    discard setsid()
    let slave = posix.open(sname.cstring, O_RDWR)
    discard dup2(slave, 0); discard dup2(slave, 1); discard dup2(slave, 2)
    if slave > 2: discard close(slave)
    discard close(master)
    discard execv(spec.exe.cstring, spec.argv)
    quit(127)  # exec failed
  result = RSession(master: master, pid: pid, watchId: 0, spec: spec)
  ptyWrite(master, spec.prime)
  ptyWrite(master, spec.ready)  # sync past the banner + prime echo
  discard ptyReadUntil(master, "NIMACSxREADY")

proc getSession(lang, name: string): RSession =
  let key = sessionKey(lang, name)
  if gRSessions.hasKey(key) and sessionAlive(gRSessions[key]):
    return gRSessions[key]
  if not gReplSpecs.hasKey(lang):
    raise newException(OSError, "no REPL spec for '" & lang & "'")
  result = spawnSession(gReplSpecs[lang])
  gRSessions[key] = result
  gLatestSession = key

proc terminalReadCallback(fd: cint; condition: cint; data: pointer): cbool {.cdecl.} =
  ## GLib watch: pump the session PTY into the terminal display.
  var b: array[4096, char]
  let n = read(fd, addr b[0], b.len)
  if n <= 0: return cbool(0)  # EOF -> drop the watch
  if pointer(gTerminalVte) != nil:
    vte_terminal_feed(gTerminalVte, addr b[0], n)
  var chunk = newString(n)
  copyMem(addr chunk[0], addr b[0], n)
  appendSessionLog(gTerminalSession, chunk)  # remember it for replay on reopen
  cbool(1)

proc terminalCommitCallback(term: GtkWidget; text: cstring; size: cuint; data: pointer) {.cdecl.} =
  ## User typed in the terminal -> forward the bytes to the displayed R.
  if gTerminalMaster >= 0 and size > 0'u32:
    discard write(gTerminalMaster, cast[pointer](text), size.int)

proc runInSession(lang, name, code: string): tuple[ok: bool, output: string] =
  let key = sessionKey(lang, name)
  var s: RSession
  try:
    s = getSession(lang, name)
  except OSError:
    return (false, "could not start " & lang & " -- is it on PATH?")
  # If the terminal is showing this session, pause its watch so our blocking
  # read gets the bytes; resume after.
  let hadWatch = s.watchId != 0
  if hadWatch:
    discard g_source_remove(s.watchId); s.watchId = 0
  let path = genTempPath("nimacs-babel-", ".src")
  writeFile(path, code)
  ptyWrite(s.master, s.spec.run.replace("{file}", path))
  let acc = ptyReadUntil(s.master, rMarkerEnd)
  removeFile(path)
  var lines: seq[string]
  var collecting = false
  for rawline in acc.split('\n'):
    let line = rawline.strip(leading = false, trailing = true, chars = {'\r'})
    if rMarkerEnd in line: break
    if collecting: lines.add(line)
    if rMarkerBegin in line: collecting = true
  while lines.len > 0 and strutils.strip(lines[^1]) == "": lines.setLen(lines.len - 1)
  let output = lines.join("\n")
  # Echo the run in the terminal too, and log it (so it survives a reopen even
  # if the terminal was closed when the block ran).
  if output.len > 0:
    var shown = output.replace("\n", "\r\n") & "\r\n"
    appendSessionLog(key, shown)
    if pointer(gTerminalVte) != nil and gTerminalMaster == s.master:
      vte_terminal_feed(gTerminalVte, addr shown[0], shown.len)
  if hadWatch:
    s.watchId = g_unix_fd_add(s.master, cint(1), terminalReadCallback, nil)  # G_IO_IN
  (true, output)

proc shutdownRSessions() =
  ## Quit each session's interpreter and reap it, so nothing is left running.
  for key, s in gRSessions:
    if s.watchId != 0: discard g_source_remove(s.watchId)
    ptyWrite(s.master, s.spec.quit)
    discard close(s.master)
    discard kill(s.pid, SIGTERM)
    var status: cint
    discard waitpid(s.pid, status, 0)
  gRSessions.clear()

var gTerminalTargetKey = ""  ## which gRSessions entry the terminal shows ("" = auto: latest)

proc detachTerminalWatch() =
  ## Remove the display watch from the currently-bound target (its process keeps
  ## running). Leaves gTerminalVte alone, so a rebind can reuse the widget.
  if gTerminalSession != "" and gRSessions.hasKey(gTerminalSession):
    let s = gRSessions[gTerminalSession]
    if s.watchId != 0:
      discard g_source_remove(s.watchId); s.watchId = 0

proc bindTerminalCommon(vte: GtkWidget; s: RSession; key: string) =
  detachTerminalWatch()                          # drop any previous binding first
  gTerminalVte = vte
  gTerminalMaster = s.master
  gTerminalSession = key
  vte_terminal_reset(vte, cbool(1), cbool(1))    # clear stale display on rebind
  if s.log.len > 0:                              # replay this target's transcript
    vte_terminal_feed(vte, addr s.log[0], s.log.len)
  if s.watchId == 0:
    s.watchId = g_unix_fd_add(s.master, cint(1), terminalReadCallback, nil)  # G_IO_IN

proc bindTerminalToSession(vte: GtkWidget) =
  ## Show the latest babel :session, or spawn an R "default" if none.
  var s: RSession
  var key: string
  if gLatestSession != "" and gRSessions.hasKey(gLatestSession):
    key = gLatestSession
    s = gRSessions[key]
  else:
    try:
      s = getSession("r", "default")
    except OSError:
      return
    key = gLatestSession  # getSession set it
  bindTerminalCommon(vte, s, key)

proc spawnRaw(argv: seq[string]; workdir: string): RSession =
  ## fork/exec an arbitrary interactive program on a PTY (no driver) -- for a
  ## raw terminal (a shell, `claude`, ...). No markers, so babel never targets it.
  let exe = findExe(argv[0])
  if exe.len == 0: raise newException(OSError, argv[0] & " not found on PATH")
  let master = posix_openpt(O_RDWR or O_NOCTTY)
  if master < 0: raise newException(OSError, "posix_openpt failed")
  discard grantpt(master); discard unlockpt(master)
  let sname = $ptsname(master)
  let cargv = allocCStringArray(argv)
  let pid = fork()
  if pid == 0:
    discard setsid()
    let slave = posix.open(sname.cstring, O_RDWR)
    discard dup2(slave, 0); discard dup2(slave, 1); discard dup2(slave, 2)
    if slave > 2: discard close(slave)
    discard close(master)
    if workdir.len > 0: discard chdir(workdir.cstring)
    discard execv(exe.cstring, cargv)
    quit(127)
  RSession(master: master, pid: pid, watchId: 0)  # default (empty) spec

proc rawKey(argv: seq[string]): string = "raw\x1f" & argv.join(" ")

proc bindTerminalToKey(vte: GtkWidget; key: string): bool =
  if gRSessions.hasKey(key) and sessionAlive(gRSessions[key]):
    bindTerminalCommon(vte, gRSessions[key], key)
    return true
  false

proc bindTerminal(vte: GtkWidget) =
  ## Bind to the chosen target, else the latest session (or a fresh R default).
  if gTerminalTargetKey.len > 0 and bindTerminalToKey(vte, gTerminalTargetKey):
    return
  bindTerminalToSession(vte)

proc unbindTerminal() =
  ## Detach the terminal entirely (the interpreter/program keeps running).
  detachTerminalWatch()
  gTerminalVte = GtkWidget(nil)
  gTerminalMaster = -1
  gTerminalSession = ""

renderable TerminalPane of BaseWidget:
  ## A VTE widget that displays a babel session or a raw program (we own the
  ## PTY; VTE is display + keyboard only). The "commit" handler forwards typed
  ## input to whatever master fd is currently bound, so switching targets needs
  ## no reconnection.
  hooks:
    beforeBuild:
      state.internalWidget = vte_terminal_new()
    build:
      vte_terminal_set_scrollback_lines(state.internalWidget, clong(5000))
      vte_terminal_set_size(state.internalWidget, clong(80), clong(10))
      discard g_signal_connect(state.internalWidget, "commit", terminalCommitCallback, nil)
      bindTerminal(state.internalWidget)

proc runningTargets(): seq[string] =
  ## Keys of the live sessions / raw terminals, for the switcher (stable order).
  for key, s in gRSessions:
    if sessionAlive(s): result.add(key)
  result.sort()

proc keyLabel(key: string): string =
  ## Friendly switcher label: "r:default", "python:py", or "claude" for raw.
  let p = key.split('\x1f')
  if p.len == 2:
    (if p[0] == "raw": p[1].split(' ')[0] else: p[0] & ":" & p[1])
  else: key

proc switchTerminalTo(app: AppState; key: string) =
  ## Make the terminal show an existing target (opening the pane if needed).
  gTerminalTargetKey = key
  if app.terminalActive and pointer(gTerminalVte) != nil:
    discard bindTerminalToKey(gTerminalVte, key)
  else:
    app.terminalActive = true  # pane builds -> bindTerminal uses gTerminalTargetKey

proc openTerminalRaw(app: AppState; argv: seq[string]) =
  ## Spawn (or reuse) a raw interactive program and switch the terminal to it,
  ## running it in the open file's directory.
  let key = rawKey(argv)
  if not (gRSessions.hasKey(key) and sessionAlive(gRSessions[key])):
    let dir = if gFilePath.len > 0: parentDir(gFilePath) else: ""
    try:
      gRSessions[key] = spawnRaw(argv, dir)
    except OSError:
      app.status = argv[0] & " not found on PATH"
      return
  app.switchTerminalTo(key)

proc dedent(code: string): string =
  ## Strip the common leading whitespace from every line -- org src blocks are
  ## usually indented, and passing that through breaks indentation-sensitive
  ## languages (Python sees a leading indent on line 1 as an error). Harmless
  ## for R/bash. Mirrors org-babel's own de-indentation.
  var minIndent = high(int)
  for line in code.splitLines():
    if strutils.strip(line).len == 0: continue  # ignore blank lines
    var i = 0
    while i < line.len and line[i] in {' ', '\t'}: inc i
    minIndent = min(minIndent, i)
  if minIndent == high(int) or minIndent == 0: return code
  var res: seq[string]
  for line in code.splitLines():
    res.add(if line.len >= minIndent: line[minIndent .. ^1] else: line)
  res.join("\n")

proc runCommandTemplate(cmdTemplate, code: string): tuple[ok: bool, output: string] =
  ## Run a config-registered one-shot babel command: write the block body to a
  ## temp file, substitute `{file}`, run it through the shell, and capture
  ## stdout+stderr merged (execCmdEx defaults to poStdErrToStdOut).
  let path = genTempPath("nimacs-babel-", ".src")
  writeFile(path, code)
  defer: removeFile(path)
  let cmd = cmdTemplate.replace("{file}", quoteShell(path))
  try:
    let (output, _) = execCmdEx(cmd)
    result = (true, output)
  except OSError, IOError:
    result = (false, "failed to run: " & cmdTemplate)

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

  let code = dedent(lines[beginIdx + 1 ..< endIdx].join("\n"))
  # `:session` -> a persistent interactive interpreter (any language with a
  # ReplSpec: R/Python/bash built in, shared with the terminal pane). No
  # `:session` -> a one-shot run (built-in R, or a config bindLang command).
  var ok: bool
  var rawOut, where: string
  if sessionName != "":
    if gReplSpecs.hasKey(lang):
      (ok, rawOut) = runInSession(lang, sessionName, code)
      where = lang & " :session " & sessionName
    else:
      app.status = "C-c C-c: no interactive session for '" &
        (if lang == "": "none" else: lang) & "'"
      return
  elif lang == "r":
    (ok, rawOut) = runRscript(code)
    where = "R (one-shot)"
  else:
    let cmd = app.dispatch.babelCommand(lang)
    if cmd == "":
      app.status = "C-c C-c: no runner for language '" &
        (if lang == "": "none" else: lang) & "' -- add :session, or bindLang in config.nim"
      return
    (ok, rawOut) = runCommandTemplate(cmd, code)
    where = lang & " (one-shot)"
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

  app.gtkBuffer.bufferText = newLines.join("\n")
  # Keep the cursor where it was -- results are inserted *after* the block, so
  # the original offset still points at the same character -- and scroll it back
  # into view (set_text otherwise snaps the view to the top of the file).
  app.gtkBuffer.placeCursorAt(cursorPos)
  if pointer(gEditorView) != nil:
    var it: GtkTextIter
    gtk_text_buffer_get_iter_at_offset(app.gtkBuffer, it.addr, cursorPos.cint)
    discard gtk_text_view_scroll_to_iter(gEditorView, it.addr, 0.1, cbool(0), 0.0, 0.0)
  app.status = "Executed " & where & " -- " & $(resultLines.len - 1) & " result line(s)"

proc toggleComment(app: AppState; cursorPos: int) =
  ## Toggle a leading `# ` line comment on the cursor's line. `#` is the line
  ## comment for R/Python/Nim/bash, a sensible default across our languages.
  let text = app.gtkBuffer.bufferText
  var ls = cursorPos
  while ls > 0 and text[ls - 1] != '\n': dec ls
  var le = cursorPos
  while le < text.len and text[le] != '\n': inc le
  let line = text[ls ..< le]
  let body = strutils.strip(line, leading = true, trailing = false)
  let indent = line[0 ..< line.len - body.len]
  var newLine: string
  if body.startsWith("# "): newLine = indent & body[2 .. ^1]
  elif body.startsWith("#"): newLine = indent & body[1 .. ^1]
  else: newLine = indent & "# " & body
  app.gtkBuffer.bufferText = text[0 ..< ls] & newLine & text[le .. ^1]
  app.gtkBuffer.placeCursorAt(max(ls, cursorPos + (newLine.len - line.len)))
  app.status = "toggled comment"

# -- Find & replace (GtkSourceSearchContext) -------------------------------
var gSearchContext: pointer = nil
var gSearchSettings: pointer = nil

proc ensureSearchContext(buf: GtkTextBuffer) =
  if gSearchContext != nil: return
  gSearchSettings = gtk_source_search_settings_new()
  gtk_source_search_settings_set_wrap_around(gSearchSettings, cbool(1))
  gSearchContext = gtk_source_search_context_new(buf, gSearchSettings)
  gtk_source_search_context_set_highlight(gSearchContext, cbool(1))  # highlight all matches

proc setSearchText(app: AppState; text: string) =
  ensureSearchContext(app.gtkBuffer)
  app.searchQuery = text
  gtk_source_search_settings_set_search_text(gSearchSettings, text.cstring)

proc searchMove(app: AppState; forward: bool) =
  ## Select and scroll to the next/previous match from the current selection
  ## or cursor; wraps around.
  ensureSearchContext(app.gtkBuffer)
  if app.searchQuery.len == 0: return
  let buf = app.gtkBuffer
  var startIter, mStart, mEnd, selStart, selEnd: GtkTextIter
  if gtk_text_buffer_get_selection_bounds(buf, selStart.addr, selEnd.addr) != cbool(0):
    startIter = (if forward: selEnd else: selStart)
  else:
    gtk_text_buffer_get_iter_at_offset(buf, startIter.addr, buf.liveCursorOffset().cint)
  var wrapped: cbool
  let found =
    if forward: gtk_source_search_context_forward(gSearchContext, startIter.addr, mStart.addr, mEnd.addr, wrapped.addr)
    else: gtk_source_search_context_backward(gSearchContext, startIter.addr, mStart.addr, mEnd.addr, wrapped.addr)
  if found != cbool(0):
    gtk_text_buffer_select_range(buf, mStart.addr, mEnd.addr)
    if pointer(gEditorView) != nil:
      discard gtk_text_view_scroll_to_iter(gEditorView, mStart.addr, 0.1, cbool(0), 0.0, 0.0)
    app.status = "match" & (if wrapped != cbool(0): " (wrapped)" else: "")
  else:
    app.status = "no match for '" & app.searchQuery & "'"

proc searchReplace(app: AppState) =
  ## Replace the current match (if the selection is one), then advance.
  ensureSearchContext(app.gtkBuffer)
  let buf = app.gtkBuffer
  var selStart, selEnd: GtkTextIter
  if gtk_text_buffer_get_selection_bounds(buf, selStart.addr, selEnd.addr) != cbool(0):
    var err: pointer = nil
    discard gtk_source_search_context_replace(gSearchContext, selStart.addr, selEnd.addr,
      app.replaceText.cstring, -1, err.addr)
  app.searchMove(true)

proc searchReplaceAll(app: AppState) =
  ensureSearchContext(app.gtkBuffer)
  if app.searchQuery.len == 0: return
  var err: pointer = nil
  let n = gtk_source_search_context_replace_all(gSearchContext, app.replaceText.cstring, -1, err.addr)
  app.status = "replaced " & $n & " occurrence(s)"

proc closeSearch(app: AppState) =
  app.searchActive = false
  ensureSearchContext(app.gtkBuffer)
  gtk_source_search_settings_set_search_text(gSearchSettings, "".cstring)  # clear highlights
  app.status = "Find closed"

# -- Command palette (Ctrl+Shift+P) ----------------------------------------
# Reuses the editor's key controller: while open, every keystroke routes here
# (type to filter, Up/Down to move, Enter to run, Esc to close), so no separate
# focused entry or popover is needed. Items span menu actions, running
# terminals, and (later) LSP servers.

type PaletteItem = object
  label: string
  run: proc() {.closure.}

proc paletteItems(app: AppState): seq[PaletteItem] =
  result.add PaletteItem(label: "Open file", run: proc() = app.openFile())
  result.add PaletteItem(label: "Save", run: proc() = app.saveFile())
  result.add PaletteItem(label: "Reload config", run: proc() = app.doReload())
  result.add PaletteItem(label: "Edit config.nim", run: proc() = app.editConfig())
  result.add PaletteItem(label: "Toggle Org babel mode", run: proc() = app.toggleOrgMode(not app.orgMode))
  result.add PaletteItem(label: "Find and replace", run: proc() = app.searchActive = true)
  result.add PaletteItem(label: "Comment: toggle line", run: proc() = app.toggleComment(app.gtkBuffer.liveCursorOffset()))
  result.add PaletteItem(label: "Terminal: Claude Code", run: proc() = app.openTerminalRaw(@["claude"]))
  result.add PaletteItem(label: "Terminal: new shell", run: proc() = app.openTerminalRaw(@["bash"]))
  for key in runningTargets():
    let k = key
    result.add PaletteItem(label: "Terminal: switch to " & keyLabel(k),
      run: proc() = app.switchTerminalTo(k))
  # LSP servers will add palette items here in the future.

proc paletteFiltered(app: AppState): seq[PaletteItem] =
  let q = app.paletteQuery.toLowerAscii
  for it in app.paletteItems():
    if q.len == 0 or q in it.label.toLowerAscii:
      result.add it

proc handlePaletteKey(app: AppState; keyval: int): bool =
  const
    kEsc = 0xff1b
    kRet = 0xff0d
    kKpEnter = 0xff8d
    kUp = 0xff52
    kDown = 0xff54
    kBackspace = 0xff08
  let items = app.paletteFiltered()
  case keyval
  of kEsc:
    app.paletteActive = false
  of kRet, kKpEnter:
    let sel = app.paletteSelected
    app.paletteActive = false
    if sel >= 0 and sel < items.len: items[sel].run()
  of kUp:
    app.paletteSelected = max(0, app.paletteSelected - 1)
  of kDown:
    app.paletteSelected = min(max(0, items.len - 1), app.paletteSelected + 1)
  of kBackspace:
    if app.paletteQuery.len > 0:
      app.paletteQuery.setLen(app.paletteQuery.len - 1)
      app.paletteSelected = 0
  else:
    let cp = gdk_keyval_to_unicode(keyval.cuint)
    if int(cp) >= 32 and int(cp) != 127:  # printable -> extend the query
      app.paletteQuery.add($Rune(cp))
      app.paletteSelected = 0
  discard app.redraw()
  true

proc handleKey(app: AppState, keyval: int, ctrl, shift: bool, cursorPos: int): bool =
  # The command palette, when open, swallows every key (filter/navigate/run).
  if app.paletteActive:
    return app.handlePaletteKey(keyval)

  # Built-in bindings are host-level and always active, regardless of
  # whatever config.nim currently has bound -- rebinding them away would be
  # a footgun (e.g. losing the only way to trigger a reload).
  # Escape closes the find bar (it's non-printable, so keychord ignores it).
  const gdkKeyEscape = 0xff1b
  if app.searchActive and keyval == gdkKeyEscape:
    app.closeSearch()
    discard app.redraw()
    return true

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
  elif chord == "C-/":
    app.toggleComment(cursorPos)
  elif chord == "C-=":
    gFontPt = min(gFontPt + 1, 40); applyZoom(); app.status = "Zoom " & $gFontPt & "pt"
  elif chord == "C--":
    gFontPt = max(gFontPt - 1, 6); applyZoom(); app.status = "Zoom " & $gFontPt & "pt"
  elif chord == "C-0":
    gFontPt = 11; applyZoom(); app.status = "Zoom reset (" & $gFontPt & "pt)"
  elif chord == "C-f":
    app.searchActive = not app.searchActive
    if not app.searchActive: app.closeSearch() else: app.status = "Find"
  elif chord == "C-S-p":
    app.paletteActive = true; app.paletteQuery = ""; app.paletteSelected = 0
    app.status = "Command palette -- type to filter, Enter to run, Esc to close"
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

        MenuButton {.addRight.}:
          tooltip = "Menu -- commands & terminals (also Ctrl+Shift+P)"
          Icon(name = "open-menu-symbolic")
          Popover:
            Box(orient = OrientY):
              margin = 4
              # Same command registry as the palette, so the menu and the
              # palette always list the same actions -- including live terminals.
              for it in app.paletteItems():
                let action = it
                ModelButton:
                  text = action.label
                  proc clicked() = action.run()

        Button {.addRight.}:
          style = [ButtonFlat]
          tooltip = "Find & replace (Ctrl+F)"
          Icon(name = "edit-find-symbolic")
          proc clicked() =
            app.searchActive = not app.searchActive
            if not app.searchActive: app.closeSearch() else: app.status = "Find"

        ToggleButton {.addRight.}:
          tooltip = "Terminal (bottom pane) -- shared with :session babel"
          state = app.terminalActive
          Icon(name = "utilities-terminal-symbolic")
          proc changed(state: bool) =
            app.terminalActive = state
            if not state: unbindTerminal()  # keep processes running, detach the view
            app.status = if state: "Terminal" else: "Terminal closed"

        Button {.addRight.}:
          style = [ButtonFlat]
          tooltip = "Claude Code in the terminal (in the open file's directory)"
          Icon(name = "starred-symbolic")
          proc clicked() =
            app.openTerminalRaw(@["claude"])
            app.status = "Claude in terminal"

      Box(orient = OrientY):
        if app.paletteActive:
          Box(orient = OrientY) {.expand: false.}:
            margin = 8
            Label(text = "⌘  " & app.paletteQuery & "▏") {.expand: false.}:
              xalign = 0.0
            for i, it in app.paletteFiltered():
              if i < 9:  # cap the visible matches
                Label(text = (if i == app.paletteSelected: "▶  " else: "      ") & it.label) {.expand: false.}:
                  xalign = 0.0

        if app.searchActive:
          Box(orient = OrientX) {.expand: false.}:
            margin = 4
            Entry {.expand: true.}:
              placeholder = "Find"
              text = app.searchQuery
              proc changed(text: string) = app.setSearchText(text)
              proc activate() = app.searchMove(true)
            Entry {.expand: true.}:
              placeholder = "Replace"
              text = app.replaceText
              proc changed(text: string) = app.replaceText = text
              proc activate() = app.searchReplace()
            Button:
              style = [ButtonFlat]
              tooltip = "Previous match"
              Icon(name = "go-up-symbolic")
              proc clicked() = app.searchMove(false)
            Button:
              style = [ButtonFlat]
              tooltip = "Next match"
              Icon(name = "go-down-symbolic")
              proc clicked() = app.searchMove(true)
            Button:
              style = [ButtonFlat]
              tooltip = "Replace"
              Icon(name = "edit-find-replace-symbolic")
              proc clicked() = app.searchReplace()
            Button:
              style = [ButtonFlat]
              tooltip = "Replace all"
              Icon(name = "edit-select-all-symbolic")
              proc clicked() = app.searchReplaceAll()
            Button:
              style = [ButtonFlat]
              tooltip = "Close (Esc)"
              Icon(name = "window-close-symbolic")
              proc clicked() = app.closeSearch()

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

        if app.terminalActive:
          Separator() {.expand: false.}
          Box(orient = OrientX) {.expand: false.}:
            margin = 2
            for key in runningTargets():           # one button per running terminal
              let k = key                           # capture per iteration for the closure
              Button:
                style = if k == gTerminalSession: [ButtonSuggested] else: [ButtonFlat]
                Label(text = keyLabel(k))
                proc clicked() = app.switchTerminalTo(k)
            Button:
              style = [ButtonFlat]
              tooltip = "New shell in the terminal"
              Label(text = "+ shell")
              proc clicked() = app.openTerminalRaw(@["bash"])
          TerminalPane {.expand: false.}

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

  # Load config first: it may register babel languages and highlight specs
  # that setupSourceHighlighting needs below.
  let projectRoot = getAppDir()
  let configPath = projectRoot / "config.nim"
  let searchPaths = @[projectRoot / "src"]
  let dispatch = newDispatch(cacheKey())
  let (ok, msg) = dispatch.reloadConfig(configPath, searchPaths)
  rebuildReplSpecs(dispatch)  # built-in R/Python/bash + any config-registered sessions
  let initialStatus = if ok: msg else: "config load failed: " & msg

  setupSourceHighlighting(gtkBuffer, filePath, dispatch)  # highlighting (incl. config langs)
  gFilePath = filePath
  gtk_text_buffer_set_modified(gtkBuffer, cbool(0))  # initial content isn't a user edit
  gOrgMode = startInOrgMode
  retagOrgBlocks(gtkBuffer)  # apply org tags to the initial text before first draw
  discard g_signal_connect_data(pointer(gtkBuffer), "changed".cstring,
    cast[pointer](bufferChangedCallback), nil, nil, G_CONNECT_AFTER)

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
