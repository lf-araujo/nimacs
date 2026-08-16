import widgets/terminal   # starts the widget's background thread at load
import uirelays
echo "READY"
var screen = createWindow(500, 200)
setWindowTitle("diagwin")
var metrics: FontMetrics
let font = openFont("/usr/share/fonts/truetype/hack/Hack-Regular.ttf", 16, metrics)
var e: Event
while true:
  if not waitEvent(e):
    echo "EV waitfalse"; stdout.flushFile(); continue
  echo "EV ", e.kind, " key=", e.key, " txt=", (if e.text[0] != '\0': $e.text[0] else: "")
  stdout.flushFile()
  if e.kind == WindowCloseEvent: break
  screen = getWindowLayout()
  fillRect(rect(0,0,screen.width,screen.height), color(20,20,30))
  refresh()
