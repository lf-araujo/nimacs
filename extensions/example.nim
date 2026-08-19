## Example wkbenchless extension. Copy this file, rename it, and edit `extend`;
## it is compiled in on the next `C-c r`. Delete it if you don't want the demo.
import wkbcore

proc extend*(app: var App) =
  defcommand("ext-hello", "Extension: hello from example.nim", proc(a: var App) =
    a.msg = "hello from the example extension")
  bindkey("C-c C-y", "ext-hello")
