Terminal traffic uses one WebSocket per browser page. The server relays screen updates from per-terminal supervisors, which own the PTY and libvterm. Graph computation runs in the thread owned by `graph.janet`. Config and pane metadata writes run synchronously on the server event loop, independently of graph layout. See [backend ownership](backend.md).

Each WebSocket multiplexes pane requests and output subscriptions. HTTP and WebSocket terminal commands call the same operation function. Input is sent in order and acknowledged when accepted by the supervisor, without waiting for an echo.

Output uses explicit credit: each subscription has at most one unacknowledged screen update. The browser acknowledges the screen revision after applying it, then requests the next update. Screen rows are encoded by the supervisor; the relay forwards its serialized payload without decoding and re-encoding it. The supervisor feeds PTY bytes to libvterm, which preserves UTF-8 sequences split across reads. Session generations and subscription IDs prevent stale output from being applied to a replacement session or subscription. Raw-byte replay and the old polling API have been removed.

The browser and relay bound input queues. Requests whose delivery cannot be confirmed are rejected and never automatically replayed. Screen updates resume from the browser's last consumed revision on reconnect. The browser fetches the new server token before opening its replacement WebSocket. Terminal supervisors close inherited descriptors before exec so they cannot keep dead server sockets open. Session replacement detaches the old output channel before waiting for the new PTY.

The upgrade requires the same token and origin checks as HTTP write routes. Framing supports masked client messages, continuation frames, ping/pong, close frames, UTF-8 validation, and bounded message sizes.

Restart the server and reload the page to load server changes. Ctrl-D preserves existing terminal sessions; Ctrl-C terminates them. Existing libvterm supervisors continue serving screen updates, but supervisor-side changes require recreating their terminals. Already-running processes are not replaced automatically.

The following measurements describe the earlier streaming implementation, before removal of raw-output replay. They have not been rerun for the current changes.

The headless Chrome benchmarks measured approximately 33–35 ms p95 key-to-DOM latency under the previously failing workloads. The earlier full-buffer test reached 2.48 seconds of visible lag, graph edits reached about 350 ms, and five long-polling panes caused an 8.38-second input-completion stall. Browser frame scheduling still contributes roughly one frame; these measurements are not physical keyboard-to-display scanout timings.

[Recorded benchmark summaries](terminal-streaming-results.json) include the one-to-five-pane run, 3,000-file scan contention, and full-backlog burst. Graph-edit contention measured 33.4 ms p95 and 34.4 ms maximum key-to-DOM latency. Five panes measured 34.7 ms p95 and 35.0 ms maximum across 60 keystrokes; input acknowledgment peaked at 17.7 ms.

Current latency scenarios and protocol checks:

```sh
node tools/latency.mjs /tmp/stream-panes.json
LATENCY_CASE=scan node tools/latency.mjs /tmp/stream-scan.json
LATENCY_CASE=protocol node tools/latency.mjs /tmp/stream-checks.json
./src/test/run
```

The protocol case checks upgrade authorization, fragmented requests with an interleaved ping, close handling, recovery across a server restart, output replay without duplication, stale-generation input rejection, and split UTF-8 output. Test sessions, profiles, and source trees are isolated in temporary directories.

Tracing remains opt-in through `VISUALIZE_TRACE=1` on the server and `?trace=1` on the page. `window.__latency.snapshot()` contains browser timing samples. Authenticated `/diagnostics`, `/diagnostics/graph`, and `/pane/<id>/diagnostics` expose relay, graph-thread, and supervisor samples respectively. New streaming measurements use `input-rpc` for the acknowledgment round trip; HTTP resource timing entries no longer represent browser terminal input.
