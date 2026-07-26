# nimacs.nimble

version       = "0.1.0"
author        = "Luis F. Araujo"
description   = "An Emacs-style GTK text editor whose commands and keybindings are Nim, hot-reloadable while the app runs."
license       = "MIT"
srcDir        = "src"
bin           = @["nimacs"]

requires "nim >= 2.0.0"
requires "owlkettle"

task build, "Build the nimacs binary (project root)":
  exec "nim c -o:nimacs src/nimacs.nim"

task run, "Build and run nimacs":
  exec "nim c -r -o:nimacs src/nimacs.nim"
