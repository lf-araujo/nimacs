# wkbenchless

A native, deeply Nim-configurable **literate editor** — org-babel execution,
LSP completion, interactive REPL sessions, and native org src-block
highlighting — in a single binary. A *workbench-less* alternative to heavier
IDEs: no language server manager, no background service, no Electron.

Written in Nim on [uirelays](https://github.com/nim-lang/uirelays) (custom
rendering, no GTK/Qt), so it targets Linux/macOS/Windows. Your configuration is
**plain Nim compiled into the binary** — commands are Nim procs, keybindings and
languages are data, and `C-c r` recompiles and restarts in place.

## Features

- **Org-babel**: `C-c C-c` runs a `#+begin_src` block in a persistent
  `:session` and writes `#+RESULTS:`. `C-Enter` sends the current line.
- **Interactive sessions**: R, Python, and bash on a PTY we own; the bottom pane
  is a live REPL (type at the prompt). `C-c s` switches sessions, `C-c k` opens
  a bash terminal.
- **Src-edit** (`C-c e` / `C-c b`): zoom into a block as a real code file with
  LSP + highlighting, then splice it back. `C-c t` tangles a whole session.
- **LSP completion**: always-on as you type in code buffers (`C-Space` also
  triggers it manually); nim / python / R (config-registerable).
- **Native org highlighting**: `#+begin_src r … #+end_src` bodies are
  syntax-highlighted in their language, in place. Blocks start **folded** —
  `Tab` on the `#+begin_src` line toggles; `C-c u` unfolds all. `*bold*` and
  `/italic/` render in their faces, `#+caption` a touch larger, and `[[url][x]]`
  links show just the label (Ctrl/Cmd-click or `C-c C-o` to open).
- **Wide tables**: org rows don't reflow; `M-Left` / `M-Right` pan the view so
  columns past the window edge come into reach.
- **RStudio-style panes**: editor · session · objects/environment · help,
  shown in the src-edit view.
- **Find / replace**: `C-f` finds incrementally (all matches highlighted,
  `Enter` cycles); `C-h` is find-and-replace (`Enter` replaces the current
  match, `!` replaces all, `Tab` switches field).
- **Org navigator**: `C-j` opens a palette of the document's headings, named /
  captioned src blocks, and figure / table captions — pick one to jump there.
- **Command palette**: `M-x` (or `C-p`) — scrolls through long lists;
  `C-x C-r` opens a recent file.

## Build & run

Needs the Nim toolchain, and (Linux) `libX11` + `libXft`.

```sh
nimble run          # build + run
# or
nim c -o:wkbenchless src/wkbenchless.nim
./wkbenchless file.org
```

## Configuration

Edit `src/wkbconfig.nim` (`M-x edit-config` / `C-c f`) — it's ordinary Nim with
full access to the editor model. The complete default keymap lives there too, so
every binding is in one place. Apply changes with `C-c r` (recompile & restart).

```nim
proc configure*(app: var App) =
  bindkey("C-c d", "insert-date")
  registerRepl("python", pySpec)          # teach it a language
  addHook("startup", proc(a: var App) = a.msg = "ready")
```

`C-c r` needs a Nim + C compiler. To make it work without a system toolchain,
bundle one next to the binary: `nimble bundle -- /path/to/zig` (see
`scripts/bundle-toolchain.sh`); Nim uses `zig cc` as a hermetic C backend.

## License

MIT. The legacy GTK editor (`src/nimacs.nim`) is kept for history but is no
longer built.
