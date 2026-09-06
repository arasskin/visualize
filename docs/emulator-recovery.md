The vendored WTerm packages were upgraded together from 0.3.4 to 0.5.0 after two live terminal captures reproduced failures in the old Ghostty WASM build. One reported an internal page integrity violation, `UnmarkedStyleRow`, followed by a WebAssembly `unreachable` trap. The other looped inside the WASM write path and blocked the browser's main thread.

The published 0.5.0 binary completes both captures. Browser replay also passed for those two dev panes and a third terminal. All 14 streaming integration checks passed, including keyboard input, reconnects, and split Unicode. Light/dark palette, background-query, and reset checks passed. The upgrade uses the [upstream release](https://github.com/vercel-labs/wterm/blob/main/CHANGELOG.md) without local binary patches; `tools/vendor-wterm` defaults to 0.5.0 so re-vendoring preserves the fix.

Captures contain private terminal output and remain outside the repository. To check a local capture containing a JSON array of base64-encoded output batches:

```sh
node tools/emulator-replay.mjs 98 30 /path/to/capture.json
```

An optional fourth argument selects an older WASM binary for comparison. Replay runs in a Node worker with a ten-second timeout so an emulator loop cannot hang the test runner. Browser integration was checked separately; this replay tool exercises the binary's write path.

Browser worker isolation is not implemented by this upgrade. A future design would put each emulator in its own Web Worker, exchange transferable output buffers and screen updates, and retain DOM rendering on the main thread. WTerm's synchronous reads of cells and input modes would need an asynchronous adapter with cached render snapshots. A watchdog could terminate a stuck worker while leaving other panes and server-side terminal sessions alive.
