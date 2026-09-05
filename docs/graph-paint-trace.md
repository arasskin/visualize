The paint trace confirms that changing the root SVG transform triggers SVG layout and painting during ordinary panning. This is browser rendering work caused by the current transform target; the application does not reconstruct the graph.

The capture used an isolated copy of the current source and graph configuration: 42 nodes, 57 edges, 560 SVG elements. Chrome 152 ran headless on macOS arm64 at 1440 × 1000, DPR 1, in light mode. Terminal metadata was removed from the copied configuration. The running application and its terminal sessions were untouched.

Each gesture supplied 90 mouse or wheel updates through Chrome DevTools Protocol. Input dispatch pacing and detailed trace instrumentation make these diagnostic captures unsuitable as keyboard-to-display or smoothness benchmarks.

During baseline panning, there were 90 layout passes, 91 SVG paint events, and 16,830 SVG text layout invalidations: 187 text elements per update. Animation-frame JavaScript took 0.08 ms p95; layout took 1.41 ms p95. Baseline zoom also invalidated all 187 text elements on each update, with layout taking 2.15 ms p95. These runs establish recurring work but do not reproduce a large main-thread stall.

Holding the search arrow still and then hiding the invisible edge hit paths did not eliminate per-update SVG text invalidation or layout. Those changes were temporary experiments in the isolated page.

A second capture redirected transform writes to an outer HTML div, also only in the isolated page. Panning layout passes dropped from 90 to 1; text invalidations dropped from 16,830 to 187, and raster tasks dropped from 1,260 to 57. Painting was not entirely eliminated: 64 Paint events remained under the wrapper/document. The result supports moving the pan transform onto a wrapper.

Wrapper zoom still invalidated all text on each update and recorded 180 layout events. Its total layout time remained similar to baseline (132 ms versus 147 ms). The wrapper changes the paint event attribution, so zero events named as SVG paints does not mean SVG contents stopped painting. A wrapper alone is not an established zoom fix. A cached visual during zoom, with a sharp redraw at gesture end, would be a separate experiment with a text-sharpness tradeoff.

Detailed counts and durations are in [graph-paint-results.json](graph-paint-results.json). Raw Chrome traces are saved at `/tmp/visualize-paint-trace.json` and `/tmp/visualize-paint-wrapper-trace.json`; load them in Chrome DevTools Performance. They are temporary local artifacts and are not committed to the repository.

Reproduce:

```sh
node tools/paint-trace.mjs /tmp/visualize-paint-trace.json
PAINT_CASE=wrapper node tools/paint-trace.mjs /tmp/visualize-paint-wrapper-trace.json
```

The trace tool does not apply the wrapper to application source files.

The inner-group implementation was subsequently traced with the same 90-update gestures and the same 42-node, 57-edge graph. Its raw capture is `/tmp/visualize-paint-group-trace.json`; the `inner-group` run in the results JSON contains the measurements.

Panning now records zero SVG text layout invalidations. There are still 90 layout passes, but these concern the camera group: total layout time fell from 71.258 ms to 3.361 ms, with p95 falling from 1.411 ms to 0.060 ms. Paint events remained at 182 and total recorded Paint time was 59.383 ms. Moving into a group therefore removed text relayout from panning but did not make it compositor-only.

Zooming still records 16,830 text layout invalidations, now reported as “SVG changed,” as well as shape and path invalidations. Total layout time was 175.493 ms, versus 146.694 ms in the earlier root-transform trace, with p95 at 2.921 ms versus 2.148 ms. These separate, instrumented runs do not establish a precise speed regression, but clearly show that the group transform did not eliminate repeated zoom layout. Freezing the search arrow and hiding hit paths did not eliminate it either.

Paint attribution changed after introducing the group, so the `svgPaints` field being zero does not mean the graph avoided painting. The capture explains recurring rendering work; it does not fully account for the user's perceived lag in their interactive browser.

The temporary CSS gesture implementation was traced after reverting the inactivity delay from 1 second to 150 ms. Raw capture: `/tmp/visualize-paint-gesture-trace.json`. The `temporary-css-gesture` entry in the results JSON contains the measurements.

For 90 zoom updates, Chrome recorded 17,017 SVG text layout invalidations (91 batches of 187), 182 layout passes, and 92 Paint events attributed to the graph layer. 16,643 text invalidations occurred before the final wheel event, establishing that this work happens during active zoom rather than only when the idle timer commits the view. Total layout time was 109.713 ms, with 1.703 ms p95 and 2.111 ms maximum per Layout event. The animation-frame callback was 0.122 ms p95. The HTML zoom label also generated 90 paint events. Paint events are browser recording operations, not necessarily distinct displayed frames.

The temporary transform keeps SVG attributes stable, but Chrome still invalidates SVG text when the ancestor scale changes. It is therefore not a fixed image cache. Extending the idle delay cannot remove that per-update rendering work. An explicit bitmap or texture during the gesture would be a different mechanism and has not been implemented or measured.

Panning recorded only two layout passes and 187 text invalidations, so the method continues to help translation more than scaling. Freezing the search arrow and hiding invisible hit paths did not eliminate the zoom text invalidations. No RunTask event exceeded 50 ms in these gesture intervals; the isolated headless capture still does not fully reproduce the perceived jank of the live browser.
