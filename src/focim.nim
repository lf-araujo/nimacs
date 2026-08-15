## nimacs on uirelays (the "focim" branch): a pure-Nim, custom-rendered editor
## targeting Windows/macOS/Linux. This is the minimal proof-of-concept: a window
## hosting uirelays' SynEdit widget. The GTK version (nimacs.nim) stays on main.

import uirelays
import widgets/synedit

const fontPath =
  when defined(windows): "C:/Windows/Fonts/consola.ttf"
  elif defined(macosx): "/System/Library/Fonts/Menlo.ttc"
  else: "/usr/share/fonts/truetype/hack/Hack-Regular.ttf"

proc main() =
  var layout = createWindow(960, 640)
  setWindowTitle("nimacs (focim)")
  var metrics: FontMetrics
  let font = openFont(fontPath, 15, metrics)
  var ed = createSynEdit(font)
  ed.setText("# nimacs on uirelays -- proof of concept\n\n" &
             "proc greet(name: string) =\n" &
             "  echo \"hello, \", name\n\n" &
             "greet(\"focim\")\n")
  let bg = color(21, 23, 27)
  var e: Event
  var running = true
  while running:
    if not waitEvent(e): continue
    case e.kind
    of WindowCloseEvent, QuitEvent:
      running = false
    else:
      layout = getWindowLayout()
      let area = rect(0, 0, layout.width, layout.height)
      fillRect(area, bg)
      discard ed.draw(e, area, focused = true)
      refresh()
  closeFont(font)

when isMainModule:
  main()
