import uirelays

proc run(title: string) =
  echo "READY"
  var screen = createWindow(560, 220)
  setWindowTitle(title)
  var metrics: FontMetrics
  let font = openFont("/usr/share/fonts/truetype/hack/Hack-Regular.ttf", 16, metrics)
  var typed = ""
  var e: Event
  while true:
    if not waitEvent(e): continue
    if e.kind in {WindowCloseEvent, QuitEvent}: break
    if e.kind == KeyDownEvent and e.key == KeyEsc: break
    if e.kind == TextInputEvent:
      for ch in e.text:
        if ch != '\0':
          typed.add ch
          stdout.write("KEY:" & ch & "\n"); stdout.flushFile()
    screen = getWindowLayout()
    fillRect(rect(0, 0, screen.width, screen.height), color(20, 20, 30))
    discard drawText(font, 12, 60, "> " & typed, color(120, 230, 120), color(20, 20, 30))
    refresh()
run("t1baseline")
