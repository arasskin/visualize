# Working on visualize

A dependency-graph viewer in Janet. It scans a source tree, works out what
imports what, and draws the result with graphviz. `README.md` is the full
account of the config language; this file is what you need in the first five
minutes.

## The loop

    ./visualize            start a server (./build runs first)
    ./vz shot out.png      what the graph looks like now

The server watches the tree and redraws when a file changes, so an edit to
the code you are viewing shows up on its own. An edit to visualize ITSELF
needs a restart: the server runs from the modules it compiled at startup.

## Tools

    ./vz                   the list, with what each one is for
    ./vz scan [pattern]    files, sizes, what each depends on
    ./vz dot [file]        the DOT the page is drawn from
    ./vz where             url, root, state directory
    ./test/run             210+ assertions, no framework
    ./visualize            start a server (./build runs first)

`vz shot` writes SVG by default because SVG is text -- you can read node names
and positions straight out of it. Ask for `.png` when you want to look.

### A measurement worth making twice belongs in `vz`

Write new tooling as a `vz` subcommand, not as a script in a scratch
directory. The scratch version is gone next session and the one after it gets
written again from nothing -- one session rewrote the same crossing counter
four times before it occurred to anyone that it was a tool.

The bar is low: `vz` is a shell script that reads a state file or posts to an
endpoint, and every subcommand in it could be typed by hand. Adding one is a
case in its `case` and a line in its usage block. If you find yourself
measuring the same property of the tree a second time, that is the signal.

It also makes the measurement available to the next person rather than to the
transcript it was buried in, and puts it somewhere a test can call.

## Traps

- **The tests do not need the server**, and the server does not notice the
  tests. They are separate images.
- **`dot` must be installed.** graphviz draws every picture; without it the
  page reports that it could not render and names the install command.

## Layout work specifically

**graphviz draws the graph.** `src/layout.janet` writes the graph as DOT --
groups become clusters, the config's colours become node attributes -- runs
`dot -Tsvg`, and strips the XML prolog so the result can be inlined into the
page. That file is the whole layout; there is nothing else to read.

`dot` is therefore a **hard runtime dependency**. Nothing renders without it,
and the error a caller sees when it is missing names the install command.

**The page contract is graphviz's own**: `g.node` with a `<title>`, `g.edge`
with a `<title>` of `from->to`. Two details differ from what a hand-rolled
renderer would emit, and both are handled -- dot escapes the arrow as
`-&#45;&gt;` (normalised in `layout.janet`), and it writes a multi-line label
as sibling `<text>` elements rather than `<tspan>`s (handled in
`web/app.js`'s `moduleNames`, which reads both shapes).

**The old layout lives on the `feast` branch**, at the last commit before it
was deleted. Nothing on `main` needs it, but it is intact there rather than
only in history: `git show feast:src/layout/layered.janet`, or check the
branch out to run it.

**There was a custom layout here** -- about six thousand lines of Sugiyama:
two rankers, two coordinate passes, mincross with transpose and sift, and a
funnel-and-slab spline router. It reached zero edges through nodes and zero
clipped outlines, and never reached dot's crossing count (12 against 2,
measured with the same scorer on the same tree). It was deleted deliberately.
If you are tempted to write another one, read that history first -- the
commits on `feast` record what was tried, what each attempt measured, and
which of them made the picture worse while improving the numbers.
