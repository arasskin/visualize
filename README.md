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

A C compiler, and graphviz's `dot` on PATH:

```bash
brew install graphviz
```

That is the whole list. **The Janet runtime is in this repository**, as the
official amalgamated source in `vendor/janet/` — so a clone builds offline,
with no package manager, no lockfile, and no `node_modules`, and builds the
same runtime a year from now.

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

The file is `visualize.conf`, written into whatever directory you point at.
It is created on first run, so there is something to edit rather than a blank
pane.

```lisp
(show-only ~)              ; narrow to our own files — the everyday setting
(hide ~.Tests)             ; drop it, and every edge touching it
;;(hide ~.Tests)           ; comment it out to put it back
(hide ~.Clip.)             ; trailing dot: its contents, not itself
(group ~.Clip)             ; box its members, next palette colour
(group ~.Shared #a54a4a)   ; ...or a colour you name
(fill-color)               ; fill nodes instead of outlining them
(show-lines)               ; write each file's line count on it
(show-lines-coloring)      ; ...and shade by size instead of by edges
(font "Helvetica")         ; draw it in something else
(harness claude)           ; what the terminal window runs -- or (harness pi)
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
./pane repl '(dev/reload "dot")'   # evaluate in the live image
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
src/dot.janet       prefix matching, filtering, and the DOT that comes out
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
test/               401 assertions, no framework
bin/janet           the compiled runtime (gitignored build artifact)
```

## Theming

`web/style.css` is vanilla CSS. Everything themeable is a custom property in
the `:root` block at the top; the rest of the file refers to those and nothing
else, so a new theme is a new `:root` block rather than a hunt through the
rules. Edit and reload — there is no build step to run.

The graph pane stays pale in both colour schemes on purpose: graphviz draws
node labels in dark ink and has no idea what the page is doing.

## Tests

```bash
./test/run
```

277 assertions (plus 40 for the terminal emulator, under node), no test
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
