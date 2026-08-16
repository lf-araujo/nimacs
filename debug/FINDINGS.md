# Root cause: a Nim background thread triggers a phantom-Esc flood under labwc/XWayland

Reproduced by injecting keys with `xdotool` and logging every event:

| test                          | concurrency            | result                                   |
|-------------------------------|------------------------|------------------------------------------|
| diag2 (no thread)             | none                   | quiet, 0 Esc events                      |
| diag3 (fork child process)    | fork/exec              | quiet, 0 Esc events                      |
| diag  (import Terminal widget)| **Nim background thread** | **continuous phantom KeyEsc down/up flood** |

- The flood appears **only with a Nim thread** — not with a forked child.
- The app "hang" is the main loop drowning in phantom Esc events (which also
  close menus / trigger Esc actions). It is **not** an Xlib lock, so
  `XInitThreads()` doesn't help.
- Injected real keys (x/y/z) still got through even with the thread+flood in a
  *trivial* loop; a heavy per-frame loop (the real editor) can't keep up → freeze.

## Conclusion
The uirelays Terminal widget (which spawns a Nim thread at import) is unusable
here. The **in-pane terminal must be thread-free**: spawn on a PTY we own via
`fork`/`exec` and poll the master fd from the main loop (see
`test5_pty_nothread.nim`) — forked children do **not** cause the flood. This is
also the substrate for the claude-code-ide.

Likely mechanism: Nim's thread runtime alters process signal handling; the X11
driver blocks in `select()` on the X fd and gets interrupted / misreads events as
repeated Escape. (Exact internals unconfirmed; the isolation above is definitive.)
