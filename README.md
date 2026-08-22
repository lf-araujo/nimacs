# wkbenchless

A native **scientific workbench** in a single binary — a deeply Nim-configurable
literate editor with org-babel execution, LSP completion, interactive REPL
sessions, a real embedded terminal, and native org src-block highlighting. A
*workbench-less* alternative to heavier IDEs: no language-server manager, no
background service, no Electron.

> **Work in progress.** wkbenchless aims to reproduce, as one native binary, the
> literate scientific-workbench workflow the author built in Emacs (the
> [workbenchless](https://github.com/lf-araujo/workbenchless) config) — org-mode
> notebooks, remote REPLs, inline figures, and manuscript round-tripping —
> without Emacs. Expect rough edges; features are still landing.

![An org notebook in wkbenchless with a figure rendered inline](docs/screenshot.png)

Written in Nim on [uirelays](https://github.com/nim-lang/uirelays) (custom
rendering, no GTK/Qt), so it targets Linux/macOS/Windows. Your configuration is
**plain Nim compiled into the binary** — commands are Nim procs, keybindings,
languages, and themes are data, and `C-c r` recompiles and restarts *in place*,
**without dropping your running sessions or terminals**.

## Features

- **Org-babel**: `C-c C-c` runs a `#+begin_src` block in a persistent
  `:session` and writes `#+RESULTS:`. `C-Enter` sends the current line to the
  current session.
- **Sessions are live terminals**: R, Python, and bash run on a PTY we own. The
  bottom pane is a live terminal — type at it interactively *and* run blocks
  against the same process (shared state). `C-c s` cycles sessions/terminals,
  `C-c k` opens a bash session.
- **Embedded terminal**: `M-t` opens a bash terminal in the bottom pane. A
  built-in **VT/ANSI screen emulator** renders cursor-addressed TUIs — `top`,
  `htop`, `vim` — correctly, with colors, mouse text-selection (drag to copy),
  and wheel scrollback. Terminals are first-class tabs alongside sessions.
- **Src-edit** (`C-c e` / `C-c b`): zoom into a block as a real code file with
  LSP + highlighting, then splice it back. `C-c t` tangles a whole session.
- **LSP completion**: always-on as you type in code buffers (`C-Space` also
  triggers it); nim / python / R (config-registerable).
- **Native org highlighting**: `#+begin_src r … #+end_src` bodies are
  syntax-highlighted in their language, in place. Blocks start **folded** —
  `Tab` toggles; `C-c u` unfolds all. `*bold*` / `/italic/` render in their
  faces, `#+caption` a touch larger, and `[[target][label]]` links show just the
  label. Click (or `C-c C-o`) follows a link — **`[[file:…]]` to a text/source
  file opens it in the editor**, URLs and other files hand off to the system.
- **Inline figures**: whole-line image links render right in the buffer, Emacs
  org-mode style — `[[file:fig.png]]` or `![](fig.png)`. Shown at the image's
  own dimensions by default; size a figure with a preceding `#+ATTR_ORG: :width
  N` (aspect ratio preserved) or set a default with `gInlineImageWidth`. Toggle
  with `M-x toggle-inline-images`. PNG/JPG/GIF/… load via a cached conversion
  (needs ImageMagick); BMP decodes natively.
- **LaTeX previews**: `M-x latex-preview` renders whole-line display math —
  `$$…$$`, `\[…\]`, `\(…\)`, `$…$` — to images shown in place (org-latex-preview
  style), via `latex` + `dvipng`. `#+LATEX_HEADER:` lines feed the preamble; the
  source returns while the cursor is on the line. `gLatexDpi` sets the size.
- **Remote sessions over SSH**: a `:session name@host` header — or a
  document-level `#+PROPERTY: header-args LANG :session … :ssh host` — runs
  blocks on a remote interpreter over a multiplexed SSH connection and captures
  the results locally, password hosts included.
- **CriticMarkup** (tracked changes): org buffers colour `{++insertions++}`
  (green), `{--deletions--}` (red), `{~~old~>new~~}`, `{>>comments<<}` (grey),
  and `{==highlights==}` (yellow). Resolve with `M-x criticmarkup-accept-all` /
  `-reject-all` (`C-c j` / `C-c l`). Pairs with the `org-tracked-docx` round-trip.
- **Two-pane diff view**: `M-x diff-buffer` shows the buffer vs its saved file
  side by side (removals red, additions green, aligned by LCS). Agents can push
  a diff — see *Agent control* below.
- **Themes**: base16 colour themes drive the editor *and* the whole UI. `M-x
  theme` (or `C-c C-t`) switches live; the choice persists to
  `~/.config/wkbenchless/state.cfg` and is restored on start. Ships `seventeen`
  (a light NANO/Sublime-“Sixteen” theme, the default), one-dark, gruvbox-dark,
  and solarized-light — add your own in the config.
- **Wide tables**: org rows don't reflow; `M-Left` / `M-Right` pan the view.
- **RStudio-style panes**: editor · session · objects/environment · help.
- **Find / replace**: `C-f` finds incrementally, `C-h` find-and-replace.
- **Org navigator**: `C-j` — a palette of headings, named/captioned blocks, and
  figure/table captions; pick one to jump.
- **Command palette**: `M-x` (or `C-p`); `C-x C-r` opens a recent file.

Src-edit (`C-c e`) zooms a block into an isolated code file with LSP, alongside
the objects/environment and help panes — then splices it back into the org
document:

![A src block opened as an isolated R file, with the objects and help panes](docs/screenshot-srcedit.png)

## Build & run

Needs the Nim toolchain, and (Linux) `libX11` + `libXft`. macOS uses the native
Cocoa backend.

```sh
nimble run          # build + run
# or
nim c -o:wkbenchless src/wkbenchless.nim
./wkbenchless file.org
```

Prebuilt binaries for Linux/macOS are attached to each
[GitHub release](https://github.com/lf-araujo/wkbenchless/releases) (see
*Releases* below).

## Configuration

Edit `src/wkbconfig.nim` (`M-x edit-config` / `C-c f`) — ordinary Nim with full
access to the editor model. The complete default keymap, the languages, and the
themes all live there, so everything is in one place. Apply changes with `C-c r`
(recompile & restart — your open sessions and terminals survive the reload).

```nim
proc configure*(app: var App) =
  bindkey("C-c d", "insert-date")
  registerRepl("python", pySpec)                 # teach it a language
  registerTheme("mine", [rgb(0x1e1e2e), …16…])   # add a base16 theme
  addExecPath("~/.local/bin")                    # extend PATH for sessions
  addHook("startup", proc(a: var App) = a.msg = "ready")
```

Sessions and terminals inherit a PATH seeded from your **login shell**
(`$SHELL -lc`), so they find R / python / latex even when launched from a GUI;
add more with `addExecPath`.

`C-c r` needs a Nim + C compiler. To work without a system toolchain, bundle one
next to the binary: `nimble bundle -- /path/to/zig` (see
`scripts/bundle-toolchain.sh`); Nim uses `zig cc` as a hermetic C backend.

## Agent control (`ctl`)

The editor exposes a loopback control socket (127.0.0.1, token-authenticated)
that drives a running instance — handy for scripts and for agents in the
embedded terminal. It's built into the binary, so **`wkbenchless ctl <verb>`**
is all you need; the shipped release is a single binary. (`wkbctl` is an
optional convenience — build it with `nimble build`, or symlink it to
`wkbenchless`; the examples below work with either name.) Works on
Linux/macOS/Windows.

```sh
wkbctl buffer                          # print the current buffer
wkbctl blocks                          # list #+begin_src blocks
echo 'summary(fit)' | wkbctl eval r default    # run code in a live session
echo TEXT | wkbctl set-buffer          # replace the buffer
echo TEXT | wkbctl insert 12           # insert before line 12
echo TEXT | wkbctl replace 3 5         # replace lines 3..5
wkbctl goto 40                         # move the cursor
wkbctl run-block 16                    # run the src block at line 16 (writes #+RESULTS)
wkbctl diff old.txt new.txt "changes"  # show a side-by-side diff
wkbctl command <name>                  # run any M-x command (echoes its status line)
```

When driving an org file, prefer `wkbctl run-block <line>` over piping code to
`eval`: it runs through the editor's own babel, so the block executes in its
`:session`, in its language, and writes `#+RESULTS:` back into the buffer.

## Releases

`.github/workflows/release.yml` builds a **single `wkbenchless` binary** per
platform (Linux/macOS/Windows) and attaches them to a GitHub release. Trigger it
by pushing a version tag:

```sh
git tag v0.2.2
git push origin v0.2.2
```

or run it manually from the repo's **Actions** tab (“Build and release
binaries” → *Run workflow*), giving the release tag as input. All three
platforms build: Linux (X11) and macOS (Cocoa) with a POSIX PTY, and Windows
with a ConPTY terminal and the winapi UI driver. The control socket is loopback
TCP and works on **all three** (`wkbenchless ctl …`). The fd-handoff hot reload
(`C-c r` preserving sessions) is still POSIX-only; on Windows `C-c r` rebuilds
and restarts without the live-session handoff.

## License

MIT. The legacy GTK editor (`src/nimacs.nim`) is kept for history but is no
longer built.
