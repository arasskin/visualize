Panels can dock to either the top or bottom tab rail. Both rails use 6px edge and inter-tab spacing, with independent horizontal scrolling. Drag a title bar near either screen edge to dock it, between tabs to reorder it, or away from the rails to float it.

Top panels open downward. Bottom panels keep their title bar at the bottom and open upward; their resize grip moves to the upper-right corner. Closed tabs on either rail resize horizontally from the right edge. Alt+Enter opens a new terminal on the top rail. Cmd/Ctrl+T uses the selected panel's rail, defaulting to the top when the selected panel is floating. MCP-created terminals appear collapsed on the bottom rail.

The Visualize panel defaults to a 26rem width, capped at 92vw, on the bottom rail. Recovered MCP terminals appear collapsed on the bottom rail; other terminal tabs default to the top rail on reload. Rail positions remain in-memory. Each terminal tab has a close button at the right that stops its session and removes the tab; the drag-to-trash target is removed.

Alt+H/L moves along one continuous order: bottom rail left to right, then top rail left to right. Left from the first top tab continues at the last bottom tab. Navigation stops at the bottom-left and top-right endpoints; it does not wrap. The existing temporary opening behavior while Alt is held is preserved.

The bottom timing/zoom display and the plus and question-mark buttons are removed. Keyboard shortcuts for new terminals and help remain available. Search and command inputs share the same vertical position and field height above the bottom rail.

Run `node tools/rail-checks.mjs` for isolated Chrome checks covering docking, opening direction, resizing, rail spacing, viewport resizing, undocking, new-terminal placement, and independent scrolling.

Alt+Enter starts a plain login shell. Computer-created tabs use the same default width as Visualize, start closed on the bottom rail, and display the title supplied through the pane API.
