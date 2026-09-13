Rendering diagnostics are opt-in. Refresh the browser after installing the change, then run this in its developer console:

```js
__renderTrace.start()
```

Pan and zoom while reproducing the slowdown, then run:

```js
console.table(__renderTrace.stop())
JSON.stringify(__renderTrace.snapshot())
```

Alternatively, add `rendertrace=1` to the page's query parameters to capture startup too. Preserve any existing query parameters. The trace holds the newest 8,192 samples in memory and sends nothing to the server. Starting a capture clears previous samples. Stopping preserves them for inspection. No node names, file paths, or terminal contents are recorded.

The report groups durations in milliseconds with counts, total, median, p95, and maximum. Nested phases overlap, so their totals must not be added together.

- `input-dispatch`: event timestamp to handler entry.
- `input-to-render`: oldest pending navigation event to render entry, including coalesced event count.
- `navigation-frame-gap`: time between renders with navigation input, excluding pauses of 250 ms or longer. This reflects input cadence as well as rendering delays; it is not a dropped-frame count.
- `raf-wait`: scheduling a paint to entering its animation-frame callback.
- `wheel-handler`, `pan-handler`: navigation handler execution.
- `geometry-rebuild`: compiling SVG geometry and file-label hit boxes.
- `raster`: drawing a cache surface, with reason, pixel count, and item counts. Reasons distinguish overview creation, missing detail, changed revision, changed scale/viewport, and panning outside cached bounds.
- `canvas-composite`: clearing the display canvas and submitting cached images.
- `overlays`: selection, hover, arrow, and fresh-node drawing.
- `selection-compile`, `repaint-hook`: SVG arrow measurements and repaint callbacks.
- `file-hit`, `edge-hit`: pointer hit testing.
- `search-match`, `search-suggestions`: search processing.
- `canvas-render`, `graph-repaint`: enclosing render durations, with scale and navigation state.
- `long-task`: browser-reported main-thread tasks over 50 ms, when supported. Firefox may not expose this entry type.

These measure JavaScript work and canvas command submission, not GPU completion or physical screen presentation. Browser performance traces are needed if the visual hitch occurs without a corresponding delay here.

Run `node tools/canvas-checks.mjs /tmp/visualize-canvas.png` for isolated browser verification. It also saves `/tmp/visualize-canvas.png.trace.json` with the captured phases. Those fixture timings are not a measurement of a live project's performance.
