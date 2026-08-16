# Terminal hang investigation

Each program opens a tiny window: type, and typed chars should appear. Esc quits.
Run each **interactively** and note whether keyboard input WORKS or HANGS.

    cd debug
    nim c -r test1_baseline.nim        # or ./test1_baseline after building

- **test1_baseline**  — plain uirelays loop, NO thread. (expected: works)
- **test2_thread**    — + one trivial background thread that just sleeps.
- **test3_xinit_thread** — + XInitThreads() before the window + trivial thread.
- **test4_terminal_import** — imports the uirelays Terminal widget (which starts
  its own background thread at load); the widget is otherwise unused.

## What each result means
- test1 works, test2 HANGS  -> ANY Nim background thread wedges input here
  (uirelays X11 driver vs threads under XWayland) -- not terminal-specific.
- test2 hangs, test3 WORKS  -> XInitThreads fixes it *when called correctly*
  (before the window). The real app called it too late / order issue.
- test2 works, test4 HANGS  -> something specific to the terminal widget's
  thread (what it does at startup), not threads in general.
- all work                  -> the hang needs the app's fuller context; we bisect
  from the real integration next.

- **test5_pty_nothread** — a THREAD-FREE PTY terminal: spawns bash on a
  pseudo-terminal we own and polls the fd from the main loop (no Nim thread).
  Type commands, Enter runs them. If keyboard works AND bash output appears here
  with no hang, this is the path for the real in-pane terminal (and the
  claude-code-ide) -- it avoids the thread entirely.
