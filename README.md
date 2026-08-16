# visualize

A dependency graph you draw by editing a file.

```bash
./visualize ~/code/some-project
```

Opens a browser. The graph is your project; the panel top-left is the config
file that drew it, editable in place. Every keystroke that lands is a real edit
to a real file on disk, so the view you leave is the view you come back to.

The first run compiles the bundled Janet runtime — a few seconds, once. Every
run after it starts immediately.

This is a generalisation of the two `depgraph` scripts in `otto-ios` and
`shoppingagent` — same config language, same colours, same picture, but the
language-specific half is now a 50-line data file rather than the whole
program.

## Requirements

A C compiler.

That is the whole list — there is nothing to install. **The Janet runtime is
in this repository**, as the official amalgamated source in `vendor/janet/` —
so a clone builds offline, with no package manager, no lockfile, and no
`node_modules`, and builds the same runtime a year from now. The layout is
ours too: `dot` used to be on this list, and both layouts now ship in
`src/layout/`.

```bash
./build           # compile bin/janet when it is missing or stale
./build --force   # compile it regardless
./build --clean   # delete it
```

`./visualize` and `./test/run` both call `./build` first, and it does nothing
when the runtime is already compiled — so there is no separate setup step to
remember.

Node is optional and only for tests: `web/term.js` runs in a browser, so its
suite needs a JavaScript runtime. `./test/run` skips those and says so when
node is absent.

Sizes: 3.3MB of vendored runtime, ~230K of tool source, ~3,800 lines of Janet,
HTML, CSS and JavaScript. `bin/janet` is a build artifact and is gitignored.

## The config language

The file is `config.janet`, written into whatever directory you point at.
It is created on first run, so there is something to edit rather than a blank
pane.

```lisp
(show-only ~)              # narrow to our own files — the everyday setting
(hide ~.Tests)             # drop it, and every edge touching it
#(hide ~.Tests)            # comment it out to put it back
(hide ~.Clip.)             # trailing dot: its contents, not itself
(group ~.Clip)             # box its members, next palette colour
(group ~.Shared #a54a4a)   # ...or a colour you name
(fill-color)               # fill nodes instead of outlining them
(show-lines)               # write each file's line count on it
(show-lines-coloring)      # ...and shade by size instead of by edges
(font "Helvetica")         # draw it in something else
(harness claude)           # what the terminal window runs -- or (harness pi)
(layout force)             # relatedness instead of direction -- or (layout layered)
```

`~` **is the project**, the way a shell expands `~` to a home directory:
`~.OttoClip` is the OttoClip directory and `~` alone is everything of yours.
Every other name is literal, so `(group SwiftUI)` and `(hide WebKit)` work on
imported frameworks exactly as they do on your own files.

Without a `(show-only)`, the graph carries the packages your code imports as
well as your own files — which is how to see what the project actually links
against.

### It is real Janet

The Python originals had a hand-written reader for a flat dialect: atoms only,
no nesting, six functions. This one is Janet, so the six verbs are ordinary
functions and everything else comes free:

```lisp
(each name ["Core" "UI" "Net"] (group (string "~." name)))
(def mine "~.OttoClip")
(hide mine)
```

Two notes on the notation, both consequences of Janet's reader:

- `~` and `#rrggbb` are rewritten before parsing (`src/tilde.janet`). Janet
  reads `~` as quasiquote and `#` as a comment, and both collisions are in
  notation the existing config files already use.
- A bare name that isn't bound resolves to itself, which is the rule the Python
  reader had — `(group SwiftUI)` groups the framework.

The config runs in a sandbox holding the verbs and a few pure helpers. There is
no `os`, no `file`, no `net`: it is edited through a web page, and the blast
radius of a typo there should be a wrong-looking graph.

A form cannot span lines — a line is the unit that gets parsed and the unit an
error attaches to. One bad line is reported under itself and the rest still
runs.

## v, the graph language

The config says what you want to see. **v** is what the graph *is* — the text
the scan renders to and the layouts read back. A v file is a list of facts,
each one an **entity, an attribute, and a value**:

