# WTerm rendering and input

Visualize uses WTerm 0.5.0's DOM renderer and input encoder with its native libvterm supervisor. `wterm-dom-wterm.js` is the locally maintained screen-only host: it requires a supplied screen core and does not parse terminal output or answer terminal queries. Synchronization is owned by the supervisor.

These rendering and input components are maintained locally as part of Visualize. The upstream Apache 2.0 license is retained in `LICENSE`.

The shipped JavaScript and CSS files differ from the published `@wterm/dom` 0.5.0 package and carry modification notices. Changes include renamed modules/imports, removal of the Ghostty host, native-screen integration, and local input, selection, hyperlink, rendering, and styling changes. The published package has no separate `NOTICE` file; its Vercel copyright notice is retained in `LICENSE`.

The host exposes `core`, `measure()`, and `refreshScreen({follow, historyChanged})` for the screen adapter. `onRender(duration)` runs after the screen DOM and scrolling have updated; `onRenderError(error)` reports rendering failures. Callers do not replace private methods or manipulate renderer scroll state.
