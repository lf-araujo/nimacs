# nimacs

An Emacs-style GTK4 text editor whose commands and keybindings are Nim code
— redefinable and hot-reloadable while the app is running, without
restarting the process or losing the buffer's contents. The GUI counterpart
to editing `init.el` and `M-x eval-buffer` in real Emacs.

## Why not Nim's own `--hotCodeReloading`

Investigated for [nimteractive](../nimteractive)'s `:procs`/`:kernel` reload
first and rejected there: it forces `-d:useNimRtl`, which doesn't compile
alongside `osproc` on current Nim (upstream Nim issue #23162), needs a
second runtime (`nimrtl`/`nimhcr`) shipped alongside the binary, can't
survive a changed type layout, and Nim's own compiler team ships its
integration test for the feature disabled. Same conclusion applies here,
doubly so — a GTK app is a single long-lived process with live GObject
widgets and signal-handler closures wired at startup; there's no clean way
to redirect those to a freshly `dlopen`'d module's vtable anyway.

## Architecture

Two halves, mirroring nimteractive's `:kernel`/`:procs` split exactly:

```
┌───────────────────────────────────────────────────────────────────┐
│  HOST (src/nimacs.nim -- compiled once, never reloaded)           │
│                                                                     │
│  owlkettle/GTK app: Window, EditorTextView, HeaderBar, status      │
│  Label. Owns:                                                      │
│    - EditorKernel  (buffer text, cursor, status -- plain data,     │
│                      host-allocated, survives every config reload) │
│    - Dispatch      (live Table[string, CommandProc] +              │
│                      Table[string, string] keymap)                 │
│                                                                     │
│  A GtkEventControllerKey on the TextView intercepts every          │
│  keystroke, builds a keychord string, and either:                  │
│    - runs a host built-in (Ctrl+Shift+R reload, Ctrl+S save), or   │
│    - looks it up in Dispatch and calls the matching CommandProc    │
│      (syncing EditorKernel from/to the live GTK buffer around      │
│      the call), or                                                 │
│    - returns "not handled" -- GTK's own native TextView behavior   │
│      (self-insert, backspace, arrows, ...) runs exactly as if we   │
│      weren't there.                                                │
└───────────────────────────────────────────────────────────────────┘
                              │  dlopen / dlsym / dlclose
                              ▼
┌───────────────────────────────────────────────────────────────────┐
│  RELOADABLE (config.nim -- your "init.el")                        │
│                                                                     │
│  Imports ONLY nimacs/config_api (which pulls in nimacs/kernel) --  │
│  never owlkettle. Defines commands as `proc(k: ptr EditorKernel)`  │
│  and registers them + their keybindings via a single exported      │
│  entry proc:                                                       │
│                                                                     │
│    proc nimacs_configure(ctx: pointer; register: RegisterProc;    │
│                           bindP: BindProc) {.exportc, dynlib.}     │
└───────────────────────────────────────────────────────────────────┘
```

## Why the reload sequence is more careful than nimteractive's

nimteractive's eval `.so`s are disposable: `dlopen` → call → capture stdout
→ `dlclose`, every time, because nothing needs to outlive the call. nimacs's
config `.so` is different — **the command table holds live function
pointers into whichever `.so` is currently loaded**, so that library must
stay mapped for as long as those pointers are reachable. `dlclose`-ing it
early leaves dangling function pointers in the table (a real
crash-on-next-keypress bug). `dispatch.reloadConfig` (`src/nimacs/dispatch.nim`)
does this in order:

1. Compile `config.nim` → a freshly-tagged `.so`, `loadLib` it.
2. Look up its `nimacs_configure` entry proc.
3. Clear the host's live command/keybinding tables — drops all references
   to whatever `.so` was previously current.
4. Call the new entry proc, which registers fresh commands/bindings —
   these function pointers are into the *new* `.so`, now safe to hold.
5. Only now `unloadLib` the *previous* `.so`'s handle (`Dispatch.currentLib`
   tracks it). The new one stays loaded until superseded by the next reload.

Ownership follows the same "host owns durable state" discipline used
throughout: instead of the `.so` allocating and returning a `seq[Command]`
by value (untested lifetime once its originating `.so` is unloaded), the
host passes two callback function pointers (`register`, `bindP`) *into* the
`.so`'s entry proc, which calls them once per command/binding. The host's
callbacks copy `cstring` → Nim `string` into host-owned tables immediately.
Nothing is ever returned by value out of a `.so` — only `ptr EditorKernel`
(raw pointer, ABI-stable across independently-compiled units sharing the
same textual type definition — validated by nimteractive's
`spike/kernel-reload/` ASAN stress test) and plain function pointers (kept
alive per the sequence above) ever cross the boundary.

## Keymap semantics

Every keypress builds a chord string (`"C-t"`, `"C-s"`, ...) from the GDK
keyval + Ctrl/Shift modifier bits (`src/nimacs.nim`'s `keychord`). Built-in
host bindings (`Ctrl+Shift+R` reload, `Ctrl+S` save) are checked first and
can never be shadowed by config.nim — rebinding the only way to trigger a
reload would be a footgun. Anything else is looked up in `Dispatch`; a miss
returns "not handled" to GTK, so ordinary typing, backspace, and arrow keys
all continue to work exactly as GTK's native `TextView` already implements
them — no self-insert engine of our own to get subtly wrong.

## File layout

```
nimacs/
├── nimacs.nimble
├── config.nim              # user's "init.el" -- example commands
├── src/
│   ├── nimacs.nim           # host: owlkettle app, EditorTextView, keymap dispatch
│   └── nimacs/
│       ├── kernel.nim       # EditorKernel -- the one type shared across the .so boundary
│       ├── config_api.nim   # CommandProc/RegisterProc/BindProc + nimacs_configure contract
│       ├── hotcompile.nim   # compileToLib, adapted from nimteractive's compiler.nim
│       └── dispatch.nim     # live command/keybinding tables + reloadConfig
└── DESIGN.md
```

## Out of scope (for now)

- Multiple buffers/windows, a minibuffer command palette (`M-x`), real
  keymap prefix sequences (`C-x C-s`) — single-chord bindings only
- Undo/redo beyond what GTK's TextBuffer gives for free, syntax
  highlighting, a file-chooser dialog
- Packaging/distribution — this is a dev-run project like the other
  entries under `Coding/Nim/Programs/`
