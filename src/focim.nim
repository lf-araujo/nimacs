## nimacs on uirelays (the "focim" branch): a pure-Nim, custom-rendered editor
## targeting Windows/macOS/Linux. The GTK version (nimacs.nim) stays on main.
##
## Step 1: the app shell -- a NIF-driven layout (editor + status bar), the main
## event loop, a themed status line, file open from the command line, Ctrl+Q.

import uirelays
import uirelays/layout
import widgets/synedit
import std/[tables, os]

const fontPath =
  when defined(windows): "C:/Windows/Fonts/consola.ttf"
  elif defined(macosx): "/System/Library/Fonts/Menlo.ttc"
  else: "/usr/share/fonts/truetype/hack/Hack-Regular.ttf"

# Window is stacked top-to-bottom: the editor stretches, a one-line status bar
# sits at the bottom. (rows/cols nesting will grow this into the 4-quadrant view.)
const layoutSrc = "(layout (editor) (status (lines 1)))"

proc main() =
  var screen = createWindow(960, 640)
  setWindowTitle("nimacs (focim)")
  var metrics: FontMetrics
  let font = openFont(fontPath, 15, metrics)
  let lineH = metrics.lineHeight

  var ed = createSynEdit(font)
  var filePath = ""
  if paramCount() >= 1 and fileExists(paramStr(1)):
    filePath = paramStr(1)
    ed.loadFromFile(filePath)
  else:
    ed.setText("# nimacs on uirelays -- app shell\n\n" &
               "proc greet(name: string) =\n  echo \"hello, \", name\n\n" &
               "greet(\"focim\")\n")

  let lay = parseLayout(layoutSrc)
  let bg = color(21, 23, 27)
  let statusBg = color(32, 35, 42)
  let statusFg = color(190, 190, 190)

  var e: Event
  while true:
    if not waitEvent(e): continue
    if e.kind in {WindowCloseEvent, QuitEvent}: break
    if e.kind == KeyDownEvent and CtrlPressed in e.mods and e.key == KeyQ: break

    screen = getWindowLayout()
    let cells = resolve(lay, screen.width, screen.height, lineH)
    fillRect(rect(0, 0, screen.width, screen.height), bg)

    if cells.hasKey("editor"):
      discard ed.draw(e, cells["editor"], focused = true)

    if cells.hasKey("status"):
      let sr = cells["status"]
      fillRect(sr, statusBg)
      let name = if filePath.len > 0: extractFilename(filePath) else: "*scratch*"
      let dirty = if ed.changed: " [+]" else: ""
      let info = "  focim    " & name & dirty & "    " &
                 $(ed.currentLine + 1) & ":" & $(ed.currentCol + 1)
      discard drawText(font, sr.x + 6, sr.y, info, statusFg, statusBg)

    refresh()
  closeFont(font)

when isMainModule:
  main()
