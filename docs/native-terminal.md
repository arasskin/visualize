# Native terminal supervisors

Each persistent Janet supervisor owns one libvterm instance and its PTY. Its existing PTY reader thread supplies bytes to the supervisor event loop; the loop serializes parsing, resizing, query responses, and snapshots. The HTTP/WebSocket server relays serialized messages. WTerm remains the browser renderer and input encoder, using `src/web/terminal/screen-core.js` as a screen cache. The browser receives screen state and encodes user input; parsing and terminal query responses run in the supervisor.

The native library is pinned and built from `src.vterm`; no separate runtime, Zig compiler, or installed libvterm is needed. The two correctness patches and their provenance are listed in `src.vterm/README.md`.

## Synchronized output

DEC mode 2026 supports begin (`CSI ? 2026 h`), end (`CSI ? 2026 l`), and query (`CSI ? 2026 $ p`). Following Neovim's implementation, libvterm keeps parsing and accumulating damage while publication is held. The supervisor sends replies to terminal queries during the hold, avoiding applications waiting on queries that only a browser could answer. Ending an update releases the accumulated screen changes without a redraw debounce.

A one-second watchdog releases a held update and resets mode 2026 if the application fails to finish. Repeated begin sequences do not extend the hold indefinitely. Terminal reset and PTY EOF release it as well. Resizes still reach the emulator and PTY during a hold; the next published screen carries the authoritative dimensions.

## Screen protocol

The authenticated terminal WebSocket subscription receives a `screen` object rather than raw PTY output. Acknowledgement credits use `(generation, at)`, where `at` is now the screen revision. Screen snapshots contain protocol version 1, dimensions, cursor, input modes, title, changed visible rows, and scrollback changes. Rows contain base64-encoded little-endian cell records: six Unicode scalars, width, WTerm attribute flags, foreground, and background, all 32-bit words. Colors are palette indices 0–255, default 256, or `0x1000000 | RGB`. Trailing default blank cells are omitted.

Per-row revision stamps support independent readers without consuming another reader's damage. Revision zero requests a complete snapshot; a changed generation also forces one. Scrollback keys are absolute line positions with an eviction counter. The browser drops evicted lines and applies changed rows before scheduling WTerm's renderer. Desired browser dimensions do not resize the screen cache before the supervisor confirms them, preventing mismatched row reads.

The PTY reader queue holds at most 64 chunks (4 MiB), and each drain processes at most 256 KiB before returning control so sustained output cannot indefinitely monopolize the supervisor loop. History is capped at 2,000 lines and 8 MiB of native cell storage. The legacy raw `poll`/`since` diagnostic API remains available, separately bounded by its chunk limit and 8 MiB. The browser does not use that API for rendering.

Default/palette color queries and character/pixel geometry queries are answered in the supervisor. The browser supplies its theme and measured cell geometry; without a browser, geometry starts at 8×17 pixels. Complex emoji, Kitty keyboard/graphics protocols, OSC palette mutation, and OSC 8 link metadata remain deferred; OSC 8's visible text renders normally.

## Capture and migration

`POST /pane/<id>/capture?k=<token>` with body `{}` returns plain visible-screen text, dimensions, and generation. The same supervisor RPC is `{"op":"capture"}`, available through the Janet client as `(:capture client)`. Capture reads the emulator's current screen, including an in-progress synchronized update; it is independent of browser publication.

Supervisors created before this change cannot load the new engine in place. The UI reports that those panes need to be closed and recreated. Restart Visualize and reload the page, then recreate old panes when their running work can be stopped. A server restart alone deliberately preserves existing supervisors. Live user panes are not restarted during development or tests.

Caught emulator and supervisor request failures are written to `.logs/terminal-errors.jsonl` (or `VISUALIZE_ERROR_LOG_DIR`), and delivered errors retain the browser's existing error reporting. A native process crash remains isolated to its supervisor.

## Checks

- `external-src/janet/janet src/test/core.janet`: backend, native wrapper, synchronized publication, query responses without a browser, and session replacement.
- `node tools/screen-core-checks.mjs`: real native snapshots decoded by the browser cache, including wide continuation cells and combining accents.
- `node tools/pane-resize-checks.mjs`: isolated browser resize matrix and hyperlink-text regressions.
- `LATENCY_CASE=protocol node tools/latency.mjs /tmp/visualize-protocol.json`: stream/reconnect/server-restart checks; this runner also records typing timings.
- `external-src/janet/janet tools/libvterm-checks.janet src.vterm/libvisualize-vterm.so`: native checks; optional recording paths add replay cycles. Recordings are not committed.
- `external-src/janet/janet tools/libvterm-regressions.janet`: UTF-8 and cursor/reflow regressions against the bundled library.
