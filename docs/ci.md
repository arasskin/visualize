CI runs on pushes to `main`, pull requests, `v*` tags, manual dispatch, and nightly at 05:23 UTC. The workflow is [`.github/workflows/ci.yml`](../.github/workflows/ci.yml).

All jobs use macOS 15 Apple Silicon runners and Node 22. Each job builds from a fresh checkout without a binary cache. The backend job rejects pre-existing build outputs, and builds use only system tools on PATH. Checkout, Node setup, and artifact upload actions are pinned to commits. The workflow has read-only repository access and needs no harness credentials.

Every run includes:

- `./src/test/run`: backend, parser corpus, native terminal, HTTP and WebSocket regressions.
- `node tools/frontend-checks.mjs`: frontend invariants and dependency boundaries.
- `node tools/launch-checks.mjs`: startup, `vz`, configuration, and recovery with a fake harness, plus native PTY Ctrl-D restarts during a blocked graph operation and terminal-session preservation across repeated restarts.
- `node tools/websocket-output-checks.mjs`: large snapshots and reconnects.
- `node tools/pane-interaction-checks.mjs chrome` and `firefox`: pane, terminal, document, focus, persistence, and resize interactions, in separate jobs. Rail coverage includes opposite-rail spacers, multiple spanning panes, shared scrolling, and releasing space when panes shrink, collapse, undock, or close.

- `node tools/config-editor-checks.mjs`: config graph editing, autocomplete, navigation, and synchronized document views, after the Chrome pane checks.

Nightly, manual, and version-tag runs also execute the complete resize matrix and `./src.graphviz/build --check` with the undefined behavior sanitizer. Browser suites within a job run sequentially because their servers choose from the same port range. There are no automatic test retries or performance thresholds.

The resize matrix creates its own fixed graph configuration; it does not require a developer's untracked `visualize_config` file.

Failures upload diagnostics for seven days. Set `VZ_TEST_ARTIFACTS` to a directory when running pane interaction checks locally to retain server logs, browser errors, terminal error logs, and a screenshot when the browser is still reachable. CI keeps command output under `.logs/ci`. New runs cancel older runs for the same event and ref.

GitHub must receive the workflow commit before it can run. Making the jobs required for merging is a separate repository ruleset setting. Linux coverage is deferred until the remaining platform assumptions are addressed.
