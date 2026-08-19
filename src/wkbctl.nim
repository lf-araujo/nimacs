## wkbctl -- talk to a running wkbenchless over its control socket.
## For scripts/agents (e.g. Claude in the terminal) to drive the editor.
##
##   wkbctl buffer                        # print the current buffer
##   wkbctl blocks                        # list #+begin_src blocks (line: header)
##   wkbctl command <name>                # run a registered command
##   echo 'mean(1:10)' | wkbctl eval r default   # run code in a live session
##   echo TEXT | wkbctl set-buffer        # replace the whole buffer
##   echo TEXT | wkbctl insert <line>     # insert before 1-based <line>
##   echo TEXT | wkbctl replace <from> <to>   # replace 1-based lines [from..to]
##   wkbctl goto <line>                   # move the cursor
##   wkbctl diff <oldfile> <newfile> [title]  # show a side-by-side diff
##
## Verbs that take text read it from stdin. lang/session default to r/default.
## POSIX-only for now: the control socket is AF_UNIX (a Windows named-pipe port
## is future work).

when defined(posix):
  import std/[net, os]
  from std/posix import shutdown, SHUT_WR

  proc main() =
    let args = commandLineParams()
    if args.len == 0:
      quit("usage: wkbctl buffer|blocks|command <name>|eval [lang] [session]|diff <old> <new>", 1)
    var req = ""
    case args[0]
    of "buffer", "blocks":
      req = args[0]
    of "command":
      if args.len < 2: quit("wkbctl command <name>", 1)
      req = "command\t" & args[1]
    of "eval":
      let lang = if args.len > 1: args[1] else: "r"
      let sess = if args.len > 2: args[2] else: "default"
      req = "eval\t" & lang & "\t" & sess & "\n" & stdin.readAll()
    of "set-buffer":
      req = "set-buffer\n" & stdin.readAll()
    of "insert":                           # insert <line> (text on stdin)
      if args.len < 2: quit("wkbctl insert <line>   (text on stdin)", 1)
      req = "insert\t" & args[1] & "\n" & stdin.readAll()
    of "replace":                          # replace <from> <to> (text on stdin)
      if args.len < 3: quit("wkbctl replace <from> <to>   (text on stdin)", 1)
      req = "replace\t" & args[1] & "\t" & args[2] & "\n" & stdin.readAll()
    of "goto":
      if args.len < 2: quit("wkbctl goto <line>", 1)
      req = "goto\t" & args[1]
    of "diff":                             # diff <oldfile> <newfile> [title]
      if args.len < 3: quit("wkbctl diff <oldfile> <newfile> [title]", 1)
      let title = if args.len > 3: args[3] else: extractFilename(args[2])
      req = "diff\t" & title & "\n" & readFile(args[1]) & "\x1e" & readFile(args[2])
    else:
      quit("unknown verb: " & args[0], 1)

    let path = getCacheDir() / "wkbenchless" / "control.sock"
    var s = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
    try:
      s.connectUnix(path)
    except OSError:
      quit("wkbenchless is not running (no control socket at " & path & ")", 1)
    s.send(req)
    discard shutdown(s.getFd, SHUT_WR)     # half-close so the server sees EOF
    var resp = ""
    while true:
      let chunk = s.recv(4096)
      if chunk.len == 0: break
      resp.add chunk
    s.close()
    stdout.write(resp)
    if resp.len > 0 and resp[^1] != '\n': stdout.write("\n")

  main()

else:
  echo "wkbctl is not supported on Windows yet (the control socket is POSIX AF_UNIX)"
  quit(1)
