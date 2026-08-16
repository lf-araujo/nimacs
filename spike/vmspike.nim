## nimeval spike: embed Nim's VM, expose a host API to a .nims config, run it,
## call a VM-defined command back from the host, and deliver an async process
## result back into the VM (the host-managed-parallelism model).

import compiler/[ast, vmdef, vm, nimeval, llstream, lineinfos, options]
import std/[os, tables, strutils, osproc]

type
  Cmd = object
    label, procName: string
  Ctx = ref object
    keymap: Table[string, string]      # chord -> command name
    commands: Table[string, Cmd]       # command name -> {label, VM proc}
    pending: seq[(string, string)]     # (output, callback proc) from async work

proc makeInterp(script: string): Interpreter =
  let std = findNimStdLibCompileTime()
  result = createInterpreter(script,
    [std, std / "pure", std / "core", parentDir(currentSourcePath)])
  result.registerErrorHook(proc(config: ConfigRef; info: TLineInfo;
                                msg: string; sev: Severity) {.gcsafe.} =
    if sev == Severity.Error:
      stderr.writeLine("  [config error] " & msg))

proc main() =
  let ctx = Ctx()
  let i = makeInterp("config.nim")

  i.implementRoutine("wkbenchless", "wkbhost", "status", proc(a: VmArgs) {.gcsafe.} =
    echo "  [status] ", getString(a, 0))
  i.implementRoutine("wkbenchless", "wkbhost", "bindkey", proc(a: VmArgs) {.gcsafe.} =
    {.cast(gcsafe).}:
      ctx.keymap[getString(a, 0)] = getString(a, 1)
      echo "  [bindkey] ", getString(a, 0), " -> ", getString(a, 1))
  i.implementRoutine("wkbenchless", "wkbhost", "defcommand", proc(a: VmArgs) {.gcsafe.} =
    {.cast(gcsafe).}:
      ctx.commands[getString(a, 0)] = Cmd(label: getString(a, 1), procName: getString(a, 2))
      echo "  [defcommand] ", getString(a, 0), " -> proc ", getString(a, 2))
  i.implementRoutine("wkbenchless", "wkbhost", "runAsync", proc(a: VmArgs) {.gcsafe.} =
    {.cast(gcsafe).}:
      let cmd = getString(a, 0)
      let cb = getString(a, 1)
      echo "  [runAsync] host runs: ", cmd
      let (outp, _) = execCmdEx(cmd)          # native host work (could be threaded)
      ctx.pending.add (outp.strip, cb))

  echo "=== 1. evalScript (top-level config runs) ==="
  i.evalScript()

  echo "=== 2. host state populated from the VM ==="
  echo "  keymap:   ", ctx.keymap
  echo "  commands: ", ctx.commands

  echo "=== 3. simulate keypress 'C-c d' -> call the VM command ==="
  if ctx.keymap.hasKey("C-c d"):
    let r = i.selectRoutine(ctx.commands[ctx.keymap["C-c d"]].procName)
    if r != nil: discard i.callRoutine(r, @[])

  echo "=== 4. deliver async result back into the VM (parallelism model) ==="
  for (outp, cb) in ctx.pending:
    let r = i.selectRoutine(cb)
    if r != nil: discard i.callRoutine(r, @[newStrNode(nkStrLit, outp)])

  i.destroyInterpreter()
  echo "=== done ==="

main()
