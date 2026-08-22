## Control server: a loopback-TCP socket (127.0.0.1, ephemeral port) the editor
## polls (non-blocking, from the main loop -- NO thread) so external tools --
## `wkbctl`, `wkbenchless ctl <verb>`, or Claude in the terminal -- can drive the
## editor: run code in a live session, read the buffer, show a diff, run a command.
##
## Protocol (one request per connection; client half-closes after sending):
##   "buffer"                      -> the current buffer text
##   "eval\t<lang>\t<session>\n<code>" -> run <code> in that session, return output
##   "command\t<name>"             -> run a registered command
##   "diff\t<title>\n<OLD>\x1e<NEW>" -> open the side-by-side diff view
##   "blocks"                      -> list #+begin_src blocks
##
## Cross-platform via std/net (works on Windows too, unlike the old AF_UNIX
## transport). The chosen port + a random token are written to a user-private
## file (<cache>/wkbenchless/control.port -- "port\ntoken"); a client connects to
## 127.0.0.1:<port> and sends "token\n<request>". The token keeps another local
## user from port-scanning the socket (parity with the old unix-socket perms).

import std/[strutils, tables, net, nativesockets, os, random]
when defined(posix): import std/posix
import wkbcore

type ControlServer* = object
  listener*: Socket        ## nil when not started
  client*: Socket          ## the in-flight client, or nil
  inbuf*: string
  token*: string

proc handle(app: var App; req: string): string =
  let nl = req.find('\n')
  let header = (if nl >= 0: req[0 ..< nl] else: req).strip()
  let body = if nl >= 0: req[nl + 1 .. ^1] else: ""
  let parts = header.split('\t')
  case parts[0]
  of "buffer":
    result = app.ed.fullText()
  of "eval":
    let lang = if parts.len > 1 and parts[1].len > 0: parts[1] else: "r"
    let sess = if parts.len > 2 and parts[2].len > 0: parts[2] else: "default"
    let code = if body.len > 0: body elif parts.len > 3: parts[3] else: ""
    if strutils.strip(code).len == 0: return "(no code)"
    let s = getSession(app, lang, sess)
    if s == nil: return "(no session for '" & lang & "')"
    result = s.runBlock(code)
  of "command":
    if parts.len > 1 and gCommands.hasKey(parts[1]):
      app.msg = ""
      gCommands[parts[1]].run(app)
      # Echo the resulting status line so scripts/agents can read outcome/state.
      result = "ok: " & parts[1] & (if app.msg.len > 0: " -- " & app.msg else: "")
    else: result = "unknown command"
  of "diff":                             # show a side-by-side diff: body = OLD \x1e NEW
    let title = if parts.len > 1: parts[1] else: "diff"
    let sep = body.find('\x1e')
    if sep < 0: return "diff: body must be OLD\\x1eNEW"
    showDiff(app, body[0 ..< sep], body[sep + 1 .. ^1], title)
    result = "ok: diff (" & title & ")"
  of "set-buffer":                       # replace the whole buffer with <body>
    app.ed.setText(body)
    app.ed.markChanged()
    result = "ok: buffer set (" & $app.ed.getLineCount() & " lines)"
  of "insert", "replace":
    # insert\t<line>\n<text>            -- insert <text> before 1-based <line>
    # replace\t<from>\t<to>\n<text>     -- replace 1-based lines [from..to] with <text>
    let total = app.ed.getLineCount()
    var newBody = body.split('\n')
    if newBody.len > 0 and newBody[^1] == "": newBody.setLen(newBody.len - 1)
    let frm = (if parts.len > 1: (try: parseInt(parts[1]) except: 1) else: 1) - 1
    let a = clamp(frm, 0, total)
    let b = if parts[0] == "replace":
              clamp((if parts.len > 2: (try: parseInt(parts[2]) except: a) else: a), a, total)
            else: a                       # insert removes nothing
    var lines: seq[string]
    for i in 0 ..< total: lines.add app.ed.getLineText(i)
    let res = lines[0 ..< a] & newBody & lines[b ..< total]
    app.ed.setText(res.join("\n"))
    app.ed.markChanged()
    result = "ok: " & parts[0] & " at " & $(a + 1) &
             (if parts[0] == "replace": ".." & $b else: "")
  of "goto":                             # move the cursor to 1-based <line>
    let ln = (if parts.len > 1: (try: parseInt(parts[1]) except: 1) else: 1) - 1
    # `ln` is a 0-based index; gotoLine is 1-based, so pass +1.
    app.ed.gotoLine(clamp(ln, 0, app.ed.getLineCount() - 1) + 1, 0)
    result = "ok: goto " & $(ln + 1)
  of "run-block":                        # run the src block at/containing 1-based <line>
    # Position + run in ONE request (so the cursor is right when babel runs), the
    # editor's own C-c C-c: executes in the block's :session and writes #+RESULTS.
    var ln = (if parts.len > 1: (try: parseInt(parts[1]) except: 1) else:
                app.ed.currentLine + 1) - 1
    ln = clamp(ln, 0, app.ed.getLineCount() - 1)
    # `blocks` reports the #+begin_src header line; babel wants a body line.
    if strutils.strip(app.ed.getLineText(ln)).toLowerAscii.startsWith("#+begin_src"):
      ln = min(ln + 1, app.ed.getLineCount() - 1)
    app.ed.gotoLine(ln + 1, 0)           # `ln` is 0-based; gotoLine is 1-based
    babelExecute(app)
    result = "ok: " & app.msg
  of "blocks":
    let total = app.ed.getLineCount()
    var i = 0
    while i < total:
      let ln = strutils.strip(app.ed.getLineText(i))
      if ln.toLowerAscii.startsWith("#+begin_src"):
        result.add $(i + 1) & ": " & ln & "\n"
      inc i
    if result.len == 0: result = "(no src blocks)"
  else:
    result = "unknown verb: " & parts[0]

