# nimacs — progress / how to resume

Status as of this session: **working end-to-end**. Editor window opens,
typing works natively, `Ctrl+T`/`Ctrl+U` run hot-reloadable commands,
"Reload Config" swaps in edited `config.nim` behavior live without
restarting or losing buffer text. Verified interactively by the user.

## How to run it

```sh
export PATH="$HOME/.local/bin:$PATH"
export MAMBA_ROOT_PREFIX="$HOME/micromamba"
eval "$(micromamba shell hook --shell zsh)"
micromamba activate nimacs
cd "/Users/silvacastrl/Library/CloudStorage/OneDrive-TheUniversityofMelbourne/Coding/Nim/Programs/nimacs"
nim c -o:nimacs src/nimacs.nim   # rebuild after editing nimacs.nim / src/nimacs/*
./nimacs [optional-file-path]     # C-s only saves if a path was given
```

`config.nim` needs no rebuild step — `Ctrl+Shift+R` / "Reload Config"
recompiles and hot-swaps it while the app keeps running.

## Environment setup (already done, for reference / a fresh machine)

GTK4/libadwaita couldn't be installed via brew: this network's Zscaler
proxy blocks `gnu.org` (even tunneled through it directly), and `gettext`
(a transitive build dep, since this custom brew prefix at `~/Documents/.brew`
can't use precompiled bottles) only has gnu.org as a source. Worked around
entirely via **conda-forge** instead (different CDN, unaffected):

```sh
# micromamba itself, fetched from GitHub releases (not the blocked micro.mamba.pm)
curl -Ls -o ~/.local/bin/micromamba \
  "https://github.com/mamba-org/micromamba-releases/releases/download/2.8.1-0/micromamba-osx-arm64"
chmod +x ~/.local/bin/micromamba

export MAMBA_ROOT_PREFIX="$HOME/micromamba"
micromamba create -y -n nimacs -c conda-forge gtk4 libadwaita pkg-config
micromamba install -y -n nimacs -c conda-forge zlib expat libxml2   # fill pkg-config gaps below
nimble install owlkettle
```

Three environment-specific gaps had to be patched manually after the conda
install (all one-time, already done in `~/micromamba/envs/nimacs/`):

1. **Missing `-lxml2`/`-lintl` symlinks** — conda-forge's osx-arm64 packages
   ship versioned dylibs only (`libxml2.16.dylib`, `libintl.8.dylib`), no
   unversioned symlink for the linker's plain `-lxml2`/`-lintl` to find:
   ```sh
   cd ~/micromamba/envs/nimacs/lib
   ln -sf libxml2.16.dylib libxml2.dylib
   ln -sf libintl.8.dylib libintl.dylib
   ```
2. **Missing `libxml-2.0.pc`** — `appstream.pc` (a `libadwaita.pc`
   `Requires.private`) needs it to exist for `pkg-config`'s dependency-graph
   validation, but conda-forge's `libxml2` package doesn't ship one. Hand-
   authored a minimal stub at `~/micromamba/envs/nimacs/lib/pkgconfig/libxml-2.0.pc`
   (`Libs: -lxml2`, no real headers needed since nothing in this project
   `#include`s libxml2 directly).
3. **Uncompiled GSettings schemas** — caused a silent failure: the app ran
   its GTK main loop fine but never actually presented a window (a
   `g_return_if_fail`-triggered early return inside GTK/Adwaita's own
   startup, easy to miss since the process looks perfectly healthy).
   Fixed with:
   ```sh
   glib-compile-schemas ~/micromamba/envs/nimacs/share/glib-2.0/schemas/
   ```

`config.nims` (project root) embeds the conda env's `-rpath` automatically
via `$CONDA_PREFIX` so the built binary can find these dylibs at runtime —
no manual `--passL` flag needed for normal builds.

## Architecture gotchas discovered while building (see DESIGN.md for the rest)

- owlkettle's per-widget `<Name>State` types (e.g. `TextViewState`) are
  generated fresh by the `renderable` macro at each call site and are
  **not reachable from outside owlkettle's own module** — subclassing an
  existing owlkettle widget (e.g. `TextView`) from application code doesn't
  work, confirmed empirically. Fix: `EditorTextView` in `src/nimacs.nim`
  is built from scratch `of BaseWidget`, using owlkettle's public raw GTK
  bindings (`gtk_text_view_new`, `gtk_text_buffer_*`) directly instead of
  owlkettle's own `TextView`/`TextBuffer` wrapper types.
- `viewable`/`renderable` constructor syntax (`App(field = value, ...)`)
  only works **wrapped in `gui(...)`** — `gui(...)` is what translates
  `field = value` into the widget's real `hasField`/`valField` pair. Calling
  `App(field = value)` directly (outside `gui(...)`) fails since the raw
  type has no such constructor proc.
- The installed owlkettle version (nimble pulled `3.0.0`, an older pinned
  commit) is missing a few raw GTK bindings present on owlkettle's current
  `main` branch (e.g. `gtk_event_controller_key_new`,
  `gtk_text_view_get_buffer`). Declared these ourselves in `nimacs.nim` via
  plain `{.importc, cdecl.}` — the underlying GTK4 C library has them
  regardless of what owlkettle's Nim bindings happen to expose.
- **Keyboard-triggered state changes don't auto-redraw.** owlkettle's own
  declarative event hooks (`Button.clicked()` etc.) are dispatched through
  its own callback machinery, which calls `app.redraw()` after your handler
  runs. `EditorTextView`'s key handling is wired directly to a raw
  `GtkEventControllerKey` via `g_signal_connect`, entirely outside that
  machinery — so mutating `app.status` (or anything else the view reads)
  from `handleKey` silently updates memory but never repaints, unless you
  call `discard app.redraw()` yourself. `handleKey` now does this once at
  the end for every handled chord. Symptom that surfaced this: a
  `k.status = "Hello"`-only test command appeared to do nothing over a
  keybinding, while the exact same status-setting pattern worked fine when
  triggered by the "Reload Config" *button*.
- **owlkettle's `FileChooserDialog`/`app.open(...)` SIGSEGVs on this GTK
  version.** Confirmed via stack trace (lldb itself is blocked on this
  managed Mac, so relied on Nim's own `--stacktrace:on` crash trace
  instead) and an isolated minimal repro with none of nimacs's own code
  involved: the crash is inside owlkettle's `beforeBuild` hook for
  `FileChooserDialog`, in its call to `gtk_file_chooser_dialog_new` —
  GTK's now-deprecated legacy file-dialog constructor. owlkettle 3.0.0 was
  written against an older GTK4; this environment's GTK is 4.22.4 (very
  recent), and something about that legacy path no longer tolerates
  whatever owlkettle passes it (likely the `nil` parent at construction
  time, fixed up only *after* construction via
  `gtk_window_set_transient_for`). Fix: bypass owlkettle's dialog machinery
  entirely and call GTK4's modern, actively-maintained `GtkFileDialog`
  API (`gtk_file_dialog_new`/`_set_title`/`_open`/`_open_finish`, GTK
  >=4.10) directly via raw `{.importc, cdecl.}` bindings in `nimacs.nim` —
  same pattern as `EditorTextView` bypassing owlkettle's `TextView`. This
  API is async (`GAsyncReadyCallback`), so like `handleKey`, the callback
  runs outside owlkettle's event-dispatch machinery and needs its own
  explicit `discard app.redraw()`.

