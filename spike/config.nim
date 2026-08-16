import wkbhost

echo "  [nimscript echo] config body executing"
proc insertDate*() =
  status("insert-date command ran INSIDE the VM")

proc onAsyncDone*(output: string) =
  status("async callback received: " & output)

status("config.nims loaded (top-level code runs)")
bindkey("C-c d", "insert-date")
defcommand("insert-date", "Insert today's date", "insertDate")
runAsync("echo hello-from-a-real-process", "onAsyncDone")
