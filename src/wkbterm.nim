## Thin wrapper around uirelays' Terminal widget. It re-exports only the terminal
## symbols we use -- NOT its `synedit` (the package's), which would clash with our
## vendored synedit (both define SynEdit/createSynEdit).
import widgets/terminal
export Terminal, createTerminal, runCommand, update, draw, TermAction, insertPrompt
