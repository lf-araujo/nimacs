## Your "init.el". Compiled to a fresh .so and hot-swapped in whenever you
## hit Ctrl+Shift+R (or the "Reload Config" button) -- the running app never
## restarts and the buffer's text is untouched. Edit a command below, save,
## reload, and try its keybinding again.
##
## Deliberately imports nothing but nimacs/config_api (which pulls in
## nimacs/kernel) -- never owlkettle -- so this recompiles fast and never
## crosses owlkettle's own types across the .so boundary. See DESIGN.md.

import std/strutils
import nimacs/config_api

proc insertTimestamp(k: ptr EditorKernel) {.cdecl.} =
  let stamp = "[HOT-RELOADED] "
  k.text.insert(stamp, k.cursorPos)
  k.cursorPos += stamp.len
  k.status = "inserted tag"

proc uppercaseLine(k: ptr EditorKernel) {.cdecl.} =
  var lineStart = k.cursorPos
  while lineStart > 0 and k.text[lineStart - 1] != '\n':
    dec lineStart
  var lineEnd = k.cursorPos
  while lineEnd < k.text.len and k.text[lineEnd] != '\n':
    inc lineEnd
  let upper = k.text[lineStart ..< lineEnd].toUpperAscii()
  k.text = k.text[0 ..< lineStart] & upper & k.text[lineEnd .. ^1]
  k.status = "uppercased current line"

proc sayHello(k: ptr EditorKernel) {.cdecl.} =
  k.status = "Hello"

proc nimacs_configure(ctx: pointer; register: RegisterProc; bindP: BindProc;
                      bindLang: BindLangProc; bindRepl: BindReplProc) {.exportc, dynlib.} =
  register(ctx, "insert-timestamp", insertTimestamp)
  register(ctx, "uppercase-line", uppercaseLine)
  register(ctx, "say-hello", sayHello)
  bindP(ctx, "C-t", "insert-timestamp")
  bindP(ctx, "C-u", "uppercase-line")
  bindP(ctx, "C-h", "say-hello")

  # Org-babel languages. R is built in (with :session support); register more
  # here and C-c C-c runs their src blocks -- no host rebuild needed. `{file}`
  # is replaced with a temp file holding the block body; stdout+stderr go to
  # #+RESULTS. The 4th/5th args add syntax highlighting: file extensions to
  # treat as this language, and a GtkSourceView .lang (here "" -- highlighting
  # needs a real .lang; pass one, e.g. `staticRead("python.lang")`, to enable).
  bindLang(ctx, "python", "python3 {file}", ".py,.pyw", "")
  bindLang(ctx, "bash", "bash {file}", ".sh,.bash", "")

  # Interactive `:session` interpreters (shared with the terminal pane). R,
  # Python, and bash are built in; add more with bindRepl. The interpreter runs
  # on a PTY; `prime` defines a helper that prints the markers `__NIMACS_BOR__`
  # /`__NIMACS_END__` (split the literals so they don't appear in the helper's
  # echo), `run` calls it ({file} -> temp file), `ready` prints NIMACSxREADY.
  # Example for Julia (uncomment if `julia` is installed):
  #
  # bindRepl(ctx, "julia", "julia -q --color=no",
  #   "function _nrun(p); println(\"__NIMACS\" * \"_BOR__\"); try; include(p); " &
  #     "catch e; showerror(stdout, e); println(); end; " &
  #     "println(\"__NIMACS\" * \"_END__\"); flush(stdout); end\n",
  #   "println(\"NIMACSx\" * \"READY\")\n",
  #   "_nrun(\"{file}\")\n",
  #   "exit()\n")

