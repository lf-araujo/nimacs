# wkbenchless.nimble

version       = "0.1.0"
author        = "Luis F. Araujo"
description   = "A native, deeply Nim-configurable literate editor: org-babel, LSP, interactive REPL sessions, org-src fontification -- a workbench-less alternative to heavier IDEs."
license       = "MIT"
srcDir        = "src"
bin           = @["wkbenchless"]

requires "nim >= 2.0.0"
requires "https://github.com/nim-lang/uirelays"

task run, "Build and run wkbenchless":
  exec "nim c -r -o:wkbenchless src/wkbenchless.nim"

task bundle, "Bundle a self-contained toolchain (Nim + zig) so C-c r needs no system compiler":
  # Pass the zig path after `--`, e.g.  nimble bundle -- /opt/zig/zig
  let zig = if paramCount() >= 3: paramStr(paramCount()) else: ""
  exec "bash scripts/bundle-toolchain.sh " & zig

# The legacy GTK editor (src/nimacs.nim, owlkettle) is kept for history but is
# no longer built by default; wkbenchless supersedes it.
