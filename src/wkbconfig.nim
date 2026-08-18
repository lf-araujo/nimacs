## wkbenchless user configuration -- plain Nim with full access to the editor model.
## This is the "deep ABI": no GObject/.so boundary like the GTK build needed.
## A command is a Nim proc; a keybinding or a language is data; a hook is a proc
## that fires at an editor event. Edit this file and press C-c r inside wkbenchless
## (command "recompile") -- it rebuilds the binary, which recompiles THIS file,
## and re-execs, restoring your file and cursor. (`nimble wkbenchless` also works.)
## The host calls `configure(app)` once, after the built-ins load.

import wkbcore
import std/times

proc configure*(app: var App) =
  # ---- Keymap ---------------------------------------------------------------
  # Every default binding lives here so you can see and change them all. The
  # command names come from wkbcore's registerBuiltins (run M-x to browse
  # them). Rebind, remove, or add freely, then C-c r to apply. (M-x and C-q are
  # also set in core as a recovery net.) Note: Shift+letter chords don't reach
  # the X11 driver, so the palette is M-x, not C-S-p.
  bindkey("M-x", "palette")
  bindkey("C-p", "palette")             # alternative to M-x
  bindkey("C-S-p", "palette")           # harmless alias where it works
  bindkey("C-s", "save")
  bindkey("C-q", "quit")
  bindkey("C-z", "undo")
  bindkey("C-y", "redo")
  bindkey("C-/", "comment-toggle")
  bindkey("C-f", "find")                 # incremental find in the buffer
  bindkey("C-h", "replace")             # find & replace
  bindkey("C-j", "org-nav")             # jump to org heading / block / caption
  bindkey("M-Right", "scroll-right")    # pan a wide table into view
  bindkey("M-Left", "scroll-left")
  bindkey("C-c u", "unfold-all")        # reveal every folded src block
  bindkey("C-Space", "complete")        # LSP completion
  bindkey("F1", "show-help")            # help for word at cursor
  bindkey("C-Enter", "run-line")        # send the current line to the session
  bindkey("C-c C-c", "babel-execute")   # run the org src block
  bindkey("C-c e", "src-edit-block")    # zoom into the block (org-edit-special)
  bindkey("C-c b", "src-edit-block")
  bindkey("C-c t", "src-edit-session")  # tangle all same-session blocks
  bindkey("C-c o", "refresh-objects")
  bindkey("C-c n", "focus-next")        # cycle pane focus
  bindkey("C-c s", "switch-session")    # cycle the current session
  bindkey("C-c k", "new-terminal")      # bash terminal session
  bindkey("C-c f", "edit-config")       # open this file
  bindkey("C-c r", "reload-config")     # recompile & restart
  bindkey("C-x C-f", "open-file")       # browse & open a file (palette)
  bindkey("C-x C-r", "recent-files")    # open a recently used file (palette)
  bindkey("C-x b", "list-buffers")      # switch buffers (palette)
  bindkey("C-x k", "kill-buffer")       # close the current buffer
  bindkey("C-=", "zoom-in")             # font size
  bindkey("C--", "zoom-out")
  bindkey("C-0", "zoom-reset")
  bindkey("C-c C-o", "open-link")       # open org link at cursor
  bindkey("C-c a", "claude")            # claude in the bottom panel (best-effort)
  bindkey("M-t", "terminal")            # bash terminal in the bottom panel
  bindkey("C-c C-t", "theme")           # pick a theme (palette); also M-x theme

  # ---- Themes ---------------------------------------------------------------
  # A theme is a base16 palette (base00..base0F): base00 is the background,
  # base05 the default text, base08..0F the accents. `registerTheme` derives the
  # whole editor + chrome from it. The FIRST registered theme is the default;
  # `M-x theme` (or C-c T) opens a palette to switch live. Add your own by
  # copying a block and changing the sixteen hex values.
  registerTheme("one-dark", [
    rgb(0x282c34), rgb(0x353b45), rgb(0x3e4451), rgb(0x545862),
    rgb(0x565c64), rgb(0xabb2bf), rgb(0xb6bdca), rgb(0xc8ccd4),
    rgb(0xe06c75), rgb(0xd19a66), rgb(0xe5c07b), rgb(0x98c379),
    rgb(0x56b6c2), rgb(0x61afef), rgb(0xc678dd), rgb(0xbe5046)])
  registerTheme("gruvbox-dark", [
    rgb(0x282828), rgb(0x3c3836), rgb(0x504945), rgb(0x665c54),
    rgb(0xbdae93), rgb(0xd5c4a1), rgb(0xebdbb2), rgb(0xfbf1c7),
    rgb(0xfb4934), rgb(0xfe8019), rgb(0xfabd2f), rgb(0xb8bb26),
    rgb(0x8ec07c), rgb(0x83a598), rgb(0xd3869b), rgb(0xd65d0e)])
  registerTheme("solarized-light", [
    rgb(0xfdf6e3), rgb(0xeee8d5), rgb(0x93a1a1), rgb(0x839496),
    rgb(0x657b83), rgb(0x586e75), rgb(0x073642), rgb(0x002b36),
    rgb(0xdc322f), rgb(0xcb4b16), rgb(0xb58900), rgb(0x859900),
    rgb(0x2aa198), rgb(0x268bd2), rgb(0x6c71c4), rgb(0xd33682)])
  applyThemeByName(app, "one-dark")     # the default; comment out for the first-registered

  # ---- Your customisations --------------------------------------------------
  # A brand-new command, written in Nim, bound to a two-key sequence.
  defcommand("insert-date", "Insert today's date", proc(a: var App) =
    a.ed.insertText(now().format("yyyy-MM-dd"))
    a.msg = "inserted date")
  bindkey("C-c d", "insert-date")

  # Teach wkbenchless a new language: Python org-babel :session blocks.
  registerRepl("python", pySpec)

  # Where terminals (M-t / C-c a) start. Empty = auto: the current file's git
  # project root (falling back to its directory). Set an absolute or ~ path to
  # override, e.g.  gTerminalDir = "~/projects/analysis"
  gTerminalDir = ""

  # PATH for sessions & terminals. Launched from a GUI, wkbenchless may inherit a
  # stripped PATH, so at startup it seeds PATH from your login shell ($SHELL -lc)
  # -- that alone usually locates R, python, etc. Add extra dirs here (prepended,
  # ~ expanded); set gLoadLoginPath = false to skip the login-shell probe.
  addExecPath("~/.local/bin")
  addExecPath("~/bin")
  # gLoadLoginPath = false

  # The `claude` action (C-c a) runs this. Default resumes the last conversation
  # in the project; set to "claude" for a fresh chat, or add your own flags.
  gClaudeCmd = "claude --continue"
  # gClaudeCmd = "claude"                # start fresh instead of continuing

  # CriticMarkup (tracked changes) is fontified in org buffers automatically:
  # {++ins++} green, {--del--} red, {~~old~>new~~} red->green, {>>comment<<}
  # grey, {==highlight==} yellow. Resolve with M-x criticmarkup-accept-all /
  # criticmarkup-reject-all (bound here to a C-c prefix for convenience).
  bindkey("C-c j", "criticmarkup-accept-all")
  bindkey("C-c l", "criticmarkup-reject-all")

  # 4. Hooks fire at editor events -- here, a friendly startup message and a
  #    note after every babel run.
  addHook("startup", proc(a: var App) =
    a.msg = "wkbenchless ready -- config loaded")
  addHook("after-babel", proc(a: var App) =
    a.sess.appendOutput("-- (after-babel hook) --\n"))
