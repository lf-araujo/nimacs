## Host-owned live command/keybinding tables, and the reload sequence that
## swaps in a freshly-compiled config.nim's .so without ever leaving a
## dangling function pointer in the tables. See DESIGN.md for why the
## ordering here (clear -> register into new .so -> unload old .so) matters:
## the command table holds live function pointers into whichever .so is
## "current", so that .so must stay mapped for as long as those pointers
## are reachable — unlike nimteractive's disposable per-eval .so's, which
## never return anything that must outlive the call.

import std/[tables, dynlib, os, strutils]
import ./config_api
import ./hotcompile
export config_api

type
  ReplFields* = object  ## config-provided pieces of an interactive :session spec
    command*, prime*, ready*, run*, quit*: string
  Dispatch* = ref object
    commands: Table[string, CommandProc]
    keymap: Table[string, string]  ## keychord -> command name
    babelRunners: Table[string, string]  ## babel langId -> one-shot run template
    langByExt: Table[string, string]     ## file extension -> highlight langId
    langSpecs: Table[string, string]     ## langId -> GtkSourceView .lang XML
    replSpecs: Table[string, ReplFields] ## langId -> interactive :session spec
    currentLib: LibHandle
    reloadCounter: int
    key: string  ## hotcompile cache key (nim version hash)

proc newDispatch*(cacheKey: string): Dispatch =
  Dispatch(
    commands: initTable[string, CommandProc](),
    keymap: initTable[string, string](),
    babelRunners: initTable[string, string](),
    langByExt: initTable[string, string](),
    langSpecs: initTable[string, string](),
    replSpecs: initTable[string, ReplFields](),
    currentLib: nil,
    reloadCounter: 0,
    key: cacheKey,
  )

proc hostRegister(ctxRaw: pointer; name: cstring; fn: CommandProc) {.cdecl.} =
  let d = cast[Dispatch](ctxRaw)
  d.commands[$name] = fn

proc hostBind(ctxRaw: pointer; keychord: cstring; commandName: cstring) {.cdecl.} =
  let d = cast[Dispatch](ctxRaw)
  d.keymap[$keychord] = $commandName

proc hostBindLang(ctxRaw: pointer; langId, command, extensions, langSpec: cstring) {.cdecl.} =
  let d = cast[Dispatch](ctxRaw)
  let id = ($langId).toLowerAscii
  if id.len == 0: return
  if ($command).len > 0:
    d.babelRunners[id] = $command
  if ($langSpec).len > 0:
    d.langSpecs[id] = $langSpec
  for e in ($extensions).split(','):
    let ext = e.strip().toLowerAscii
    if ext.len > 0:
      d.langByExt[(if ext.startsWith("."): ext else: "." & ext)] = id

proc hostBindRepl(ctxRaw: pointer; langId, command, prime, ready, run, quitCmd: cstring) {.cdecl.} =
  let d = cast[Dispatch](ctxRaw)
  let id = ($langId).toLowerAscii
  if id.len == 0 or ($command).len == 0: return
  d.replSpecs[id] = ReplFields(command: $command, prime: $prime, ready: $ready,
                               run: $run, quit: $quitCmd)

iterator configRepls*(d: Dispatch): tuple[lang: string, fields: ReplFields] =
  ## Config-registered interactive :session specs (langId, fields).
  for lang, fields in d.replSpecs:
    yield (lang, fields)

iterator configCommands*(d: Dispatch): tuple[name: string, fn: CommandProc] =
  ## Commands config.nim registered (for the palette / menu).
  for name, fn in d.commands:
    yield (name, fn)

proc lookup*(d: Dispatch; keychord: string): CommandProc =
  let name = d.keymap.getOrDefault(keychord, "")
  if name == "": return nil
  d.commands.getOrDefault(name, nil)

proc babelCommand*(d: Dispatch; lang: string): string =
  ## One-shot run template registered for `lang`, or "" if none.
  d.babelRunners.getOrDefault(lang.toLowerAscii, "")

proc langIdForExt*(d: Dispatch; ext: string): string =
  ## Config-registered highlight language id for a file extension, or "".
  d.langByExt.getOrDefault(ext.toLowerAscii, "")

iterator configLangSpecs*(d: Dispatch): tuple[id, xml: string] =
  ## Config-provided GtkSourceView .lang definitions (id, XML).
  for id, xml in d.langSpecs:
    yield (id, xml)

proc reloadConfig*(d: Dispatch; configPath: string; searchPaths: seq[string]): tuple[ok: bool, msg: string] =
  if not fileExists(configPath):
    return (false, "no such file: " & configPath)
  inc d.reloadCounter
  let tag = "config_" & $d.reloadCounter
  let (soPath, compileErr) = compileToLib(d.key, configPath, tag, searchPaths)
  if compileErr != "":
    return (false, compileErr)

  let newLib = loadLib(soPath)
  if newLib == nil:
    return (false, "could not dlopen compiled config: " & soPath)

  let configureFn = cast[ConfigureProc](newLib.symAddr("nimacs_configure"))
  if configureFn == nil:
    unloadLib(newLib)
    return (false, "config.nim must define nimacs_configure(...) {.exportc, dynlib.}")

  # Drop all references into whatever .so is currently loaded *before*
  # calling into the new one, so by the time we unload the old library
  # below, nothing in the tables still points at it.
  d.commands.clear()
  d.keymap.clear()
  d.babelRunners.clear()
  d.langByExt.clear()
  d.langSpecs.clear()
  d.replSpecs.clear()
  configureFn(cast[pointer](d), hostRegister, hostBind, hostBindLang, hostBindRepl)

  let previousLib = d.currentLib
  d.currentLib = newLib
  if previousLib != nil:
    unloadLib(previousLib)

  result = (true, "config reloaded (" & $d.commands.len & " commands, " &
    $d.keymap.len & " bindings, " & $d.babelRunners.len & " babel langs, " &
    $d.replSpecs.len & " sessions)")
