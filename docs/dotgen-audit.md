# The dot audit, second pass

What graphviz's dot has, what this layout has, and — for everything both
have — how the implementations differ. Written 2026-08 after the first
audit's conclusion was tested and failed; this one starts from the evidence
that forced the rewrite, because the method matters as much as the
inventory: **every comparison here is two renders of the same tree**, and
every claim about a pass names the commit or file that carries it.

The first audit survives in git history (`05c1d99` and before). Its
factual sections were sound; its conclusion — that network simplex ranking
was "the one remaining difference that matters" — was wrong, and the way it
was wrong is now the most useful thing in this document.

---

## 1. What prompted the second pass

The picture from the start of the dotgen work read better than the picture
after six ports of dot machinery. That was checkable. The screenshot pinned
to commit `ff9254e` (by its line counts: layered 1523, svg 534), and every
default-path layout commit since was rendered **against that same tree** —
the tool draws itself, so before/after of any commit are different graphs,
and only a fixed tree makes the algorithm the only variable.
`tools/overlap.janet` takes an SVG file for exactly this purpose now.

The strip, all on the 42-edge tree of `ff9254e`:

| commit | what it did | node overlap | crossings | width | src.term box |
|---|---|---|---|---|---|
| ff9254e | (the screenshot) | 1/2/5 | 4 | 1117 | **2 ranks** |
| 23265bd | splines, fanned arrivals | 1/2/4 | 4 | 1117 | 2 ranks |
| 2e97405 | rank by relaxation | 0/1/2 | 2 | 1027 | **3 ranks** |
| 13bc90a | priority in coordinates | 0/2/5 | 2 | 1078 | 3 ranks |
| db47194 | transpose | 0/3/5 | 2 | 1057 | 3 ranks |
| e534672 | mincross loop | 0/3/5 | 2 | 1057 | 3 ranks |
| daf5a09 | corridors | 0/3/5 | 2 | 1057 | 3 ranks |
| d8f7d0b | the spline router | 0/3/5 | 2 | 1057 | 3 ranks |

Two things are visible at once. The metrics **improved monotonically** —
and the picture broke at `2e97405`, where `src/term/client` dropped a rank
below its sibling and the group box grew from two ranks to three. The tall
box is a wall; every long edge on that side has detoured around it since.
That detour is the one the corridors measured, gap-widening worsened, and
concentrate, simplex and the aux graph all failed to fix. **Six ports
chased a cost one tie-break created.** No metric caught it because a group
box is not an ellipse: edges routed around it cross nothing a scorer
counts.

### The cause, precisely

For a sum of absolute distances the minimiser is an interval, not a point.
A node with one parent at rank 0 and one child at rank 6 pays the same
total edge length at every rank from 0 to 6. The relaxation took
`(neighbours (div n 2))` — the upper median — which chooses an end of that
interval the objective is indifferent about. `client` (parent `json` high,
child `core` low) was indifferent across nearly the whole drawing, and the
snap moved it away from its siblings for zero gain.

### The fix (`d5f42b8`)

Within the interval the edges leave free, do not drift: a node stays put
unless staying costs actual length, and a group member spends the freedom
on its siblings. The box went back to two ranks on both trees, the S-weave
around the tall box disappeared, and the blend that paid edge length for
group compactness went with it — it existed to fight this same drift.

### The law this keeps proving

Three times now, a change improved a measured objective and damaged the
picture: **concentrate** (corridor count, width), **simplex** (total edge
span, −24%), **the aux graph** (drawn width, −18%). And once the reverse:
the tie-break fix *worsened* the scorer's counts slightly (the wide box
crowds its own rank) and repaired the drawing. Width, span, corridor count
and even crossing counts all measure **packing**. None measures whether a
reader can follow a line. On a sparse dependency graph with whitespace to
spare, packing is the wrong thing to buy — and dot's arranging passes were
tuned for graphs dense enough that it isn't. The ports that paid off are
the ones that **draw** (transpose, the spline router); the ones that
**arrange** (ranking, x-objectives, concentrate) measured better and read
worse, every time.

