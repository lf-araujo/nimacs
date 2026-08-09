## Contract between the host and a compiled `config.nim`. Deliberately
## imports nothing but `kernel` — no owlkettle, no GTK — so config.nim's
## recompiles stay fast and never risk crossing owlkettle's own types
## across the .so boundary.
##
## config.nim must define:
##   proc nimacs_configure(ctx: pointer; register: RegisterProc;
##                          bindP: BindProc) {.exportc, dynlib.}
## which calls `register`/`bindP` once per command/binding it wants to
## install. The host owns all resulting storage (copies cstring -> string
## immediately in its callbacks) — nothing is returned by value out of the
## .so, only function pointers the host keeps alive per DESIGN.md's reload
## sequence.

import ./kernel
export kernel

type
  CommandProc* = proc (k: ptr EditorKernel) {.cdecl, gcsafe.}
  RegisterProc* = proc (ctx: pointer; name: cstring; fn: CommandProc) {.cdecl, gcsafe.}
  BindProc* = proc (ctx: pointer; keychord: cstring; commandName: cstring) {.cdecl, gcsafe.}
  BindLangProc* = proc (ctx: pointer; langId: cstring; command: cstring;
                        extensions: cstring; langSpec: cstring) {.cdecl, gcsafe.}
    ## Register an org-babel language from config, so new languages don't
    ## require editing the host.
    ##   langId     -- the src-block language name, e.g. "python"
    ##   command    -- one-shot run template; the host substitutes `{file}`
    ##                 with a temp file holding the block body, runs it, and
    ##                 captures stdout+stderr into #+RESULTS. "" = no runner.
    ##   extensions -- comma-separated file extensions to syntax-highlight as
    ##                 this language (e.g. ".py,.pyw"), or "" for none.
    ##   langSpec   -- GtkSourceView .lang XML for highlighting, or "" to use a
    ##                 built-in/already-present spec of the same id.
  ConfigureProc* = proc (ctx: pointer; register: RegisterProc; bindP: BindProc;
                         bindLang: BindLangProc) {.cdecl, gcsafe.}
