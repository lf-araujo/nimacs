## Compile `config.nim` (a real, user-edited file — not inline-generated
## source) into a fresh shared library, reusing a persistent nimcache dir so
## repeated reloads only pay for their own delta, not the whole toolchain's
## startup cost. Adapted from nimteractive's `compiler.nim` (compileToLib),
## simplified: config.nim always imports the same fixed `nimacs/config_api`
## module (never owlkettle), so the cache key only needs to track the Nim
## compiler version, not a variable import set.

import std/[os, osproc, sha1, strutils]

const CacheBase = "~/.cache/nimacs"

proc cacheDir*(): string =
  expandTilde(CacheBase)

proc nimVersion*(): string =
  let (output, _) = execCmdEx("nim --version")
  result = output.splitLines()[0]

proc cacheKey*(): string =
  ($secureHash(nimVersion()))[0..15]

proc sessionCacheDir*(key: string): string =
  cacheDir() / key

proc tmpDir*(key: string): string =
  sessionCacheDir(key) / "tmp"

proc nimcacheDir*(key: string): string =
  sessionCacheDir(key) / "nimcache"

proc compileToLib*(key: string; sourcePath: string; tag: string;
                    searchPaths: seq[string] = @[]): tuple[soPath: string, err: string] =
  ## `tag` must be unique per call (caller's job — e.g. an incrementing
  ## reload counter) so a fresh reload never overwrites the .so file the
  ## currently-loaded library handle still has mapped.
  let dir = tmpDir(key)
  createDir(dir)
  createDir(nimcacheDir(key))
  let soPath = dir / (tag & ".so")
  var pathFlags = ""
  for p in searchPaths:
    pathFlags &= " --path:" & quoteShell(p)
  let cmd = "nim c --app:lib -d:release --hints:off --warnings:off " &
            "--nimcache:" & quoteShell(nimcacheDir(key)) & pathFlags & " " &
            "-o:" & quoteShell(soPath) & " " & quoteShell(sourcePath)
  let (output, code) = execCmdEx(cmd)
  if code != 0:
    return ("", output)
  result = (soPath, "")