The standing rule that falls out: *a layout change is judged by rendering
the same tree before and after, with the scorer for regressions and the
eye for the verdict.* The strip above is the template.

---

## 2. The pipeline, side by side

| stage | dot | here | file |
|---|---|---|---|
| cycle breaking | DFS, reverse back edges (`acyclic.c`) | DFS, reverse back edges | `layered.janet` `back-edges` |
| ranking | network simplex (`rank.c`, `ns.c`) | longest-path + interval-aware relaxation; simplex ported, unwired | `rank`; `simplex.janet` |
| ordering | wmedian + transpose loop (`mincross.c`) | barycentre sweeps + transpose + sift | `order`, `transpose`, `sift` |
| x placement | aux-graph network simplex (`position.c`) | isotonic constraint solve per rank; aux ported, flagged | `settle`, `place-x`; `aux.janet` |
| routing | boxes + funnel + bezier fit (`dotsplines.c`, `routespl.c`, pathplan) | corridors + funnel + bezier fit | `funnel.janet`, `fit.janet`, `svg.janet` |
| clusters | recursive sub-layouts, collapsed for mincross | one global layout with group constraints | throughout `layered.janet` |

---

## 3. Feature by feature, where the implementations differ

### Cycle breaking — same idea, same mechanism

Both walk depth-first and reverse exactly the edges that point back into
the open stack. Both draw a reversed edge in its original direction
afterward, so a cycle appears as an edge pointing back up the page.
Differences are trivia: dot merges parallel edges while breaking; we have
none to merge (one import edge per file pair by construction). Self-edges
are ignored by both rankers; dot draws them as loops beside the node, we
do not draw them at all — a file importing itself is a parser artifact,
not information.

### Ranking — different optimum, deliberately

dot runs network simplex to the true minimum of total weighted edge
length: feasible tight tree, cut values maintained incrementally through
low/lim intervals, leave/enter exchange, then a balance pass. Most of its
1400 lines are the incremental cut-value bookkeeping.

Ours is longest-path for a feasible start, then coordinate-descent
relaxation: each node moves within the window its edges allow, toward the
**interval** between its middle neighbours (see §1 — the interval, not the
upper median, as of `d5f42b8`), with group members spending free slack on
their siblings. Per-component, normalised after; no per-edge weights or
minlens (nothing in a dependency graph asks for them).

The full simplex is ported (`simplex.janet`, ~230 lines, recomputing cut
values rather than maintaining them) and **left unwired on evidence**: its
optimum packs nodes onto fewer, fuller ranks, and on this graph every
measurement of the packed drawing is worse (last full matrix: 2/4/7 with
14 crossings against the default's 2/2/4 with 8). A dependency graph wants
its ranks loose. The relaxation reaches a slightly worse number and a
better picture, which is the trade this tool wants — and with the interval
fix, its remaining choices are exactly the ones the objective is
indifferent about.

dot also supports `minlen`, per-edge `weight`, `same`/`min`/`max` rank
constraints, and edge labels that become ranking nodes. All unused here;
`weight` would matter only if some imports should pull harder than others,
which nothing currently asserts.

### Ordering — dot's loop, our scoring

dot: initial order by BFS, then up to `MaxIter=24` iterations of weighted
median (`wmedian`, with the two-sided interpolated median for even
adjacency lists) alternating sweep direction, `transpose` after every
sweep (greedily swapping adjacent pairs, taking ties on reversed passes),
keep the best ordering seen, stop when crossings improve by less than
.995× per iteration.

Ours: the same alternating structure (`order`, resumable via a pass
number so the outer loop and the seating pass share one alternation —
restarting it from zero each call was a measured bug), scored by
**barycentre** rather than median, which the sparse-graph literature
prefers and our own numbers confirmed; `transpose` ported faithfully
including the reverse-pass tie-taking (`db47194`, five tangles fixed);
`sift` for the moves adjacent swaps cannot see; a keep-the-best loop
(`e534672`). Groups are scored as one node so a crossing into a box costs
what it reads like. The convergence constant differs (we run a fixed
budget, `:sweeps 8`); on 35 nodes the difference is noise.

**Flat edges do not exist here** — leveling forbids same-rank edges by
construction, so dot's entire flat-edge machinery (`flat_search`,
adjacency ranks, flat crossing counts) has no counterpart and needs none.
The first audit got this wrong and the correction stands: 0 of 45 edges.

