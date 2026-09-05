This is the investigation of the previous transport. The counter fix, graph-worker thread, and WebSocket transport have now been implemented; see [the current architecture and verification](terminal-streaming.md). Measurements below describe the earlier version.

Three reproducible causes explain the typing delays: a full-buffer progress bug, exhaustion of the browser's HTTP connection pool, and synchronous graph work on the terminal relay's event loop. Instrumentation is retained in the project; the behavioral counter fix was tested only in a temporary copy.

Measurements used isolated headless Chrome on this Mac, a real PTY running `/bin/cat`, and real browser key events. The final run used Chrome 152.0.7977.82 on macOS arm64. Bursts send 100–150 printable keys with 25 ms between dispatches. These stress rapid input; they do not represent average human typing speed. Key-to-DOM measures the echoed character appearing in the terminal DOM, not physical display scanout. It also excludes the operating system's physical keyboard delivery time. These experiments reproduce failure modes; they do not identify which was active in a particular past user session.

| Scenario | Median key-to-DOM | p95 | Maximum |
| --- | ---: | ---: | ---: |
| One pane, before filling buffer | 26.6 ms | 32.9 ms | 35.9 ms |
| Same pane, default 4,000-chunk buffer full | 1,307.3 ms | 2,390.5 ms | 2,484.8 ms |
| Full buffer with temporary counter fix | 26.7 ms | 34.2 ms | 34.8 ms |
| 3,000 files, idle | 26.8 ms | 34.4 ms | 60.3 ms |
| 3,000 files, edits every 350 ms | 29.7 ms | 279.3 ms | 353.0 ms |
| Same edit workload, server tracing disabled | 30.1 ms | 278.6 ms | 358.2 ms |

The paired buffer tests warmed the real default buffer to 4,100 output chunks. Earlier reduced-buffer experiments produced the same effect. The edit workload folds the generated directory into one graph node, limiting SVG/DOM complexity while exercising scanning and redraws.

The full-buffer bug is in `src/visualize/term/host.janet`, in the `input` branch of `handle`. It saves `length backlog` and waits for that length to change. At capacity, `drain` appends a chunk, removes the oldest chunk, and increments `base`. Length therefore stays constant even when new output has arrived. Each input acknowledgment waits for the 48 ms timeout; measured median echo-wait was 49.17 ms. The browser serializes input requests through `inputTurn`, so later keys accumulate behind these waits. The poll can display the first key promptly, but subsequent keys have not yet been sent. Using `base + length backlog` as the progress counter reduced median echo-wait to 0.04 ms and restored normal visible echo latency. This fixes the demonstrated capacity bug; intentional waiting for programs that produce no output remains a separate throughput constraint.

The connection-pool failure occurs with five open, polling panes. Five terminal long polls plus `/watch` occupy the six HTTP/1.1 connections available in the tested browser. In the measured run, the first input request waited 8,375.9 ms before it could start; server handling took 0.77 ms. Following keys accumulated in the browser's input queue. The delay depends on the remaining long-poll lifetimes, not PTY speed. Timing this request only inside Janet would miss nearly the entire stall. That run measured input completion rather than key-to-DOM.

The graph workload blocks the relay. During source edits, input requests waited hundreds of milliseconds while terminal-host handling remained under 1 ms. Retained scan-phase samples showed directory walks around 30 ms, `read-all` around 146–183 ms, graph construction around 103 ms, and layout around 51 ms. These are nested/overlapping phase durations, not independent numbers to add. `read-all` launches an OS thread for every file, with a concurrency limit; it does not use a persistent worker pool. File enumeration, thread launch/marshalling, graph construction, and some fingerprint work still run on the server's event loop. Existing cooperative fingerprinting yields only after `find-files` has already walked and sorted the tree. The near-identical tracing-disabled result rules out tracing as the primary source of these stalls.

