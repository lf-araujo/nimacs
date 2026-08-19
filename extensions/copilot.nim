## GitHub Copilot ghost completion -- a wkbenchless extension.
##
## Talks to the standalone `copilot-language-server` binary over JSON-RPC/LSP
## (NO npm/Node -- just the binary on PATH; get it from GitHub's
## copilot-language-server releases, or point gCopilotCmd at it). Reuses the
## editor's own LSP client (wkblsp, via wkbcore).
##
## Commands (M-x):
##   copilot-login    -- device-code sign in (shows a URL + code)
##   copilot-status   -- check auth status
##   copilot-suggest  -- ask for a suggestion at the cursor (M-\ ); shown in Help
##   copilot-accept   -- insert the last suggestion at the cursor
##   copilot-signout  -- sign out
##
## STATUS: login + request plumbing are wired; true inline "ghost text" (greyed,
## Tab-to-accept in place) needs a virtual-text hook in SynEdit -- next step.
## Protocol method names follow the Copilot agent; adjust if your server differs.

import wkbcore
import std/[json, strutils, os]

var
  gCopilotCmd* = "copilot-language-server --stdio"   ## edit if the binary is elsewhere
  cop: LspClient                                     ## the running server, or nil
  gSuggestion: string                                ## last suggestion text

proc pick(n: JsonNode; keys: varargs[string]): string =
  ## First present, non-empty string among `keys` in object `n`.
  if n == nil or n.kind != JObject: return ""
  for k in keys:
    let v = n{k}
    if v != nil and v.kind == JString and v.getStr.len > 0: return v.getStr
  ""

proc ensureCop(app: var App): bool =
  if cop != nil and cop.initialized: return true
  let root = uriOf(if app.filePath.len > 0: parentDir(app.filePath) else: getCurrentDir())
  cop = startLsp(gCopilotCmd, root, %*{
    "editorInfo": {"name": "wkbenchless", "version": "0.1"},
    "editorPluginInfo": {"name": "wkbenchless-copilot", "version": "0.1"}})
  if cop == nil or not cop.initialized:
    app.msg = "copilot: couldn't start '" & gCopilotCmd.splitWhitespace()[0] &
              "' (is the binary on PATH?)"
    return false
  true

proc copilotLogin(app: var App) =
  if not ensureCop(app): return
  let resp = cop.request("signIn", %*{})
  let r = if resp != nil: resp{"result"} else: nil
  let status = pick(r, "status")
  if status in ["AlreadySignedIn", "OK", "MaybeOk"]:
    app.msg = "copilot: already signed in" & (let u = pick(r, "user"); (if u.len > 0: " as " & u else: ""))
    return
  let code = pick(r, "userCode", "user_code")
  let url = pick(r, "verificationUri", "verificationUrl", "verification_uri")
  if code.len == 0 or url.len == 0:
    app.help.setText("Copilot sign-in -- unrecognised response:\n\n" &
                     (if resp != nil: resp.pretty else: "(no response)"))
    app.msg = "copilot: sign-in response not understood (see Help pane)"
    return
  app.help.setText("GitHub Copilot -- device sign in\n\n" &
    "  1. Open:       " & url & "\n" &
    "  2. Enter code: " & code & "\n\n" &
    "Authorise in the browser, then run  M-x copilot-status  to confirm.")
  app.msg = "copilot: open " & url & "  code " & code

proc copilotStatus(app: var App) =
  if cop == nil: (app.msg = "copilot: not started -- M-x copilot-login"; return)
  let resp = cop.request("checkStatus", %*{"options": {"localChecksOnly": false}})
  let r = if resp != nil: resp{"result"} else: nil
  let status = pick(r, "status")
  let user = pick(r, "user")
  app.msg = "copilot: " & (if status.len > 0: status else: "unknown") &
            (if user.len > 0: " (" & user & ")" else: "")

proc copilotSignout(app: var App) =
  if cop == nil: (app.msg = "copilot: not started"; return)
  discard cop.request("signOut", %*{})
  app.msg = "copilot: signed out"

proc suggestionOf(r: JsonNode): string =
  ## Pull the insert text out of an inlineCompletion / getCompletions result,
  ## tolerating the several shapes servers return.
  if r == nil: return ""
  let items = if r.kind == JArray: r
              elif r.kind == JObject and r{"items"} != nil: r{"items"}
              elif r.kind == JObject and r{"completions"} != nil: r{"completions"}
              else: newJArray()
  if items.kind == JArray and items.len > 0:
    let it = items[0]
    result = pick(it, "insertText", "text", "displayText")
    if result.len == 0:
      let ins = it{"insertText"}
      if ins != nil and ins.kind == JObject: result = pick(ins, "value")

proc copilotSuggest(app: var App) =
  if not ensureCop(app): return
  if app.filePath.len == 0: (app.msg = "copilot: save the file first"; return)
  let uri = uriOf(app.filePath)
  let lang = if app.docLang.len > 0: app.docLang else: "plaintext"
  cop.syncDoc(uri, lang, app.ed.fullText())
  let resp = cop.request("textDocument/inlineCompletion", %*{
    "textDocument": {"uri": uri},
    "position": {"line": app.ed.currentLine, "character": app.ed.currentCol},
    "context": {"triggerKind": 2}})       # 2 = Automatic
  let sug = suggestionOf(if resp != nil: resp{"result"} else: nil)
  if sug.len == 0: (app.msg = "copilot: no suggestion here"; return)
  gSuggestion = sug
  app.help.setText("Copilot suggestion  (M-x copilot-accept to insert):\n\n" & sug)
  app.msg = "copilot: suggestion ready (Help pane) -- copilot-accept inserts it"

proc copilotAccept(app: var App) =
  if gSuggestion.len == 0: (app.msg = "copilot: no pending suggestion"; return)
  app.ed.insertText(gSuggestion)
  app.ed.markChanged()
  app.msg = "copilot: inserted suggestion"
  gSuggestion = ""

proc extend*(app: var App) =
  # Let a COPILOT_LANGUAGE_SERVER / WKB_COPILOT_CMD env override the binary path.
  let envCmd = getEnv("WKB_COPILOT_CMD", getEnv("COPILOT_LANGUAGE_SERVER"))
  if envCmd.len > 0: gCopilotCmd = envCmd
  defcommand("copilot-login", "Copilot: sign in (device code)", copilotLogin)
  defcommand("copilot-status", "Copilot: check auth status", copilotStatus)
  defcommand("copilot-signout", "Copilot: sign out", copilotSignout)
  defcommand("copilot-suggest", "Copilot: suggest at cursor", copilotSuggest)
  defcommand("copilot-accept", "Copilot: insert the last suggestion", copilotAccept)
  bindkey("M-\\", "copilot-suggest")