### X placement — one constraint solve, not one graph

dot builds a second graph whose ranks are x-coordinates — separation as
hard min-length edges, straightness as weighted slack nodes (weights
1/2/8 by bend-count) — and runs the ranker sideways. One objective for
the whole drawing; its known character is aggressive horizontal
compaction.

Ours (`settle`) is an isotonic block-merge solve **per rank**: passes
state desires (a node under its neighbours' median, a bend under its
chain, priorities so a bend outranks a node), bounds state what may not
overlap, and the solver decides — non-overlap is a property of the
output, not of pass order. The whole-drawing coupling dot gets from its
one graph, we approximate with `cohere` (chains pull their bends
together across ranks) and `reseat-bends`/`untangle-bundles`.

The aux formulation is ported (`aux.janet`, with the cluster walls and
keepout constraints from `position.c`) and flagged off: it draws ~15%
narrower and measurably worse everywhere else (1/4/11 against 2/2/4 at
last matrix). Same law as ranking — compaction is packing.

### Routing — their algorithm, a tenth the code, one extra preference

dot routes **every** edge as a spline through a corridor of boxes
(`maximal_bbox` per bend), calling `Pshortestpath` (funnel over a
triangulated polygon, ~950 lines with its support) then `Proutespline`
(piecewise bezier fit, subdividing on failure), through the 1000-line
`routespl.c` wrapper.

Ours: corridors fall out of the layout (`daf5a09` — left/right free span
per bend, per rank), and because every corridor is a strictly y-monotone
stack of axis-aligned boxes (measured: 18 of 18), the funnel runs
directly on box edges — no triangulation, no visibility graph
(`funnel.janet`, ~100 lines). The fit is the same Hoschek/Plass
least-squares with **fixed end tangents** (the renderer's fan angles
survive routing), containment checked by sampling where dot clips
analytically, subdividing at the worst violation (`fit.janet`, ~230
lines). Nil on failure, and the caller keeps its previous drawing — the
router is not allowed to make things worse.

The extra preference dot does not have: **an edge that can run straight,
runs straight** — checked against nodes, foreign group boxes, and other
edges' lines — and a blocked one-rank edge bows as a quadratic, trying
both sides at increasing depth. dot splines everything; on a sparse
graph, straight lines are information (28 of 48 edges here run straight).

### Clusters vs groups — theirs are subgraphs, ours are constraints

This is the largest structural difference in the codebase. dot lays out a
cluster as a **separate recursive layout** — collapsed to a single node
for the outer graph's ordering, expanded and laid out internally, then
installed. Containment is guaranteed by construction; the cost is that an
edge crossing a cluster boundary is routed between two coordinate systems.

Here a group is three soft constraints inside the one global layout:
members pull toward the sibling median in ranking (free-slack only, since
`d5f42b8`), a group scores as one node in ordering and stays contiguous on
its ranks, and boxes are drawn around wherever members ended up (with the
walls/keepout as hard constraints only in the flagged aux path). Cheaper,
honest about what a group is in a dependency graph (a labelling, not a
territory) — but containment is emergent, and the tall-box episode shows
the failure mode: a single ranking choice can stretch a box no later pass
can shrink.

