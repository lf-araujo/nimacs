import uirelays   # NO terminal, NO thread
echo "READY"
var screen = createWindow(500, 200)
setWindowTitle("diagwin2")
var metrics: FontMetrics
let font = openFont("/usr/share/fonts/truetype/hack/Hack-Regular.ttf", 16, metrics)
var e: Event
var esc = 0
var other = 0
while true:
  if not waitEvent(e): continue
  if e.kind == KeyDownEvent and e.key == KeyEsc: inc esc
  elif e.kind != NoEvent: inc other
  if e.kind == WindowCloseEvent: break
  echo "escKeyDowns=", esc, " otherEvts=", other; stdout.flushFile()
  screen = getWindowLayout()
  fillRect(rect(0,0,screen.width,screen.height), color(20,20,30))
  refresh()
