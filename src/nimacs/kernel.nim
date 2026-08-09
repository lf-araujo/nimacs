## The one type shared across the host<->config.nim boundary. Its source
## must stay textually identical everywhere it's compiled (host and every
## config.nim build) — that's what keeps its field layout ABI-compatible
## across independently-compiled units. See DESIGN.md.

type
  EditorKernel* = object
    text*: string
    cursorPos*: int
    status*: string
