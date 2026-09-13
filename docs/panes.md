Pane geometry belongs to `makePanel` in `src/web/panes.js`: dragging, rail placement, dimensions, selection, and the resize observer. Closing removes the pane from the registry and disconnects its observer. Placement persistence records the expanded height even while a tab is collapsed, and includes collapsed config editors. A resize schedules a save without waiting for a later dock operation or page reload.

Terminal content owns its subscription, resize and recovery timers, window listeners, and WTerm renderer. Removing a pane or replacing its terminal with a document releases those resources. Removal marks the content disposed before waiting for an in-flight startup request; its completion cannot resubscribe or reopen the pane. The server's pane watch also excludes local closures until it observes their removal.

Recovery retries interrupted reads and theme synchronization. It does not automatically replay input or a start request whose delivery is unconfirmed. Failed starts retain their diagnostic instead of subscribing to a nonexistent terminal and replacing the error with an exit status.

Terminal paint notifications run after WTerm updates the DOM. During a resize, scroll following remains anchored until the requested rows and columns have painted. A user reading scrollback keeps that position.

Run `./src/test/run` for backend tests. Unexpected stderr fails the run, including errors from background fibers. The HTTP tests supervise listener and connection tasks to verify clean shutdown and incomplete-request handling.

Run browser checks with Node 22 or later:

```sh
node tools/pane-lifecycle-checks.mjs chrome
node tools/pane-lifecycle-checks.mjs firefox
node tools/pane-resize-checks.mjs
node tools/rail-checks.mjs
node tools/file-command-checks.mjs
node tools/config-editor-checks.mjs
```

The lifecycle checks exercise repeated native pointer drags, collapsing and reopening, startup cancellation, completed-session removal, browser reload, floating document recovery, and server restart. Both browsers run against temporary projects with separate profiles, without touching live Visualize sessions. Set `CHROME` or `FIREFOX` to override the executable; the defaults are their macOS application paths. Firefox uses its built-in WebDriver BiDi endpoint, and Chrome uses CDP. No browser automation package is required.
