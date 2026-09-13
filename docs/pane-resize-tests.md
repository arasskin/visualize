Run the pane interaction suite on macOS with Node 22 or later, the native libraries and Janet executable from `./build`, and Chrome installed:

```sh
node tools/pane-resize-checks.mjs
```

Set `CHROME` to override the Chrome executable. An optional positional argument sets the artifact directory, which defaults to `/tmp/visualize-pane-resize`. The runner creates an isolated project, server, browser profile, and PTY sessions. It does not attach to existing terminals. All output comes from `tools/fixtures/pane-terminal.janet`, run with the repository's bundled Janet executable.

The default run includes the interaction matrix and a separate browser run for hyperlink stress. Any failure exits nonzero; hyperlink stress remains part of the default run. For a focused run:

```sh
PANE_RESIZE_CASE=matrix node tools/pane-resize-checks.mjs
PANE_RESIZE_CASE=hyperlinks node tools/pane-resize-checks.mjs /tmp/visualize-hyperlinks
```

The matrix covers normal and alternate terminal screens on top and bottom rails and floating panes; growing, shrinking, width-only and height-only drags; rapid drags and slow drags that trigger intermediate PTY resizes; minimum dimensions and floor snapping; collapsed width resizing, quick toggles, and collapse during a pending resize; viewport changes and device pixel ratios 1 and 2; collapsed bottom panes during viewport resizing; output during resizing; paused output, fully frozen output, and synchronized output; scrollback anchoring; independent sibling panes; failed resize delivery; replacement terminal generations; Visualize pane resizing in all three positions; and native keyboard input after the interactions.

Settled terminal checks compare visible cell capacity, emulator dimensions, PTY dimensions, rendered row counts, application-reported dimensions, and the bottom marker's actual position. They also reject missing or duplicate terminal DOM, tab errors, browser exceptions, and console errors. Static-output checks allow rows to move into scrollback on shrink but require retained visible content. The suite waits for the current dimensions rather than accepting stale pre-debounce output.

Each run saves `report.json` and `final.png` on success. Failures save `failure.json` with completed checks, browser stacks, geometry and content snapshots, and server logs, plus `failure.png` when the renderer still responds. The default run saves the isolated hyperlink case under `hyperlinks/`. CDP requests have timeouts so a stuck browser does not hang the test runner indefinitely. These are correctness tests, not latency benchmarks. They exercise Chrome on macOS; Firefox and other platforms are not covered.

The suite exposed three application issues addressed alongside it: pane sizing measured a generic text span instead of the renderer's actual cells; layout-generated scroll events and a stale pending scroll position could stop following live output; and failed PTY resize requests were silently discarded after the local emulator had already resized. Pane sizing now uses WTerm's cell metrics and the screen's available dimensions, preserves the prior follow state during resizing, retries failed remote size updates, and invalidates the remembered remote size for a replacement terminal generation.

The hyperlink regression sends OSC 8 sequences, colors, Unicode, and repeated redraws through the native supervisor while resizing. It verifies that visible text remains intact and that unsupported hyperlink metadata renders as plain text. See `terminal-errors.md` for persistent diagnostics.