proc portPath*(): string = getCacheDir() / "wkbenchless" / "control.port"

proc genToken(): string =
  var r = initRand()
  const hex = "0123456789abcdef"
  for _ in 0 ..< 32: result.add hex[r.rand(15)]

proc startControl*(): ControlServer =
  ## Bind a loopback listener on an ephemeral port; record port+token so clients
  ## can find and authenticate to it. On failure the listener stays nil and
  ## `poll` is a no-op.
  try:
    let s = newSocket()
    s.setSockOpt(OptReuseAddr, true)
    s.bindAddr(Port(0), "127.0.0.1")
    s.listen()
    let (_, port) = s.getLocalAddr()
    s.getFd.setBlocking(false)
    when defined(posix):
      discard fcntl(s.getFd.cint, F_SETFD, FD_CLOEXEC)   # don't leak into forked sessions
    result.listener = s
    result.token = genToken()
    try: createDir(portPath().parentDir) except CatchableError: discard
    writeFile(portPath(), $port.int & "\n" & result.token & "\n")
    when defined(posix):
      try: setFilePermissions(portPath(), {fpUserRead, fpUserWrite})
      except CatchableError: discard
  except CatchableError:
    result = ControlServer()

proc poll*(cs: var ControlServer; app: var App) =
  if cs.listener == nil: return
  if cs.client == nil:                  # accept a pending connection (non-blocking)
    var lfds = @[cs.listener.getFd]
    if selectRead(lfds, 0) > 0:
      try:
        var c: Socket
        cs.listener.accept(c)
        c.getFd.setBlocking(false)
        when defined(posix):
          discard fcntl(c.getFd.cint, F_SETFD, FD_CLOEXEC)
        cs.client = c; cs.inbuf = ""
      except CatchableError: discard
  if cs.client != nil:
    var cfds = @[cs.client.getFd]
    while selectRead(cfds, 0) > 0:
      var chunk = ""
      try: chunk = cs.client.recv(4096)
      except CatchableError: chunk = ""
      if chunk.len == 0:                # client half-closed: request complete
        let nl = cs.inbuf.find('\n')    # first line is the auth token
        let tok = if nl >= 0: cs.inbuf[0 ..< nl] else: ""
        let body = if nl >= 0: cs.inbuf[nl + 1 .. ^1] else: ""
        let resp = if tok == cs.token: handle(app, body) else: "unauthorized"
        try: cs.client.send(resp) except CatchableError: discard
        try: cs.client.close() except CatchableError: discard
        cs.client = nil
        break
      cs.inbuf.add chunk
      cfds = @[cs.client.getFd]