```lisp
(~.term color "#ff4d6d")
(src_color label "src/\ncolor" ours size 187)
(SwiftUI label "SwiftUI")
(src_term_host label "src/term/\nhost" ours size 669 ~.term)
(src_color->src_graph from src_color to src_graph)
```

A form is `(e a1 a2 a3 v3 …)`: the first atom names the **entity**, and
everything after it is an **attribute** that either stands alone or takes the
atom after it. So one line is a handful of rows sharing an entity —
`(src_color label "…" ours size 187)` is four:

```
src_color  is     true
src_color  label  "src/\ncolor"
src_color  ours   true
src_color  size   187
```

`v/facts` is the seam: it turns text into rows, and `v/parse` builds a graph
out of rows. Code that wants the *facts* rather than the picture stops at the
first one.

**A closed schema is what makes that readable.** `(A ours size 187)` would be
ambiguous on its own — `size` could be the value of `ours` as easily as an
attribute of its own — so `v/attributes` declares every attribute the language
has and whether it takes a value. The parser never guesses. It also means
`label` and `:label` are the same word: the colon used to be the only way to
tell an attribute from a value, and with a schema it's just spelling.

**Everything is an entity**, including the things that used to be forms. A
group is an entity with a `color`; an edge is an entity with `from` and `to`;
and a node joins a group by *naming* it — a bare word that isn't a declared
attribute is a reference to another entity. That last inference is decidable
precisely because the schema is closed.

**It was nested s-expressions first, and that was a mistake.** The obvious lisp
move is to make a group a form that *contains* its members. It reads well and
it asserts a hierarchy the data doesn't have: membership here is many-to-many
and crosses layers freely. The parens claimed a containment the renderer
already knew was a lie — and the tree got flattened on read anyway, so it was a
shape no consumer ever read as a shape. Naming a group instead, a node in two
groups is expressible instead of unsayable, and a group whose members land on
four different ranks says exactly what it means.

**This replaced graphviz and DOT**, and the reasoning was the same for both.
DOT is a language for describing *drawings*: ports, splines, rankdir,
peripheries, a hundred attributes that exist because graphviz can draw a
hundred things. This tool draws one thing. Everything past that was surface to
keep generating correctly and never read back — and a foreign syntax in a tree
written in a lisp, which meant quoting rules, identifier sanitising, and a
parser nobody would write because the text only ever went one way: out, to a
subprocess.

**It round-trips**, which is the difference between a language and a
serialiser. `v/render` writes a graph; `v/parse` reads it back to the same
graph, and `src/layout.janet` puts that round trip on the *only* path to a
picture. So the language cannot rot the way a debug-only format does, and
`vz shot` is showing you exactly what the renderer saw.

**The PEG is the spec** (`grammar`, in `src/v.janet`) — there is no second
description of the syntax to drift from it. A bare word is anything that is
not a delimiter, so `~.Otto`, `#ff4d6d` and `demo-api` all parse unescaped;
strings are double-quoted and decode their escapes, which is the only place a
space or a newline appears.

### Two layouts

```lisp
(layout layered)   ; the default
(layout force)
```

**layered** is Sugiyama, the algorithm `dot` ran, in about four hundred lines
(`src/layout/layered.janet`): rank every node onto a layer so edges point one
way, order each layer to cut crossings, place each node so parents sit over
their children, route the edges that span more than one layer around what is
in between. Cycles are broken by provisionally reversing the edges that close
them, so a dependency loop draws as an arrow running back up the page rather
than being silently rewritten.

Seven things in there are what closed the gap with `dot`, each one measured
against `dot`'s own output on this repository's graph:

- **A long edge is threaded through real bend points**, one per layer it
  crosses, and those bends are placed *before* ordering — so they take part in
  crossing reduction and get a column of their own. Inventing them afterwards
  by interpolating along the straight line, which is what this did first, puts
  the bends exactly where the line already was: 26 of 42 edges ran through a
  node that had nothing to do with them.
- **A node with no parent sinks to just above its children.** Longest-path
  ranking is correct and reads badly — it stranded seventeen of thirty-three
  nodes in the top row, and that row set the width of the whole picture.
