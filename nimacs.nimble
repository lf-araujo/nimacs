# nimacs.nimble

version       = "0.1.0"
author        = "Luis F. Araujo"
description   = "An Emacs-style GTK text editor whose commands and keybindings are Nim, hot-reloadable while the app runs."
license       = "MIT"
srcDir        = "src"
bin           = @["nimacs"]

requires "nim >= 2.0.0"
requires "owlkettle"                                   # GTK version (src/nimacs.nim)
requires "https://github.com/nim-lang/uirelays"        # focim branch (src/focim.nim)

task build, "Build the GTK nimacs binary":
  exec "nim c -o:nimacs src/nimacs.nim"

task run, "Build and run the GTK nimacs":
  exec "nim c -r -o:nimacs src/nimacs.nim"

task focim, "Build the uirelays (native, cross-platform) nimacs":
  exec "nim c -o:focim src/focim.nim"

task focimrun, "Build and run the uirelays nimacs":
  exec "nim c -r -o:focim src/focim.nim"

task bundle, "Bundle a self-contained toolchain (Nim + zig) for focim's C-c r":
  # Pass the zig path after `--`, e.g.  nimble bundle -- /opt/zig/zig
  let zig = if paramCount() >= 3: paramStr(paramCount()) else: ""
  exec "bash scripts/bundle-toolchain.sh " & zig