## UI

- Header bar, left to right: **Open** (native GTK4 file-open dialog via
  `openFile`/`GtkFileDialog`), **Save** (also `Ctrl+S`), **Edit config.nim**
  (pencil icon — loads `config.nim`'s source into the buffer and repoints
  `filePath` at it, so `Ctrl+S` saves back to `config.nim` directly; then
  "Reload Config" picks up the edit), **Reload Config** (also
  `Ctrl+Shift+R`). All icon-only buttons with tooltips (Adwaita symbolic
  icons: `document-open-symbolic`, `document-save-symbolic`,
  `document-edit-symbolic`, `view-refresh-symbolic`) — installed via
  `micromamba install -y -n nimacs -c conda-forge adwaita-icon-theme`
  (not part of the original gtk4/libadwaita install, the icon theme
  package is separate). `main()` sets `XDG_DATA_DIRS` at startup so GTK's
  icon lookup finds the conda env's icon theme automatically — no need to
  export it manually before running `./nimacs`.
- Both **Open** and **Edit config.nim** load into the single buffer this
  editor has (replacing whatever was there, unsaved) — no multi-buffer
  support yet, same caveat as before.

## Not yet done

- **Nothing committed to git yet** — repo is initialized
  (`Coding/Nim/Programs/nimacs/.git`) with everything staged, but no commit
  made. Do that first thing next session.
- `Ctrl+S` (save) confirmed working via the Edit-config round-trip; the
  **Open** button (via `GtkFileDialog`) is also confirmed working
  end-to-end (no crash, file loads correctly).
- No PR / nothing pushed anywhere (no remote configured either).