- **A node with no edges at all goes on a shelf above the graph.** It stays on
  the graph, because "nothing you are looking at uses this" is a fact worth
  drawing; it just does not get to widen the rank that is doing the work, and
  it is read on the way in rather than found underneath afterwards.
- **A group is one box, and the layout makes that box true.** A group says
  nothing about layers — a group whose members land on four ranks is still one
  group — so it gets one rect with its name on it once. Drawing a band per
  layer, which is what this did first, was a workaround for the box being
  *wrong* rather than for groups being layer-shaped: a single rect around
  scattered members swallows whatever sits between them, and a group split
  across two ranks then looked like two groups. So the layout keeps a group
  over itself across layers and a member stands for the whole rectangle when
  the layer is packed, so a group two members wide on one rank takes that
  much room on every rank it spans. Packing against the member instead let a
  neighbour sit flush against the node and inside the box that reached over
  it from the rank beneath.
- **The crossing sweep scores a group as one node.** Every member on a layer
  takes the median of all their neighbours together, so the group and the
  nodes around it are seated in the same decision. Ordering the layer first
  and shuffling the group together afterwards — which is what cohesion alone
  does — fixes where the ungrouped nodes go *before* the group has taken its
  slot, and a node whose only edge runs past the group gets stranded on the
  wrong side of it: `src/parser` sat 318 units from `src/scan`, the one node
  it connects to, with its edge crossing the whole `src.term` box to reach
  it. Scoring them together puts it 13 units away, directly above. Cohesion
  still runs, and still last, because a shared median makes members *want*
  the same slot without guaranteeing it.
- **Every pass says what it wants; one function decides where things go.** A
  node has several things pulling on it — sit over your parents, lie on the
  line your edge wants, stay out of a box you are not in — and each of those
  used to move the node itself and sweep the layer apart afterwards. A sweep
  pushes one way, so the passes undid each other in sequence: clearing a box
  shoved a node onto its neighbour, the next sweep shoved it back into the
  box, and the picture kept whichever defect the last pass left. Adding a
  pass meant finding out which of the others it broke. Now a pass contributes
  a desired position, a hard bound, or a pin, and `settle` returns the
  closest arrangement that keeps the order and the gaps — so non-overlap is a
  property of the output rather than of the order the passes ran in.
- **A real node wins a near-tie with a bend.** A bend's median comes from the
  one chain link it has, so it is exact; a node's is the average of
  everything it touches, and a single unrelated neighbour off to one side
  drags it half a position. `src/scan` scored 8.5 from links at 7 and 10
  while the `src/json → src/graph` bend scored exactly 8, so the bend sorted
  ahead of it by half a slot and was pushed out the far side: its bend landed
  ninety units from the straight line between its own ends, and the edge took
  the long way round `src/scan` instead of running down beside
  `src/state`'s. Half a position is not a real preference, so the node keeps
  the slot and the edge routes past it on the side its line wants.

Sizes are fitted to what `dot` produced for the same labels rather than
guessed. That sounds cosmetic and is not: `place-x` separates nodes by their
drawn width, so an ellipse 78% too wide made *the layout* that much too wide.
Together these took the picture from 2163×668 to 1269×737, against `dot`'s
1140×629, and cut edge crossings from 44 to 6.

What it deliberately does not do is what made graphviz big: no spline routing,
no port constraints, no orthogonal edges. A dependency graph needs none of
them.

**force** lets nodes repel and edges pull until the picture settles. It shows
relatedness rather than direction, so it reads better for a tangle than for a
hierarchy — and it draws no group boxes, because a force layout has no reason
to keep a group contiguous and a box around scattered members would claim a
structure the picture does not have.

## The harness window

A second panel runs an agent in a real terminal, beside the graph. Same
furniture as the config editor: drag the bar to move it, the grip to resize,
click the bar to collapse it into just the bar.

```lisp
(harness claude)          ; the default
(harness pi)
(harness "/bin/sh" "-i")  ; anything with a command line
```

**Nothing in the terminal knows which agent it is running.** `src/pty.janet`
takes argv and `web/term.js` takes bytes, so Claude Code and pi go through
identical code — the harness is a config value, not a code path.

