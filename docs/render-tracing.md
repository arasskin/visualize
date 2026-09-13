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
- `raster`: drawing a missing tile, with `reason: "tile"`, tile column/row, pixel density, pixel count, and item counts.
- `canvas-composite`: clearing the display canvas and submitting cached images.
- `overlays`: selection, hover, arrow, and fresh-node drawing.
- `selection-compile`, `repaint-hook`: SVG arrow measurements and repaint callbacks.
- `file-hit`, `edge-hit`: pointer hit testing.
- `search-match`, `search-suggestions`: search processing.
- `canvas-render`, `graph-repaint`: enclosing render durations, with scale and navigation state. `canvas-render` also records the number of tiles rebuilt, cached, and visible.
- `long-task`: browser-reported main-thread tasks over 50 ms, when supported. Firefox may not expose this entry type.

The main graph caches 512×512 device-pixel tiles at the current zoom resolution. Missing visible tiles render during navigation; there is no lower-resolution overview fallback. Cached pans only composite images, with translation snapped to device pixels. Two extra pixels around each tile preserve antialiasing at the edges; only the interior is composited, so translucent shapes do not overlap. An LRU cache retains up to 96 tiles (about 98 MiB of RGBA pixels). Zoom or pixel-density changes, geometry rebuilds, font changes, and theme changes invalidate tiles. Viewport resizing retains tiles when pixel density stays the same. Hover, selection, and search arrows remain separate overlays.

These measure JavaScript work and canvas command submission, not GPU completion or physical screen presentation. Browser performance traces are needed if the visual hitch occurs without a corresponding delay here.

Run `node tools/canvas-checks.mjs /tmp/visualize-canvas.png` for isolated browser verification. It also saves `/tmp/visualize-canvas.png.trace.json` with the captured phases. Those fixture timings are not a measurement of a live project's performance.
