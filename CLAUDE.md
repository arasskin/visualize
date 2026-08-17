# Working on visualize

A dependency-graph viewer in Janet. `README.md` is the full account -- how the
config language works, what `v` is, why the layout replaced graphviz. This file
is only what you need in the first five minutes, and the traps that cost a
session each.

## The server runs from a loaded image

**Editing a file does not change what the page draws.** The server holds the
modules it compiled at startup, so your change is invisible to it until you
reload -- and a fresh `janet` you run yourself will happily give you different
numbers from the page, which is a confusing way to spend an afternoon.

    ./vz reload            load your edits (git tells it which, innermost first)
    ./vz shot out.png      what the graph looks like now

That is the loop. `vz reload` exits non-zero and names the file if something
fails to compile, and leaves the repl usable either way.

## Reaching the live image

    ./pane repl '(expr)'   evaluate, where a person watching the page sees it
    ./pane repl            just read what the pane shows
    ./pane harness 'text'  type at the agent in the other pane

`vz eval '(expr)'` and `vz pane repl '(expr)'` are the *same script* -- pick
whichever reads better. `./pane` with no arguments prints its own usage.

**Do not open `nc -U` to the repl socket.** It gets a private evaluation
environment that nobody watching the page can see, and work done there leaves
no trace to scroll back through. `./pane` types into the pty instead, so what
you type, a person sees typed.

## Tools

    ./vz                   the list, with what each one is for
    ./vz scan [pattern]    files, sizes, what each depends on
    ./vz faults [n]        what has gone wrong lately, with stacks
    ./vz where             url, root, state directory
    ./test/run             510+ assertions, no framework
    ./visualize            start a server (dev mode; ./build runs first)

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
measuring the same property of the graph a second time -- how many edges
cross, how far a bend sits from its line, how deep an edge cuts into a node --
that is the signal.

It also makes the measurement available to the next person rather than to the
transcript it was buried in, and puts it somewhere a test can call.

## Traps

- **`dev/reload` takes a substring of the path.** `"layout"` now resolves to
  `src/layout.janet` rather than erroring, but a name matching several
  unrelated modules still needs to be exact.
- **A failed reload drops the repl into `debug[1]`**, where every later
  expression evaluates in the wrong environment and the next reload will look
  like it worked. `(quit)` leaves -- once per level, and they nest.
- **Reload innermost first.** A module that imports another holds bindings
  from it, so reloading `select` alone leaves `layout.janet` and
  `graph.janet` calling the version they compiled against. `vz reload` orders
  by path depth for this reason; if you reload by hand, follow it.
- **The tests do not need the server**, and the server does not notice the
  tests. They are separate images.

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
If you are tempted to write another one, read that history in git first --
`docs/dotgen-audit.md` and the commits around 2026-08-17 record what was
tried, what each attempt measured, and which of them made the picture worse
while improving the numbers.