It is a real terminal, not a chat box. `forkpty` asks the kernel for a
pseudo-terminal, so `isatty()` is genuinely true and a TUI renders as it
would in any other terminal. Nothing here defeats a tty check; it satisfies
one, the same way tmux and ssh do.

The session survives a page reload — the browser attaches to a backlog of
output rather than to the pty — and collapsing the panel leaves the agent
running.

### What the harness can reach

The terminal pane holds the intelligence -- claude, pi, whatever the config
names -- and `vz` is on its PATH, so it can reach what *this* program knows
rather than only the tools it brought:

```bash
vz scan [pattern]     files, sizes, what each one needs
vz faults [n]         what has gone wrong, with stacks
vz eval '(expr)'      evaluate in the running server's image
vz shot [file]        the graph as it looks now (SVG, or .png)
vz pane repl 'text'   type into a pane
vz state [name]       the facts on disk
vz where              url, root, state directory
```

Every one of these reads a state file or posts to an endpoint -- there is no
privileged channel, and anything `vz` does could be done by hand. A session
opens with a one-line note saying they exist, because an agent cannot use
what it does not know about.

### Driving a pane from outside the page

An agent working on this tool -- or you, from a second shell -- can type
into a pane instead of opening a private connection to the image:

```bash
./pane repl '(dev/reload "layout")' # evaluate in the live image
./pane harness 'what changed?'     # type at the agent
./pane repl                        # just read what the pane shows
```

The point is visibility. `nc -U` to the repl socket gets its own evaluation
environment, invisible to whoever is watching the pane in the page; work done
that way leaves no trace on screen. `./pane` sends the same text as keystrokes
to the pane's pty, so what an agent types, you see typed -- and can scroll back
through afterwards.

It reads this run's url and token from a dev-mode file beside the sockets, and
posts to the same endpoints the page uses.

### What it knows, on disk

A project gets a `.visualize/` directory holding what the program knows about
it: `scan.json` (every file, dependency, and line count) and `faults.jsonl`
(what has gone wrong, one JSON object per line).

```bash
cat .visualize/scan.json | python3 -m json.tool | head
tail -3 .visualize/faults.jsonl
```

This is the substrate the rest of the tool is meant to sit on. A view of a
project -- the graph this ships with, or one an app writes for itself -- is
then something that reads a file, rather than something that has to be built
into the server and reached through an endpoint. It also means the facts
outlive the process: a crash that takes the server down leaves its own
explanation behind.

Add `.visualize/` to `.gitignore`; it is a cache and a log, not source.

### When the server itself breaks

Server errors used to go only to stderr -- invisible to an agent working in a
pane, and gone unless you were watching the terminal you launched from. They
are now kept in a ring the tool can be asked about:

```bash
./pane repl '(faults/print-recent)'   # the last few, with their stacks
```

The pane's state line says `2 server faults` when there are any, so a failure
announces itself rather than waiting to be looked for. Repeats collapse into a
count, since a failing poll fails several times a second and sixty identical
entries would bury the one fault that explains them.

### The terminal endpoints need a token

Everything else visualize serves is derived from files, and the worst a stray
request can do is redraw a graph. These endpoints run a program, and
**127.0.0.1 is not a boundary**: any page in any tab can POST to a localhost
port. So a secret is generated per run, embedded in the page (not a cookie, so
it dies with the tab), and required on every terminal request alongside an
`Origin` check.

## Adding a language

Drop a file in `src/parsers/`. Nothing else in the tree knows languages exist —
`src/parsers.janet` finds them by looking, so there is no registry to update.

A spec is data:

```lisp
(def spec
  {:name "go"
   :ext [".go"]
   :skip-dirs ["vendor" "testdata"]
   :noise    ~(+ ...)   # comments AND strings, blanked before :declares/:refs
   :comments ~(+ ...)   # comments only, blanked before :imports
   :imports  ~(* ...)   # captures → the modules this file imports
   :declares ~(* ...)   # captures → the names this file defines
   :refs     ~(* ...)   # captures → the names this file mentions
   :parse    (fn [text path] ...)})  # escape hatch: overrides the PEGs
```

