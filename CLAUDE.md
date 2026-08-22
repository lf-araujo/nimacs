# Working in wkbenchless (agent instructions)

wkbenchless is a native Nim literate editor. When you (Claude) run **inside its
embedded terminal**, drive the live editor over its control socket with
**`wkbctl`** instead of editing files blind or grep-and-piping code.

## Detect it
The socket is live when this responds:
```sh
wkbctl blocks    # lists #+begin_src blocks as "  <line>: <header>"
```
If `wkbctl` isn't found or errors, wkbenchless isn't running here — work with
files normally. (`wkbctl <verb>` is just `wkbenchless ctl <verb>` — the editor
binary embeds the same client; either works, on Linux/macOS/Windows.)

## Read the live buffer
- `wkbctl buffer` — the current buffer's full text (use this, not the file on
  disk; the buffer may have unsaved edits).
- `wkbctl blocks` — src blocks with their 1-based line numbers.

## Run org src blocks — use the editor's babel, NOT eval
To run a specific block, position + run the editor's own `C-c C-c` so it
executes in the block's `:session`, respects its language, and **writes
`#+RESULTS:` back into the buffer**:
```sh
wkbctl run-block <line>     # <line> = the block's #+begin_src line (from `blocks`)
```
Do **not** grep code out of a block and pipe it to `wkbctl eval` — that ignores
the block's session/language and doesn't write results. Reserve `eval` for
ad-hoc, throwaway code:
```sh
echo 'summary(fit)' | wkbctl eval r default     # ad-hoc in the r/default session
```

## Edit the buffer
- `echo TEXT | wkbctl set-buffer` — replace the whole buffer.
- `echo TEXT | wkbctl insert <line>` — insert before 1-based `<line>`.
- `echo TEXT | wkbctl replace <from> <to>` — replace 1-based lines `[from..to]`.
- `wkbctl goto <line>` — move the cursor.

## Show the user changes — use the diff panel
When you change files, show them in the editor's diff pane (renders in the top
editor area; the terminal stays live):
```sh
git show HEAD:path/file > /tmp/old && wkbctl diff /tmp/old path/file "what changed"
```

## Run any editor command / reload
- `wkbctl command <name>` — run any `M-x` command.
- `wkbctl command recompile` — after editing wkbenchless's own source, rebuild &
  hot-reload the running instance (sessions and terminals are preserved).

## Building this project
```sh
nim c --hints:off -o:wkbenchless src/wkbenchless.nim   # the editor
nim c --hints:off -o:wkbctl src/wkbctl.nim             # the control CLI
```
Extensions live in `extensions/*.nim` (each `proc extend*(app: var App)`), are
compiled in on `C-c r`, and filenames must be valid Nim identifiers (use `_`).
Windows is cross-checked with mingw (see the harness memory).
