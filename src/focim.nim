## nimacs on uirelays (the "focim" branch): a pure-Nim, custom-rendered editor
## targeting Windows/macOS/Linux. The GTK version (nimacs.nim) stays on main.
##
## Now: app shell + an interactive R session. Ctrl+Enter runs the current line in
## a persistent R (our ported PTY engine) and shows the output in a bottom pane;
## Ctrl+S saves; Ctrl+Q quits.

import uirelays
import uirelays/layout
import widgets/synedit
import focimsession
import std/[tables, os, strutils]

const fontPath =
  when defined(windows): "C:/Windows/Fonts/consola.ttf"
  elif defined(macosx): "/System/Library/Fonts/Menlo.ttc"
  else: "/usr/share/fonts/truetype/hack/Hack-Regular.ttf"

const layoutSrc = "(layout (editor) (session (lines 12)) (status (lines 1)))"

proc main() =
  var screen = createWindow(960, 700)
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
    ed.setText("# Ctrl+Enter runs the current line in R; Ctrl+S saves; Ctrl+Q quits.\n\n" &
               "x <- c(10, 20, 30)\n" &
               "mean(x)\n" &
               "summary(x)\n")

  var sess = createSynEdit(font)
  sess.setText("R session -- put the cursor on a line above and press Ctrl+Enter.\n")
  var session: Session = nil

  let lay = parseLayout(layoutSrc)
  let bg = color(21, 23, 27)
  let sessBg = color(16, 18, 22)
  let statusBg = color(32, 35, 42)
  let statusFg = color(190, 190, 190)
  var msg = "ready"
  let noEvent = Event(kind: NoEvent)

  var e: Event
  while true:
    if not waitEvent(e): continue
    if e.kind in {WindowCloseEvent, QuitEvent}: break

    var consumed = false
    if e.kind == KeyDownEvent and CtrlPressed in e.mods:
      case e.key
      of KeyQ:
        break
      of KeyS:
        if filePath.len > 0:
          ed.saveToFile(filePath); ed.markSaved(); msg = "saved " & extractFilename(filePath)
        else:
          msg = "no file (pass a path on the command line)"
        consumed = true
      of KeyEnter:
        let line = ed.getLineText(ed.currentLine)
        if strutils.strip(line).len > 0:
          if session == nil: session = startSession(rSpec)
          if session == nil:
            msg = "could not start R (is it on PATH?)"
          else:
            let outp = session.runBlock(line)
            sess.appendOutput("> " & line & "\n")
            if outp.len > 0: sess.appendOutput(outp & "\n")
            msg = "ran line"
        consumed = true
      else: discard

    screen = getWindowLayout()
    let cells = resolve(lay, screen.width, screen.height, lineH)
    fillRect(rect(0, 0, screen.width, screen.height), bg)

    if cells.hasKey("editor"):
      discard ed.draw((if consumed: noEvent else: e), cells["editor"], focused = true)
    if cells.hasKey("session"):
      fillRect(cells["session"], sessBg)
      discard sess.draw(noEvent, cells["session"], focused = false)
    if cells.hasKey("status"):
      let sr = cells["status"]
      fillRect(sr, statusBg)
      let name = if filePath.len > 0: extractFilename(filePath) else: "*scratch*"
      let dirty = if ed.changed: " [+]" else: ""
      let info = "  focim   " & name & dirty & "   " &
                 $(ed.currentLine + 1) & ":" & $(ed.currentCol + 1) & "   " & msg
      discard drawText(font, sr.x + 6, sr.y, info, statusFg, statusBg)

    refresh()

  closeSession(session)
  closeFont(font)

when isMainModule:
  main()
