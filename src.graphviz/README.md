Visualize's embedded Graphviz bridge takes a DOT string and returns SVG or diagnostics. `src.server/graphviz.janet` owns the returned buffer until it has copied it into Janet, then frees it. The graph worker uses `dot` for both the project graph and the config editor.

`./build` builds `libvisualize-graphviz.so` with the system C compiler on macOS and Linux. `./src.graphviz/build --force` rebuilds it; `--clean` removes the generated library. Publication uses an atomic rename so a running server keeps its loaded library until restart. No `dot`, CMake, package manager, plugin cache, or network connection is required to build or run it.

Graphviz 15.1.1 and Expat 2.8.4 are vendored under `external-src`. The build includes DOT layout, spline routing, SVG rendering, and HTML labels. Layout and SVG plugins are registered statically with demand loading disabled. Expat is linked into the same library. Only our four bridge functions are exported.

Each render creates and frees its graph and context. Graphviz has process-global parser, error, and layout state, so all Graphviz calls are protected by one native mutex, including context creation and destruction. This also protects callers using separate Janet worker threads. A native crash can still terminate the server process; thread isolation does not provide process isolation.

Text measurement uses Graphviz's built-in metrics rather than Pango or platform font discovery. The SVG keeps the requested font name, and the browser still draws with Visualize's bundled Parkinsans font. Some label or cluster dimensions can differ from a system Graphviz build with Pango. Additional layout engines, image loading, compressed SVG, and raster/PDF renderers are not included.

`src/test/graphviz.janet` covers rendering without `dot` or installed plugins, HTML and Unicode labels, nested clusters, errors followed by valid renders, repeated layouts, and concurrent callers. The existing graph and canvas checks exercise integration with Visualize.

`./src.graphviz/build --check` builds a temporary executable with UndefinedBehaviorSanitizer and runs 400 valid and 400 malformed renders across four native threads, followed by a 14,000-node fan-out layout on a 512 KiB worker stack. The wide-graph check verifies that every node and edge is rendered and guards against the native stack overflow in network simplex reranking. It leaves the application library untouched. Local correctness patches are documented in `external-src/graphviz/README.visualize.md`.

Validated on macOS ARM64: the Janet suite, browser canvas and config editor integration suites, and native UBSan check pass. Temporary check executables and their macOS debug-symbol bundles are removed on exit. Linux has not been tested because the local Docker daemon is unavailable. Apple Clang 17's AddressSanitizer hangs during runtime initialization on this macOS installation, before the test program starts, so no ASan result is claimed.
