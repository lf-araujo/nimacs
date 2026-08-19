## org-tracked -- Word .docx <-> org round-trip with tracked changes as
## CriticMarkup, via pandoc. A wkbenchless port of org-tracked-docx.
##
## Needs `pandoc` on PATH. Link a buffer to its Word doc with a header line:
##   #+OTD_DOCX: /path/to/manuscript.docx
## Then:
##   M-x otd-import  -- docx -> this buffer, tracked changes/comments as CriticMarkup
##   M-x otd-export  -- this buffer's CriticMarkup -> tracked changes in the docx
##
## CriticMarkup handled: {++ins++} {--del--} {~~old~>new~~} {>>[Author] note<<}
## {==highlight==}. Insertions/deletions/substitutions round-trip as real Word
## revisions; comments are emitted best-effort as Word comments.

import wkbcore
import std/[osproc, os, strutils, times]

var
  gPandoc* = "pandoc"
  gAuthor* = ""     ## blank -> git user.name, else "wkbenchless"

proc trackAuthor(): string =
  if gAuthor.len > 0: return gAuthor
  let (o, c) = execCmdEx("git config user.name")
  result = (if c == 0: o.strip() else: "")
  if result.len == 0: result = "wkbenchless"

proc nowDate(): string = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc pandoc(args: seq[string]): tuple[code: int; output: string] =
  let exe = findExe(gPandoc)
  if exe.len == 0: return (127, "pandoc not on PATH")
  var cmd = quoteShell(exe)
  for a in args: cmd.add " " & quoteShell(a)
  let r = execCmdEx(cmd)
  (r.exitCode, r.output)

# ---- CriticMarkup <-> pandoc span conversion -------------------------------

proc criticToSpans(md: string): string =
  ## CriticMarkup tokens -> pandoc markdown spans (for md -> docx). Uses the same
  ## split scanner style as wkbcore.applyCriticMarkup.
  let a = trackAuthor()
  let d = nowDate()
  let ins = " author=\"" & a & "\" date=\"" & d & "\""
  result = newStringOfCap(md.len)
  var i = 0
  var cid = 0
  proc closeOf(o, c: char): int =
    var q = i + 3
    while q + 2 < md.len:
      if md[q] == c and md[q+1] == c and md[q+2] == '}': return q + 2
      inc q
    -1
  while i < md.len:
    if i + 4 < md.len and md[i] == '{':
      let x = md[i+1]; let y = md[i+2]
      if x == y and x in {'+', '-', '=', '~'}:
        let e = closeOf(x, x)
        if e >= 0:
          let inner = md[i+3 ..< e-2]
          case x
          of '+': result.add "[" & inner & "]{.insertion" & ins & "}"
          of '-': result.add "[" & inner & "]{.deletion" & ins & "}"
          of '=': result.add inner                        # highlight: keep the text
          of '~':
            let arrow = inner.find("~>")
            if arrow >= 0:
              result.add "[" & inner[0 ..< arrow] & "]{.deletion" & ins & "}"
              result.add "[" & inner[arrow+2 .. ^1] & "]{.insertion" & ins & "}"
            else:
              result.add "[" & inner & "]{.insertion" & ins & "}"
          else: discard
          i = e + 1; continue
      elif x == '>' and y == '>':                         # {>>[A] note<<}
        var q = i + 3
        var e = -1
        while q + 2 < md.len:
          if md[q] == '<' and md[q+1] == '<' and md[q+2] == '}': e = q + 2; break
          inc q
        if e >= 0:
          var note = md[i+3 ..< e-2].strip()
          var cauth = a
          if note.startsWith("[") and ']' in note:        # [Author] prefix
            let rb = note.find(']')
            cauth = note[1 ..< rb]
            note = note[rb+1 .. ^1].strip()
          result.add "[" & note & "]{.comment-start id=\"" & $cid & "\" author=\"" &
                     cauth & "\" date=\"" & d & "\"}[]{.comment-end id=\"" & $cid & "\"}"
          inc cid
          i = e + 1; continue
    result.add md[i]; inc i

proc spansToCritic(md: string): string =
  ## pandoc markdown track-change spans -> CriticMarkup (for docx -> md).
  ## Balanced-bracket scan so inserted/deleted text may itself contain `]`.
  result = newStringOfCap(md.len)
  var i = 0
  while i < md.len:
    # a closing `]{.class ...}` -> find the matching `[`, wrap in CriticMarkup
    if md[i] == ']' and i + 2 < md.len and md[i+1] == '{' and md[i+2] == '.':
      let braceEnd = md.find('}', i)
      if braceEnd > 0:
        let attrs = md[i+3 ..< braceEnd]      # skip `]{.`
        let cls = attrs.split({' ', '\t'})[0]
        # find matching open bracket
        var depth = 1; var p = i - 1
        while p >= 0 and depth > 0:
          if md[p] == ']': inc depth
          elif md[p] == '[': dec depth
          if depth == 0: break
          dec p
        if p >= 0 and depth == 0:
          let inner = md[p+1 ..< i]
          var wrapped = ""
          case cls
          of "insertion": wrapped = "{++" & inner & "++}"
          of "deletion": wrapped = "{--" & inner & "--}"
          of "mark": wrapped = "{==" & inner & "==}"
          of "comment-start":
            var auth = ""
            let ai = attrs.find("author=\"")
            if ai >= 0:
              let s = ai + 8; let en = attrs.find('"', s)
              if en > s: auth = attrs[s ..< en]
            wrapped = "{>>[" & auth & "] " & inner & "<<}"
          else: wrapped = ""    # unknown class: drop the span, keep the text
          # replace result[p+1..] : rebuild -- we appended md up to p already?
          # (handled below by rewriting; see note)
          if wrapped.len > 0 or cls notin ["insertion","deletion","mark","comment-start"]:
            # trim what we already emitted back to the open bracket, then wrap
            result.setLen(result.len - (i - (p + 1)) - 1)   # drop inner + '['
            if wrapped.len > 0: result.add wrapped
            else: result.add inner
            i = braceEnd + 1
            continue
    result.add md[i]; inc i

