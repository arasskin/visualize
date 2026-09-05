Terminal traffic now uses one WebSocket per browser page. Scanning, graph construction, layout, and config-file writes run on one persistent graph-worker thread inside the server process. There is no separate graph-worker process. Existing PTY supervisor processes still own the terminal sessions.

The graph thread owns its scan cache, rendered results, watcher, and config metadata. Requests and replies cross bounded thread channels; terminal I/O stays on the server event loop. Config edits, pane labels, and recovery notes are serialized by that thread so they cannot overwrite each other. Draw replies identify their source generation. Changes detected during a draw produce a newer generation, which the browser requests next. Identical draw requests reuse the cached result. In this vendored runtime, selecting across thread channels can deadlock, so result and worker-exit channels have separate readers.

Each WebSocket multiplexes pane requests and output subscriptions. Input is sent in order and acknowledged when accepted by the supervisor, independently of output. It no longer waits for echo. The legacy HTTP input endpoint also uses the corrected monotonic output counter, so a full backlog cannot force its 48 ms timeout.

Output uses explicit credit: each subscription has at most one unacknowledged batch. The browser advances its chunk position after consuming the batch, then requests the next one. Batches target 64 KiB and preserve complete PTY chunks. Bytes are base64-encoded in the supervisor's JSON envelope and passed to the emulator as byte arrays, preserving UTF-8 sequences split across reads. The relay forwards the supervisor's serialized payload without decoding and re-encoding terminal text. Session generations and subscription IDs prevent stale output from being applied to a replacement session or subscription.

The browser and relay bound input queues; a disconnected or overloaded connection produces an explicit input error. Requests whose delivery cannot be confirmed are rejected and never automatically replayed. Output resumes from the browser's last consumed position on reconnect. The browser fetches the new server token before opening its replacement WebSocket. Terminal supervisors close inherited descriptors before exec so they cannot keep dead server sockets open. Session replacement also detaches the old output channel before waiting for the new PTY, preventing the old session's EOF from stopping a new subscription.

The upgrade requires the same token and origin checks as the HTTP write routes. Framing supports masked client messages, continuation frames, ping/pong, close frames, UTF-8 validation, and bounded message sizes, following the [WebSocket protocol](https://www.rfc-editor.org/rfc/rfc6455.html). No new runtime package dependency was added. Browser-side HTTP terminal routes remain available for tools and older pages; a page reload activates streaming.

To use the change, restart the server and reload the page. Ctrl-D preserves existing terminal sessions; Ctrl-C terminates them. Existing supervisors can serve the new relay using their older protocol, but a newly created terminal supervisor is needed to pick up supervisor-side fixes and byte encoding. Already-running processes are not replaced automatically.

The headless Chrome benchmarks measured approximately 33–35 ms p95 key-to-DOM latency under the previously failing workloads. The earlier full-buffer test reached 2.48 seconds of visible lag, graph edits reached about 350 ms, and five long-polling panes caused an 8.38-second input-completion stall. Browser frame scheduling still contributes roughly one frame; these measurements are not physical keyboard-to-display scanout timings.

[Recorded benchmark summaries](terminal-streaming-results.json) include the one-to-five-pane run, 3,000-file scan contention, and full-backlog burst. Graph-edit contention measured 33.4 ms p95 and 34.4 ms maximum key-to-DOM latency. Five panes measured 34.7 ms p95 and 35.0 ms maximum across 60 keystrokes; input acknowledgment peaked at 17.7 ms.

Reproduce the measurements and integration checks:

```sh
node tools/latency.mjs /tmp/stream-panes.json
LATENCY_CASE=scan node tools/latency.mjs /tmp/stream-scan.json
LATENCY_CASE=default-backlog node tools/latency.mjs /tmp/stream-backlog.json
LATENCY_CASE=protocol node tools/latency.mjs /tmp/stream-checks.json
./src/test/run
```

The protocol case checks upgrade authorization, fragmented requests with an interleaved ping, close handling, recovery across a server restart, output replay without duplication, stale-generation input rejection, and split UTF-8 output. Test sessions, profiles, and source trees are isolated in temporary directories.

Tracing remains opt-in through `VISUALIZE_TRACE=1` on the server and `?trace=1` on the page. `window.__latency.snapshot()` contains browser timing samples. Authenticated `/diagnostics`, `/diagnostics/graph`, and `/pane/<id>/diagnostics` expose relay, graph-thread, and supervisor samples respectively. New streaming measurements use `input-rpc` for the acknowledgment round trip; HTTP resource timing entries no longer represent browser terminal input.
