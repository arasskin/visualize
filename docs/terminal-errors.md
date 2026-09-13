Terminal diagnostics are saved to `.logs/terminal-errors.jsonl` in the visualize checkout. The server creates the file at startup. Set `VISUALIZE_ERROR_LOG_DIR` to choose another directory. Logs are outside the static web roots and ignored by git.

```sh
tail -f .logs/terminal-errors.jsonl
```

Each JSON line includes a server timestamp and the reported browser time, error message and stack, phase, pane ID, label, and terminal dimensions when available. The browser reports screen initialization, screen application, rendering, resizing, supervisor errors, input failures, and failed resize delivery, plus uncaught exceptions and rejected promises. Terminal output and typed commands are not recorded. Session tokens in URLs are redacted before transmission.

The authenticated `/errors` endpoint limits report size and stores only the listed diagnostic fields. The log rotates at roughly 1 MiB, keeping one previous file, `terminal-errors.jsonl.1`. The browser suppresses identical pane/phase/message reports for five seconds and retains up to 32 queued reports in local storage. It retries delivery after an outage and reload; excessive errors can evict older queued reports. Disk failures leave reports queued for retry.

Native emulator and supervisor request failures are logged by each supervisor. Browser reports cover screen application, rendering, input, and resize delivery. The libvterm screen adapter renders OSC 8 labels as plain text.

Checks:

```sh
node tools/terminal-error-checks.mjs
node tools/pane-resize-checks.mjs
```

The browser logging check verifies authentication, redaction, duplicate suppression, offline queuing, disk persistence, and acknowledgment. Private terminal captures remain outside the repository.

A pane with accumulated scrollback can need a reconnect snapshot larger than 1 MiB. The WebSocket output queue now waits for earlier output to drain and admits one oversized frame on an empty queue, rather than closing the connection and repeating the failure on every reconnect. The supervisor and its terminal process remain alive during this failure. After updating the server, Ctrl-D in its launching terminal reloads the code while preserving sessions.

`node tools/websocket-output-checks.mjs` tests three reconnects with a 3 MiB snapshot and queued follow-up messages on an isolated server. The websocket unit suite also covers draining an oversized snapshot before subsequent output.

Workers must receive the browser's current terminal theme before their process starts. Starting with libvterm's black background and applying the light browser theme later lets programs cache dark-theme colors during their initial OSC color queries. Visualize retains the latest browser-reported theme for new workers and passes it with the supervisor start request; before a browser reports a theme, the coordinator uses the default light foreground and background. A running application may retain its previously selected colors until it is restarted. Launcher checks cover startup queries with both light and dark worker themes.
