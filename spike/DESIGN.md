# nimeval config spike — findings

Goal: config/extensions as **real Nim, interpreted in-process** by Nim's VM
(`compiler/nimeval`) — no external compiler, no rebuild-and-re-exec — with the
deepest practical ABI. Proven working in `spike/` (`vmspike.nim` + `wkbhost.nim`
+ `config.nim`).

## It works
`vmspike` embeds the VM, exposes a host API, runs a `.nim` config, calls a
VM-defined command back on a simulated keypress, and delivers an async process
result back into a VM callback. Binary ~17 MB (compiler linked in).

## The model
- **Host API**: `implementRoutine(pkg, module, name, impl)` binds a host proc to
  a signature declared in a stub module (`wkbhost.nim`, bodies `= discard`). The
  config `import`s that module and calls the procs; the VM routes the calls to
  the host impl.
- **Commands**: config defines Nim procs and registers them by *name* string
  (`defcommand("insert-date", label, "insertDate")`). On a keypress the host does
  `selectRoutine("insertDate")` + `callRoutine(...)` to run it in the VM.
- **Parallelism** (the VM has no threads/async — no FFI): the host runs work
  natively (a process we own, or a worker thread) and calls a VM callback proc
  with the result via `callRoutine(cb, @[newStrNode(nkStrLit, output)])`. Same
  shape as Emacs `start-process` + filter.
- **Safety**: `registerErrorHook` swallows config compile/eval errors so a bad
  config doesn't `quit()` the app (see nimteractive for the `cmdIdeTools` trick
  that also stops fatal-msg quits).

## Gotchas (cost real time — remember these)
1. **`pkg` for `implementRoutine` is the NIMBLE PACKAGE NAME**, not `"nim"`. It's
   derived from the nearest up-tree `.nimble` (here `wkbenchless`). The VM matches
   `toKey(sym)` = `name.module.package` against `reverseName(pkg.module.name)`
   (see `vmgen.procIsCallback` / `vmdef.registerCallback`). Wrong pkg ⇒ the call
   silently runs the stub body, no callback. The official example uses `"nim"`
   only because its test modules resolve to that package.
2. Callback fires only for procs the VM treats as external: either `importcCond`
   (`{.importc.}` + empty body) **or** a registered-callback name match
   (`procIsCallback` sets `sym.offset = -2 - index`). A normal proc with a real
   body runs its body.
3. The impl proc must be `proc(a: VmArgs) {.closure, gcsafe.}`.
   Capture a `ctx` ref (makes it a closure) and wrap global/host access in
   `{.cast(gcsafe).}`.
4. Build needs the `compiler` package on the path: `nim.cfg` → `path:"$nim/.."`.
5. Runtime needs Nim's **stdlib source** (`findNimStdLibCompileTime()` +
   `searchPaths`). So "no external compiler" but the stdlib must be present —
   **bundle a trimmed stdlib** for a distributable binary.
6. `getString(a, i)` / `getInt` / `getFloat` read args; `setResult(a, v)` returns.
   `.nim` vs `.nims` doesn't matter — nimeval defines `nimscript` either way.

## What ports from the compiled ABI
Command registry, keymap, hooks, session/objects/help logic — all stay host-side
(native, full FFI). The config just *drives* them through the host API. Deep
`App`/`SynEdit` access becomes a rich host-proc surface (editor ops exposed to
the VM), since the VM can't touch `ptr`/FFI types directly.

## Next
- Define the host API surface (the editor "kernel": bindkey/defcommand/hooks +
  insertText/cursor/appendOutput/runInSession/openFile/setStatus/...).
- Port `wkbconfig` to a VM config + `wkbhost` stub; wire command callbacks.
- Bundle a trimmed stdlib; measure footprint.
