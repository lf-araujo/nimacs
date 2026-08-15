## focim user configuration -- plain Nim with full access to the editor model.
## This is the "deep ABI": no GObject/.so boundary like the GTK build needed.
## A command is a Nim proc; a keybinding or a language is data; a hook is a proc
## that fires at an editor event. Edit this file and rebuild (`nimble focim`) to
## apply -- the host calls `configure(app)` once, after the built-ins load.

import focimcore
import std/times

proc configure*(app: var App) =
  # 1. A brand-new command, written in Nim, bound to a two-key sequence.
  defcommand("insert-date", "Insert today's date", proc(a: var App) =
    a.ed.insertText(now().format("yyyy-MM-dd"))
    a.msg = "inserted date")
  bindkey("C-c d", "insert-date")

  # 2. Rebind an existing built-in (keys are just data).
  bindkey("C-w", "quit")

  # 3. Teach focim a new language: Python org-babel :session blocks.
  registerRepl("python", pySpec)

  # 4. Hooks fire at editor events -- here, a friendly startup message and a
  #    note after every babel run.
  addHook("startup", proc(a: var App) =
    a.msg = "focim ready -- config loaded")
  addHook("after-babel", proc(a: var App) =
    a.sess.appendOutput("-- (after-babel hook) --\n"))