The uncontended browser still introduces a frame-scale delay: terminal rendering itself typically took 0.4–0.5 ms, but scheduling a write for rendering took about 16.5 ms. Input network resource duration was usually about 1 ms, while the fetch continuation could run later. This is a separate baseline latency from the large stalls; headless scheduling is not an exact prediction of a foreground terminal window.

| Option | What it addresses | Scope and tradeoff |
| --- | --- | --- |
| Fix the progress counter | Full-buffer 48 ms waits and resulting input backlog | Small, demonstrated fix; does not solve graph contention or connection exhaustion. |
| Keep HTTP, reduce contention | Mitigate long-poll saturation and relay stalls | Multiplex polls, reserve a separate input origin, or shorten holds; add cooperative yields and reuse scan workers. More requests or scheduling complexity, with weaker isolation. |
| Stream terminal traffic over WebSocket | Per-pane HTTP connection exhaustion and request-by-request input acknowledgment | One bidirectional connection can multiplex panes and acknowledge accepted input independently of output. Requires backpressure, ordered writes, reconnection, and replay/generation handling. A WebSocket handled on the same busy event loop still suffers graph stalls. |
| Isolate graph work | Source-edit stalls in terminal traffic | Move scan/config/render jobs into a persistent worker or process; cache results and publish generations. Requires explicit job ownership, stale-result handling, and cancellation/coalescing. |
| Dedicated terminal relay plus streaming | Both transport contention and graph interference | Strongest separation, larger change: terminal I/O runs independently of graph computation and streams to the browser. Retain existing PTY supervisors and recovery semantics. |

Recommended sequence: land the counter fix first, then isolate graph work and replace per-pane long polls with a multiplexed terminal stream. A dedicated relay is appropriate if terminal responsiveness must remain independent of future app workloads. Optimize frame scheduling after the larger stalls are gone. The counter A/B result demonstrates a small fix is worthwhile; it does not make the architectural contention disappear.

Instrumentation is off by default. Start a server with:

```sh
VISUALIZE_TRACE=1 ./visualize /path/to/project
```

Open its page with `?trace=1` and start a new terminal pane so its supervisor also has tracing enabled. Existing supervisors survive server restarts and keep their original environment.

Browser console collection:

```js
window.__latency.snapshot()
window.__latency.clear()
await fetch('/diagnostics?k=' + window.TOKEN).then(r => r.json())
await fetch('/pane/harness/diagnostics?k=' + window.TOKEN, {
  method: 'POST', body: '{}'
}).then(r => r.json())
```

The browser ring holds 4,096 samples; each process ring holds 2,048. Records contain durations, stage names, pane/input IDs, and sizes of timing windows, not typed text or terminal output. Server-Timing records handler and supervisor-client stages. Browser resource timings distinguish pre-request waiting from response waiting. Additional spans cover key dispatch, application input queueing, JSON consumption, emulator writes, scheduled render completion, PTY send/echo waits, supervisor encoding/writes, scan phases, and event-loop lateness. The trace-only render hook uses WTerm's private `_doRender` method and needs rechecking when that dependency changes. Samples from different clocks should not be subtracted directly.

Reproduce the tests without installing JavaScript packages:

```sh
node tools/latency.mjs /tmp/visualize-latency.json
LATENCY_CASE=default-backlog node tools/latency.mjs /tmp/backlog.json
LATENCY_CASE=default-backlog LATENCY_VARIANT=backlog-counter node tools/latency.mjs /tmp/counter.json
LATENCY_CASE=scan node tools/latency.mjs /tmp/scan.json
VISUALIZE_TRACE=0 LATENCY_CASE=scan node tools/latency.mjs /tmp/scan-untraced.json
```

The runner uses an isolated Chrome profile, temporary project, and temporary terminal sessions, then shuts them down. `CHROME` can override the default macOS Chrome executable. The counter variant copies the source into the temporary workspace and changes only that copy. It does not patch the working project.

[Recorded summaries and slow-request timings](terminal-latency-results.json) include paths to the raw JSON captures from this investigation. Timings vary between runs; the causal distinctions and A/B differences are more important than individual sub-millisecond values.
