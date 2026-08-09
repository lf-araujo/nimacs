## A small, dependency-light LSP *client*: JSON-RPC (Content-Length framed) over
## a language server's stdio, using std/json. Requests block until their reply
## (notifications in between are skipped) -- fine for on-demand completion, the
## same synchronous model as the babel sessions. No chronos / heavy deps.

import std/[osproc, json, streams, os, strutils, tables, sets]

type
  LspClient* = ref object
    process: Process
    nextId: int
    initialized*: bool
    opened: HashSet[string]         ## uris we've sent didOpen for
    version: Table[string, int]     ## uri -> document version

proc send(c: LspClient; msg: JsonNode) =
  let body = $msg
  c.process.inputStream.write("Content-Length: " & $body.len & "\r\n\r\n" & body)
  c.process.inputStream.flush()

proc readMessage(c: LspClient): JsonNode =
  let s = c.process.outputStream
  var contentLength = -1
  while true:
    var line: string
    if not s.readLine(line): return nil     # server closed
    if line.len == 0: break                  # blank line ends the headers
    if line.toLowerAscii.startsWith("content-length:"):
      contentLength = parseInt(line.split(':')[1].strip())
  if contentLength <= 0: return nil
  try: parseJson(s.readStr(contentLength))
  except CatchableError: nil

proc awaitResponse(c: LspClient; id: int): JsonNode =
  ## Read until the reply with `id`; skip notifications/other-id messages.
  for _ in 0 ..< 1000:
    let m = c.readMessage()
    if m == nil: return nil
    if m.hasKey("id") and m["id"].kind == JInt and m["id"].getInt == id:
      return m
  nil

proc request(c: LspClient; meth: string; params: JsonNode): JsonNode =
  inc c.nextId
  let id = c.nextId
  c.send(%*{"jsonrpc": "2.0", "id": id, "method": meth, "params": params})
  c.awaitResponse(id)

proc notify(c: LspClient; meth: string; params: JsonNode) =
  c.send(%*{"jsonrpc": "2.0", "method": meth, "params": params})

proc uriOf*(path: string): string = "file://" & path

proc startLsp*(command, rootUri: string): LspClient =
  ## Spawn `command` (space-split argv) and run the initialize handshake.
  ## Returns nil if the server isn't found or the handshake fails.
  let parts = command.splitWhitespace()
  if parts.len == 0: return nil
  let exe = findExe(parts[0])
  if exe.len == 0: return nil
  var p: Process
  try:
    p = startProcess(exe, args = parts[1 .. ^1], options = {poStdErrToStdOut})
  except OSError:
    return nil
  result = LspClient(process: p, nextId: 0, initialized: false,
                     opened: initHashSet[string](), version: initTable[string, int]())
  let resp = result.request("initialize", %*{
    "processId": getCurrentProcessId(),
    "rootUri": rootUri,
    "capabilities": {"textDocument": {
      "synchronization": {"didSave": true},
      "completion": {"completionItem": {"snippetSupport": false}}}}})
  if resp != nil and resp.hasKey("result"):
    result.notify("initialized", %*{})
    result.initialized = true
  else:
    try: p.terminate() except CatchableError: discard
    return nil

proc syncDoc*(c: LspClient; uri, langId, text: string) =
  ## didOpen the first time, didChange (full-text) after -- keeps the server's
  ## copy current before a request.
  if uri notin c.opened:
    c.opened.incl uri
    c.version[uri] = 1
    c.notify("textDocument/didOpen", %*{"textDocument":
      {"uri": uri, "languageId": langId, "version": 1, "text": text}})
  else:
    let v = c.version.getOrDefault(uri, 1) + 1
    c.version[uri] = v
    c.notify("textDocument/didChange", %*{
      "textDocument": {"uri": uri, "version": v},
      "contentChanges": [{"text": text}]})

proc completion*(c: LspClient; uri: string; line, character: int): seq[string] =
  ## Completion labels at a 0-based (line, character) position.
  let resp = c.request("textDocument/completion",
    %*{"textDocument": {"uri": uri}, "position": {"line": line, "character": character}})
  if resp == nil or not resp.hasKey("result"): return
  let r = resp["result"]
  let items = if r.kind == JArray: r
              elif r.kind == JObject: r{"items"}
              else: newJNull()
  if items != nil and items.kind == JArray:
    for it in items:
      let label = it{"label"}.getStr
      if label.len > 0: result.add label

proc shutdownLsp*(c: LspClient) =
  if c == nil or c.process == nil: return
  try:
    discard c.request("shutdown", newJNull())
    c.notify("exit", %*{})
  except CatchableError: discard
  try: c.process.terminate() except CatchableError: discard
  discard c.process.waitForExit()