### Components and loose nodes

dot connects components with invisible zero-weight edges and lays out one
graph (`connectGraph`); separate graphs are packed afterward by `pack`.
Here components rank independently and normalise to a shared top;
completely unconnected nodes go on a **shelf above the drawing**
(`shelve`), which is why `config` and the parsers read as a legend rather
than as participants. dot has no shelf; its loose nodes float at rank 0
inside the drawing.

### Drawing

Ellipses only, sized by line count; dot has the full shape/record/port
library, none of which a file-dependency picture wants. Arrowheads land
on the ellipse via `on-ellipse` with **fan spread by arrival angle** —
multiple edges into one node share the boundary instead of stabbing one
point; dot achieves the same with port assignment. Both clip edges to
node boundaries. Labels: node labels only, no edge labels (dot's edge
labels become virtual ranking nodes — a real feature with real layout
cost, and nothing here has text to put on an edge).

---

## 4. dot features with no counterpart here, with verdicts

| feature | verdict |
|---|---|
| network simplex ranking | ported, unwired on evidence (`simplex.janet`) |
| aux-graph x placement | ported, flagged off on evidence (`aux.janet`) |
| concentrate | ported, reverted on sight (`63ea7fc` — "this graph looks noticeably worse") |
| flat edges | cannot exist here; needs nothing |
| edge labels, ports, shapes, records | no use in a file graph |
| self-loop drawing | scan artifact, deliberately undrawn |
| multi-edge bundling | one edge per pair by construction |
| `minlen` / `weight` / rank constraints | nothing asserts them yet; add with a use, not before |
| rankdir (LR/BT/RL) | genuinely absent; LR might suit wide graphs someday |
| `pack` for separate graphs | shelf covers the actual case (loose nodes) |
| size/ratio fitting | the page scales the SVG; nothing lost |
| incremental cut values, `nslimit`, `mclimit` | performance machinery for sizes this tool does not reach |

What we have that dot does not: the straight-line preference with the
obstruction check, the bow-with-side-choice for blocked short edges, fan
arrivals by angle, the shelf, groups-as-constraints, and the scorer
(`tools/overlap.janet`) that reads the finished SVG — file in, counts and
named offenders out — which is the instrument every conclusion in this
document rests on.

---

## 5. Where it stands

At this tree (48 edges), default path: **0 cross a node, 0 clip, 4 near,
9 edge-pair crossings, 1152×796** — with the group shapes right, which
the strip showed is the thing the counts cannot see.

The audit first shipped with two named crossers, and resolving them split
cleanly along the line this document keeps drawing:

- `src_color → src_config` was **real**, and the defect was a conflation:
  the bow fallback for a blocked one-rank edge compared only its two
  gentlest arcs, never noticing that the straight line it had rejected
  entered *no node at all* — it was refused for crossing another edge's
  line, a different and lesser sin. The fallback now scores every
  candidate, straight line included, by node-penetration alone, and the
  least wins. A crossing in open space is a blemish; a line through a
  node is a lie about the graph.

- `src_layout → src_graph` was a **phantom**: the scorer's overlap walk
  read a bezier's control polygon as the curve, and the polygon dips
  where the curve does not. The drawn edge grazed `dev` at 95% of its
  radius — touching, legal — and was indicted for crossing it. The scorer
  now flattens the real curves for every count. (Overlap columns in the
  §1 strip predate that fix and can over-report on curved edges; the
  strip's verdict rests on box ranks and crossings, which were always
  honest.)

A scorer that indicts the wrong edge sends whoever reads it to fix the
wrong code. Half of this fix was fixing the instrument.

The two flagged ports stay flagged. The audit's productive direction is
unchanged from §1: improvements to how edges are **drawn** keep paying;
improvements to how nodes are **packed** keep costing. Parity with dot was
the right goal for the router and the wrong goal for the arrangement, and
the tool now measures the difference on every change.
