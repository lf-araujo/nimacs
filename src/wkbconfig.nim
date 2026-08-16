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
  bindkey("C-x b", "list-buffers")      # switch buffers (palette)
  bindkey("C-x k", "kill-buffer")       # close the current buffer

  # ---- Your customisations --------------------------------------------------
  # A brand-new command, written in Nim, bound to a two-key sequence.
  defcommand("insert-date", "Insert today's date", proc(a: var App) =
    a.ed.insertText(now().format("yyyy-MM-dd"))
    a.msg = "inserted date")
  bindkey("C-c d", "insert-date")

  # Teach wkbenchless a new language: Python org-babel :session blocks.
  registerRepl("python", pySpec)

  # 4. Hooks fire at editor events -- here, a friendly startup message and a
  #    note after every babel run.
  addHook("startup", proc(a: var App) =
    a.msg = "wkbenchless ready -- config loaded")
  addHook("after-babel", proc(a: var App) =
    a.sess.appendOutput("-- (after-babel hook) --\n"))