**Two kinds of language, and the split matters.** Python, Go and JavaScript say
what they depend on: an import names a module and the graph writes itself, so
those specs declare only `:imports`. Swift does not — files in one module see
each other with nothing written down, so scraping imports would draw SwiftUI
and Foundation and miss every edge between your own files. Its spec therefore
declares `:declares` and `:refs`, and an edge means *this file mentions a type
that one defines*. The engine supports both; a spec picks by which keys it
sets.

`:noise` matters more than it looks. A Swift file embedding a JavaScript
program in a string literal contains `HTMLInputElement` and `Event` —
capitalised words that are not references to anything. Left in, they invent
edges to whichever file declares a colliding name, and the graph is quietly,
confidently wrong.

`:comments` exists because in most languages the import path *is* a string
literal. Blanking strings before reading imports erased every import in Go and
JavaScript; declarations get the strings blanked, imports get only the comments
blanked.

Five ship: `swift`, `python`, `javascript` (also .ts/.jsx/.tsx), `go`, `janet`
— which is why `./visualize .` draws this tool's own graph.

## Speed

The scan is multithreaded — real OS threads via `ev/thread`, one file per
thread, bounded to core count. It is embarrassingly parallel because no file's
parse depends on any other's.

```
2000 files, ~7.8MB
   1 thread  0.382s
   4 threads 0.125s
   8 threads 0.096s      ← 4× speedup
```

Real repos land in the tens of milliseconds: otto-ios is 20 Swift files in
8ms, shoppingagent is 153 nodes across several languages in 38ms.

The scan is cached, since the same sources always give the same answer. Only
the post-processing — hiding, grouping, colouring, all string work — reruns per
edit. **Regenerate** is how you say the source changed.

## Layout

```
visualize           run it (builds the runtime first if needed)
build               compile vendor/janet -> bin/janet, once
vendor/janet/       the Janet runtime, amalgamated: three files, no deps
src/core.janet      the core: event loop, HTTP, repl, harness, faults
src/graph.janet     the dependency-graph app -- the first thing built on it
src/scan.janet      walk the tree, read every file on all cores, build the graph
src/parser.janet    what a language spec is, and how one is run
src/parsers.janet   find the specs in src/parsers/ at runtime
src/parsers/        one file per language
src/term/           the terminal: everything one interface costs
src/term/pty.janet      a pseudo-terminal, via libc's forkpty through the FFI
src/term/host.janet      the live session behind one pane -- pty, pump
                        thread, backlog -- in a process of its own
                        (`visualize --supervise`), so restarting the
                        server keeps it running
src/term/client.janet    the client the HTTP routes talk through -- one per
                        pane -- and the wire protocol both ends agree on
src/select.janet    prefix matching and the filtering the config applies
src/v.janet         the graph language: a PEG, a reader and a writer
src/layout.janet    which layout draws the graph -- the seam between them
src/layout/layered.janet ranks, orders, places and routes -- the default
src/layout/force.janet   nodes repel, edges pull; for a tangle, not a tree
src/layout/svg.janet     positions to a picture, and the size of a label
src/color.janet     the palette, the ramp, and WCAG-checked label ink
src/config.janet    the sandbox the config runs in
src/tilde.janet     rewriting ~ and #rrggbb past Janet's reader
src/http.janet      just enough HTTP for one browser on localhost
src/json.janet      just enough JSON for the browser protocol
src/dev.janet       the repl the running server hosts, and its equipment
src/faults.janet    what has gone wrong lately, where an agent can read it
src/state.janet     the facts on disk, in .visualize/, for anything to read
src/watch.janet     notices the source changed, so nobody presses Regenerate
src/watchdog.janet  a thread that names event-loop stalls from outside them
src/stamp.janet     which code each process is running, for the handshake
vz                  the tools the harness comes with (on its PATH)
pane                type into a pane from a shell, so agent work is visible
tools/replay.mjs    run a captured session through the emulator, headlessly
web/term.js         a terminal emulator, in the ~25 sequences agents emit
web/                the page: vanilla HTML, CSS and JS, no build step
test/               500 assertions, no framework
bin/janet           the compiled runtime (gitignored build artifact)
```