proc stash(s: string; tokens: var seq[string]): string =
  ## Replace CriticMarkup tokens with opaque sentinels so a pandoc org<->md pass
  ## can't mangle them (=verbatim=, ~~, etc.). Restored with `unstash`.
  result = newStringOfCap(s.len)
  var i = 0
  proc take(closeSeq: string): int =
    let e = s.find(closeSeq, i + 3)
    if e < 0: -1 else: e + closeSeq.len
  while i < s.len:
    var e = -1
    if i + 4 < s.len and s[i] == '{':
      case s[i+1]
      of '+': (if s[i+2] == '+': e = take("++}"))
      of '-': (if s[i+2] == '-': e = take("--}"))
      of '=': (if s[i+2] == '=': e = take("==}"))
      of '~': (if s[i+2] == '~': e = take("~~}"))
      of '>': (if s[i+2] == '>': e = take("<<}"))
      else: discard
    if e > 0:
      tokens.add s[i ..< e]
      result.add "zZoTdZz" & $(tokens.len - 1) & "zZ"
      i = e
    else:
      result.add s[i]; inc i

proc unstash(s: string; tokens: seq[string]): string =
  result = s
  for idx, tok in tokens:
    result = result.replace("zZoTdZz" & $idx & "zZ", tok)

# ---- commands --------------------------------------------------------------

proc docxOf(app: App): string =
  ## The docx path from a #+OTD_DOCX: header, or a sibling <file>.docx of the
  ## open .org, or "" if neither is available.
  for i in 0 ..< app.ed.getLineCount():
    let ln = strutils.strip(app.ed.getLineText(i))
    if ln.toLowerAscii.startsWith("#+otd_docx:"):
      return expandTilde(strutils.strip(ln[ln.find(':') + 1 .. ^1]))
  if app.filePath.len > 0: return app.filePath.changeFileExt("docx")
  ""

proc otdImport(app: var App) =
  let docx = docxOf(app)
  if docx.len == 0: (app.msg = "add a  #+OTD_DOCX: /path.docx  line first"; return)
  if not fileExists(docx): (app.msg = "not found: " & docx; return)
  let md = getTempDir() / "otd-import.md"
  var (code, outp) = pandoc(@["-f", "docx", "-t", "markdown", "--wrap=none",
                              "--track-changes=all", docx, "-o", md])
  if code != 0: (app.msg = "pandoc docx->md failed: " & outp.strip(); return)
  var toks: seq[string]
  let stashed = stash(spansToCritic(readFile(md)), toks)
  writeFile(md, stashed)
  let orgOut = getTempDir() / "otd-import.org"
  (code, outp) = pandoc(@["-f", "markdown", "-t", "org", "--wrap=none", md, "-o", orgOut])
  if code != 0: (app.msg = "pandoc md->org failed: " & outp.strip(); return)
  let org = unstash(readFile(orgOut), toks)
  app.ed.setText("#+OTD_DOCX: " & docx & "\n\n" & org.strip())
  app.ed.markChanged()
  app.msg = "otd: imported " & extractFilename(docx) & " (tracked changes as CriticMarkup)"

proc otdExport(app: var App) =
  let docx = docxOf(app)
  if docx.len == 0:
    app.msg = "otd: save the .org first, or add a  #+OTD_DOCX: /path.docx  line"; return
  if findExe(gPandoc).len == 0: (app.msg = "otd: pandoc not on PATH"; return)
  # strip the OTD header line from the org we feed pandoc
  var lines: seq[string]
  for i in 0 ..< app.ed.getLineCount():
    let ln = app.ed.getLineText(i)
    if not strutils.strip(ln).toLowerAscii.startsWith("#+otd_docx:"): lines.add ln
  var toks: seq[string]
  let orgStashed = stash(lines.join("\n"), toks)
  let orgTmp = getTempDir() / "otd-export.org"
  writeFile(orgTmp, orgStashed)
  let md = getTempDir() / "otd-export.md"
  var (code, outp) = pandoc(@["-f", "org", "-t", "markdown", "--wrap=none", orgTmp, "-o", md])
  if code != 0: (app.msg = "pandoc org->md failed: " & outp.strip(); return)
  writeFile(md, criticToSpans(unstash(readFile(md), toks)))
  (code, outp) = pandoc(@["-f", "markdown", "-t", "docx", md, "-o", docx])
  if code != 0: (app.msg = "pandoc md->docx failed: " & outp.strip(); return)
  app.msg = "otd: exported tracked changes -> " & extractFilename(docx)

proc extend*(app: var App) =
  defcommand("otd-import", "Tracked: import .docx -> org (CriticMarkup)", otdImport)
  defcommand("otd-export", "Tracked: export org (CriticMarkup) -> .docx", otdExport)
