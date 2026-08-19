## Extension loader.
##
## Drop a Nim module into the repo's `extensions/` directory that defines
##   proc extend*(app: var App)
## and it is discovered at COMPILE time and run right after the user config, so
## `C-c r` (recompile & reload) compiles in any new or changed extension. An
## extension shares wkbcore's whole API -- it can `defcommand`, `bindkey`,
## `addHook`, `registerRepl`, `registerTheme`, spawn sessions, drive an LSP, etc.
## Files starting with `_` are skipped (helpers/includes).

import wkbcore
export wkbcore
import std/[macros, os, strutils]

macro genLoadExtensions(): untyped =
  ## Emit `import` statements for every extensions/*.nim plus a
  ## `loadExtensions(app)` that calls each module's `extend(app)`.
  const here = currentSourcePath()
  let dir = here.parentDir.parentDir / "extensions"
  result = newStmtList()
  var calls = newStmtList()
  let listing = staticExec("ls -1 " & quoteShell(dir) & " 2>/dev/null")
  for raw in listing.splitLines():
    let name = raw.strip()
    if not name.endsWith(".nim") or name.startsWith("_"): continue
    let modName = name[0 ..< name.len - 4]
    result.add nnkImportStmt.newTree(newLit(dir / name))
    calls.add newCall(newDotExpr(ident(modName), ident("extend")), ident("app"))
  if calls.len == 0: calls.add nnkDiscardStmt.newTree(newEmptyNode())
  result.add newProc(
    name = postfix(ident("loadExtensions"), "*"),
    params = @[newEmptyNode(), newIdentDefs(ident("app"), nnkVarTy.newTree(ident("App")))],
    body = calls)

genLoadExtensions()