## Theming

`web/style.css` is vanilla CSS. Everything themeable is a custom property in
the `:root` block at the top; the rest of the file refers to those and nothing
else, so a new theme is a new `:root` block rather than a hunt through the
rules. Edit and reload — there is no build step to run.

The graph pane stays pale in both colour schemes on purpose: label ink and
group colours are computed for contrast against a pale page (`src/color.janet`)
and baked into the SVG, which cannot know the page's theme. The dark theme
inverts the whole SVG rather than trying to re-colour it.

## Tests

```bash
./test/run
```

500 assertions (plus 82 for the terminal emulator, under node), no test
framework — the harness is 70 lines in
`test/harness.janet`, because a dependency is a dependency. It runs against
the **vendored** runtime, not whatever `janet` is on PATH: a green run against
a different interpreter than the one that ships here would not mean much.

The colour values are checked against what the Python tools produce for the
same inputs, and the Swift scan was diffed edge-for-edge against
`swiftdepgraph.py` on otto-ios: 26 nodes, 51 edges, identical. Several tests
exist for bugs that were real during the port — an `extension` declaring a type
it doesn't own, `import struct Foundation.Data` declaring `Foundation`, per-line
error messages arriving as `null`.

## Developing it from inside

```bash
./visualize ~/code/project
# ...
#   repl: nc -U /tmp/visualize-1a2b3c4d.repl.8770.sock

./repl        # connects to the newest repl socket; or pass the path you mean
```

Every run hosts a repl on a unix socket — the Swank arrangement, because the
stock stdin repl would freeze the event loop while its prompt waited, and
because Janet compiles defs to constants, so redefinition only reaches
compiled callers when `*redef*` is switched on **before** anything compiles.
That is why dev mode is decided at launch — on by default, `--no-dev` to opt
out — and not a runtime toggle. The socket name carries the server's port,
so the live server and a sandbox developing it, sharing one project root,
each keep their own.

There is also a **repl window** on the page itself, beside the harness window
— the same terminal pane, running `./repl` against that server's own socket.
It only exists in dev mode, since without one there is nothing to connect to.

Connect and you are in the server's own image: every module under its prefix,
every def in `src/core.janet` by name. From there:

- **Hot reload:** edit a file, `(dev/reload "scan")` — re-evaluated into the
  module's *live* environment, so every caller sees the new definitions
  immediately. In-memory state survives, which is the point: the pty already
  survives restarts by living in the supervisor, and this covers the rest.
- **Post-mortem:** a request that crashes leaves its fiber — stack *and
  locals* — in `dev/crashed`. `(dev/attach 0)` opens the core dot-command
  debugger on it: `(.stack)`, `(.frame 1)`, `(.locals)`, `(.source)`.
- **Breakpoints:** `(debug/fbreak scan/scan 0)` marks live bytecode; the next
  request to cross it parks in `dev/parked` with its client waiting while
  every other request keeps serving. `(dev/attach id)` inspects it
  mid-flight, `(dev/continue id)` lets it finish.
- An error typed *at* the repl drops the connection straight into that same
  debugger, like `janet -d` does on stdin.

The socket is the security boundary: created `0600`, keyed to the project
like the supervisor's, and never a TCP port — this endpoint evaluates
whatever connects, and 127.0.0.1 is not a boundary (see the token note
above).

## Notes on the picture

- **Arrows point the dataflow way.** `A -> B` means B depends on A, so the
  arrowhead lands on the file doing the importing. That is pydeps' direction,
  which means these graphs sit beside the Python ones without being a trap.
- **A name declared by several files is dropped, not resolved.** Nothing short
  of a type checker can say which `ContentView` a third file meant. Guessing
  draws a confident edge that is wrong half the time.
- **A node left with no edges stays on the graph.** It says "this is here and
  nothing you are looking at uses it", which is a fact about the picture you
  asked for rather than a defect in it.
- **Outlines, not fills, by default.** A wall of saturated boxes is harder to
  read the *edges* over, and the edges are what a dependency graph is for.
