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
visualize.janet     entry point: the server's two endpoints
src/scan.janet      walk the tree, read every file on all cores, build the graph
src/parser.janet    what a language spec is, and how one is run
src/parsers.janet   find the specs in src/parsers/ at runtime
src/parsers/        one file per language
src/pty.janet       a pseudo-terminal, via libc's forkpty through the FFI
src/harness.janet   the agent session, both halves: the owner (run as
                    `visualize --supervise`, outliving the server) and the
                    client the HTTP routes talk through
src/dot.janet       prefix matching, filtering, and the DOT that comes out
src/color.janet     the palette, the ramp, and WCAG-checked label ink
src/config.janet    the sandbox the config runs in
src/tilde.janet     rewriting ~ and #rrggbb past Janet's reader
src/http.janet      just enough HTTP for one browser on localhost
src/json.janet      just enough JSON for the browser protocol
web/term.js         a terminal emulator, in the ~25 sequences agents emit
web/                the page: vanilla HTML, CSS and JS, no build step
test/               236 assertions, no framework
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

236 assertions, no test framework — the harness is 70 lines in
`test/harness.janet`, because a dependency is a dependency. It runs against
the **vendored** runtime, not whatever `janet` is on PATH: a green run against
a different interpreter than the one that ships here would not mean much.

The colour values are checked against what the Python tools produce for the
same inputs, and the Swift scan was diffed edge-for-edge against
`swiftdepgraph.py` on otto-ios: 26 nodes, 51 edges, identical. Several tests
exist for bugs that were real during the port — an `extension` declaring a type
it doesn't own, `import struct Foundation.Data` declaring `Foundation`, per-line
error messages arriving as `null`.

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
