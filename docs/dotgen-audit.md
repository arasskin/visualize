# Our layout against dotgen, pass by pass

An audit of `src/layout/layered.janet` (1,657 lines) and `src/layout/svg.janet`
(633) against graphviz's `lib/dotgen` (7,589 lines across the passes that
matter), done to answer one question: what is structurally different, and is
the difference why long edges detour around group boxes?

The short answer is that three of our four passes are the same algorithm with
fewer refinements, and one — **coordinate assignment** — is a different
algorithm entirely. That one is the cause of the routing complaint.

## The pass that is genuinely different: x-coordinates

**dotgen** (`position.c:127`) does not have a coordinate pass in the sense we
do. It builds an *auxiliary graph* and runs the ranking algorithm on it a
second time, sideways:

```c
create_aux_edges(g);
if (rank(g, 2, nsiter2(g))) { ... }   /* LR balance == 2 */
set_xcoords(g);
```

The auxiliary graph encodes every x-coordinate desire as an edge with a
*weight* and a *minimum length*:

- `make_LR_constraints` — one edge per adjacent pair in a rank, minimum length
  = the separation they need. These are the non-overlap constraints.
- `make_edge_pairs` (`position.c:327`) — for every real edge, a **slack node**
  with two aux edges, one to each endpoint, carrying the edge's weight. Pulling
  those two aux edges tight is exactly "make this edge vertical".
- `contain_nodes` / `keepout_othernodes` / `separate_subclust` — cluster
  containment, also as weighted edges.

Then network simplex finds the assignment minimising total weighted aux-edge
length. **Every desire competes in one optimisation**, with weights deciding
who wins.

**Ours** (`place-x`, `layered.janet:911`) is iterated local relaxation: each
sweep computes a desire per node, hands the row to `settle`, and `settle`
solves *that row* optimally with block merging. Rows are solved one at a time,
in sequence, repeatedly.

The difference that matters is not quality of the row solver — ours is a
correct isotonic solver — it is **scope**. `settle` cannot trade a worse
position on rank 3 for a better one on rank 5, because it never sees rank 5.
Network simplex over the aux graph sees all of it at once.

### Why this produces the detour

A bend on the `src/json -> src/core` chain wants x=14 and has a ceiling of 5.
It is *ordered* after the `src.term` group on its rank, and `settle` honours
order above every bound — a block cannot start behind the one before it — so
the bend lands at 247, the far edge of the group's box. The edge swings out
around the term box and back.

In dotgen this cannot happen in the same way: the bend's aux edges to its two
endpoints carry the edge's weight, and a 240-unit stretch of both of them is
enormously expensive against the ordering constraint's minimum length. The
optimiser would move the *group* before it moved the bend that far.

We tried two local fixes and both failed, in instructive ways:

1. **Bends take the nearer side of a box.** Correct in itself; no effect,
   because order still beats bounds at seating time.
2. **A drift tiebreak in `sift`** — prefer, among orderings that tie on
   crossings, the one putting a bend nearest its line. This *fixed the
   detour* (the `src/stamp` chain went from a 254-unit excursion to
   essentially straight, and the drawing narrowed from 1078 to 828) and
   **broke overlap**: 0 crossings became 4, with 10 outline clips. The
   orderings it overrode were not arbitrary — they were holding edges in
   clear channels.

That second result is the audit's most useful finding. **Straightness and
clearance are in tension, and our pipeline cannot trade them** because they
are decided in different passes: clearance in ordering, straightness in
placement, with no shared objective. dotgen resolves them together, in one
optimisation, weighted.

## The passes that are the same algorithm, with fewer refinements

### Ranking

Both break cycles by DFS back-edge reversal (`acyclic.c` / our `back-edges`)
and both then want minimum total weighted edge length.

- **dotgen** (`rank.c`): network simplex on a tight spanning tree, with cut
  values maintained incrementally and edges swapped across the negative ones.
- **ours**: relaxation — each node moves to the median of its neighbours,
  clamped so it cannot invert an edge, until nothing moves.

Same objective, different solver. On this repo's graph they agree; on a graph
with a long chain competing against a wide fan they may not, and simplex would
be right. **Not currently a visible defect.**

Ours additionally weights a group as a neighbour (2:1) to keep members on
nearby ranks. dotgen does this with cluster containment in the aux graph
instead, which is stronger.

### Ordering

Both do the wmedian/transpose loop from the Sugiyama paper.

- **dotgen** (`mincross.c`): up to `MaxIter` passes with `save_best` /
  `restore_best`, a convergence ratio of `.995`, and a `MinQuit` patience
  counter (`mincross.c`, the `mincross` loop). It keeps the best ordering
  *ever seen* and restores it if later passes are worse.
- **ours**: fixed sweeps, then `sift` (try every node in every slot, keep
  strict improvements), then `cohere` for group contiguity.

**We have no save/restore.** Our passes are individually monotone — `sift`
only takes strict improvements — so we cannot regress, but we also cannot take
a worse intermediate ordering that leads somewhere better, which is exactly
what dotgen's restore-best exists to allow.

dotgen also handles **flat edges** (both endpoints on one rank) as a separate
pass with its own cycle-breaking (`flat.c`, 336 lines). We have none: a
same-rank edge is drawn as a straight line and hoped for.

### Routing

- **dotgen** (`dotsplines.c`, 2,309 lines): builds an explicit **box corridor**
  per edge — the free space between the nodes on each rank it crosses — and
  calls `routesplines` (in `pathplan`) to fit a piecewise bezier inside that
  polygon. The corridor is the guarantee: a spline that stays in the boxes
  cannot hit a node.
- **ours** (`path-through`, `svg.janet:140`): sample the candidate line, test
  it against every node, box and other edge; if it hits, use the reserved
  bends; if there are no bends, bow the curve and try increasing depths.

Ours is *checking* rather than *constructing*, which is why it works (measured:
0 of 44 edges touch a node they do not connect) and why it cannot do better
than the bends it was given. When the bends are in the wrong place, the check
has nothing to fall back on except a wider bow.

## What dotgen has that we have no version of

| feature | dotgen | ours |
|---|---|---|
| flat (same-rank) edges | `flat.c`, cycle-broken and routed | drawn straight, unmanaged |
| self edges | loops placed beside the node | skipped entirely |
| ports (edge attachment points) | full port model | fan by arrival angle |
| edge labels as nodes | virtual node on an odd rank | none |
| clusters laid out recursively | `cluster.c`, own mincross per cluster | groups as ordering + box |
| leaf-node packing | `expand_leaves`, `make_leafslots` | none |
| aspect-ratio targeting | `set_aspect`, ratio/size attrs | none |
| concentrated edges | `dot_concentrate` | none |

Most of these do not matter for a dependency graph. **Flat edges do** — a
same-rank dependency exists in real projects and we currently draw it as a
chord across the rank.

## Recommendation

The routing complaint is not fixable by another local patch. It needs the
placement pass to see the whole graph at once, and the honest way to get that
is the aux-graph formulation: express separation, straightness and containment
as weighted constraints, and solve them together.

That is a rewrite of one pass, not of the layout — `rank` already exists and
would be reused on the aux graph, which is exactly what dotgen does. It is the
smallest change that removes the tension rather than trading one side of it
against the other.

If we go further and port dotgen file by file, the order that keeps a working
picture at every step is: `position.c` (aux graph + reuse our ranker),
`flat.c` (the missing feature), `mincross.c` (save/restore + its convergence
rule), then `dotsplines.c` (box corridors) last, since our checking router is
adequate until the bends are right.

## Postscript: why the detour survived five ports

Recorded after porting the aux graph, cluster walls, transpose, the mincross
loop and box corridors, none of which moved the edge that prompted the audit.

The corridors gave the number that explains it. A bend's corridor is the free
space it has on its rank -- from the right edge of the thing ordered before it
to the left edge of the thing after. On the rank where the `src/stamp ->
src/core` chain swings out, that corridor is **eight pixels wide**, and across
the graph **20 of 37 bend corridors are under twenty pixels**. There is no
space to route into, so no router can help.

Widening the gaps does not create any. Raising `bend-gap` from 3 to 26 and
`bend-width` from 8 to 14 makes it *worse* -- 26 narrow corridors instead of
20, on a drawing grown from 1162 to 1364 pixels -- because a corridor is the
gap *between neighbours*, and giving every bend more personal space moves the
neighbours out by the same amount. Every bend gets more room of its own and no
more room to move.

The rank census says what is actually there:

```
rank 0:  8 nodes +  0 bends
rank 1:  7 nodes +  8 bends
rank 2:  7 nodes + 10 bends
rank 3:  3 nodes + 12 bends
rank 4:  4 nodes +  7 bends
```

The crowded ranks are crowded with **pass-through edges, not nodes**. Twelve
long edges cross rank 3 on their way to `src/core`, which has thirteen
dependents. The detour is those twelve edges competing for one rank's width.

So the remaining lever is not in any of dot's passes. It is either:

- **fewer things per rank** -- real network simplex ranking might place some
  of `src/core`'s dependents closer to it, shortening the chains that cross
  everything; or
- **fewer chains** -- which is a drawing decision rather than a layout one.
  dot has `concentrate` for exactly this: merge parallel runs into one line
  and split them at the end. Thirteen edges into one node drawn as one bundle
  that fans at the last rank would empty the middle ranks completely.

`concentrate` is the honest next step, and it is a feature rather than a
parity fix -- dot has it, we do not, and on a dependency graph where one
module is imported by everything it is the difference between a readable
picture and a bundle of wires.

## Feature inventory

Everything `lib/dotgen` does, and whether we do it. Written after porting
concentrate, which was the last item on the "would visibly help" list.

### Have, and equivalent

| feature | dot | ours |
|---|---|---|
| cycle breaking | `acyclic.c`, DFS back edges | `back-edges`, same method |
| ranking | `rank.c`, network simplex | relaxation to the same objective |
| ordering: median sweep | `mincross.c` wmedian | `order` |
| ordering: transpose | `mincross.c` transpose | `transpose` (monotone half) |
| ordering: keep-the-best | save/restore, .995, patience | the mincross loop |
| coordinates | `position.c` aux graph | `settle` + relaxation; aux graph behind a flag |
| cluster containment | `contain_nodes` and friends | walls in `aux.janet`; ordering + box otherwise |
| virtual nodes for long edges | chains of vnodes | bend chains |
| concentrate | `conc.c` | tried and reverted -- see below |
| splines | `dotsplines.c` + pathplan | Catmull-Rom through the bends |
| box corridors | `maximal_bbox` | computed, carried, unused by the router |

### Have, but weaker

| feature | dot | ours |
|---|---|---|
| ranking solver | exact (simplex) | relaxation; agrees here, may not elsewhere |
| ordering escape | takes equal-cost swaps | measured: costs a clip, left off |
| spline routing | fits a bezier inside the box chain | checks a curve and bows it if blocked |
| edge attachment | full port model | fan by arrival angle |

### Do not have

| feature | what it is | worth it? |
|---|---|---|
| flat edges | `flat.c`, same-rank edges cycle-broken and routed | **yes** -- real in any project, currently drawn as a chord |
| self edges | a loop beside the node | minor; we skip them |
| edge labels | a virtual node on an odd rank | no -- we do not label edges |
| recursive clusters | `cluster.c`, own mincross per cluster | no -- our groups are one level |
| leaf packing | `expand_leaves`, `make_leafslots` | maybe -- would tighten the parser row |
| aspect targeting | `set_aspect`, ratio and size | no -- the page zooms |
| multi-edges | parallel edges bowed apart | no -- the scan emits one per pair |
| ports | attach at a named point on the node | no |

Nothing left on the "do not have" list would visibly change this graph. See
the note on flat edges below for the item I previously claimed would.

## Concentrate: tried, measured well, looked worse, reverted

Worth recording because the metrics said yes and the picture said no.

Bundling the twelve chains into `src/core` halved the narrow corridors (20 to
11) and took the drawing from 1162 to 955 pixels -- better than any of the
five previous attempts managed. It also made the graph harder to read, which
is the only thing that matters.

Twelve thin lines that stay thin, spread out and individually followable beat
one thick rope, however much narrower the rope makes the picture. The bundle
became the most visually dominant object in the drawing, it crossed `src/state`
and `src/faults` on its way down, and it pushed the nodes around it into a
worse arrangement.

**The lesson is about the metrics, not the feature.** Width and corridor width
measure PACKING. Nothing here measured legibility, so a change that traded
twelve readable lines for one dense one scored as an improvement. `concentrate`
may still be right for a graph with genuinely parallel structure -- several
edges running the same route between the same two regions -- but on a fan into
one popular node it is exactly the wrong shape.

## Flat edges: why there are none, correcting an earlier claim

I listed flat edges -- both endpoints on one rank -- as the last missing
feature that would visibly change a real graph. Measured on this repo:
**0 of 45 edges are flat**, and that is structural rather than luck.

Longest-path ranking assigns `layer(to) = layer(from) + 1`, so every edge it
processes spans at least one rank by construction. The relaxation that follows
clamps each node strictly below its parents and strictly above its children,
so it cannot reintroduce one either. Levelling really does destroy flat edges.

Two things escape that guarantee, and neither is common:

- **Back edges.** Cycle-closing edges are set aside before ranking and drawn
  afterward, so nothing forces their endpoints onto different ranks. In
  practice the rest of the cycle pushes them apart.
- **Unreachable knots.** Nodes the Kahn queue never reaches -- a cycle the
  back-edge pass did not fully break -- keep their initial rank of 0. Several
  such nodes share rank 0, and any edge among them is flat.

`dot` has a third source we do not: `rank=same`, an explicit user constraint
that forces nodes onto one rank. That is most of what `flat.c` exists to
service.

So flat-edge handling is not worth building here. If flat edges ever appear
in this tool's output it means the back-edge pass left a knot unbroken, and
the useful fix is better cycle breaking rather than a flat-edge router.

## Feature by feature, measured against dot on the same graph

Going through what we HAVE rather than what we lack, since the missing list
turned out to be empty. Same 35-node graph, same config, dot 15.1.0.

### Ranking — a real gap, and the only one

| | dot | ours |
|---|---|---|
| ranks used | 6 | 7 |
| nodes per rank | 1, 5, 8, 6, 6, 9 | 6, 8, 7, 8, 3, 4, 1 |
| total edge span | **68 ranks** | **84 ranks** |
| longest edge | 4 ranks | 5 ranks |

Twenty-four per cent more total edge length, an extra rank, and a lopsided
tail: our lower ranks hold 3, 4 and 1 nodes where dot's hold 6, 6 and 9.

**Our ranking is at a local optimum.** Checked directly: no single node can
move to a better rank without inverting an edge — zero of thirty-five could
improve. The relaxation has done everything a relaxation can do.

That is exactly the difference the audit predicted. Network simplex maintains
a tight spanning tree and swaps edges across negative cut values, which moves
WHOLE SUBTREES at once; coordinate descent moves one node at a time and cannot
reach an arrangement that requires several nodes to move together. Our answer
is locally optimal and globally 24% worse.

### And it explains everything downstream

Slack is the direct cost: **17 edges span more than one rank, carrying 37
ranks of slack between them**, worst being `src/stamp -> src/core` at 4. Every
unit of slack is a bend, every bend needs a column, and the columns are what
crowded the ranks until corridors measured eight pixels wide.

So the chain is: relaxation leaves 24% more edge length than simplex → more
slack → more bends → crowded ranks → no room to route → the detour that
started this audit. Five ports downstream of ranking could not fix it because
the cost was already paid upstream.

### The other passes, for completeness

- **Ordering.** Crossings are what this optimises and both reach a good
  answer; we measure zero crossings in the finished picture. No visible gap.
- **Coordinates.** Ours is a correct isotonic solver per rank; the aux-graph
  port (behind `VISUALIZE_AUX`) draws narrower but currently crosses nodes.
  Not the bottleneck.
- **Routing.** Zero edges touch a node they do not connect, measured. Better
  than parity on the metric that matters, and only because the checking router
  refuses to draw a bad line rather than because the bends are well placed.

### Conclusion

**Network simplex ranking is the one remaining difference that matters.** Not
because ranking looks wrong, but because everything downstream inherits its
slack. It is `rank.c` -- feasible tree, cut values, leave/enter edge, balance
-- and it is the port with a measurable target: 84 down to 68.

---

## Postscript: the conclusion above was tested, and it was wrong

The section that ends this audit says network simplex ranking "is the one
remaining difference that matters", and gives a chain of reasoning for it:
relaxation leaves 24% more edge length → more slack → more bends → crowded
ranks → no room to route → the detour. Every link in that chain is measured
and each one is true. The conclusion still did not hold.

### What was predicted

Simplex was ported (`src/layout/simplex.janet`) and worked — total edge span
85 → 82, better-balanced distribution — but the drawing got worse, so it was
left unwired with a stated reason: dot can afford a tight ranking because it
fits splines inside box corridors, ours could only check a straight line and
bow it, so the two had to improve together. That reason was a prediction, and
`docs/pathplan-scope.md` scoped the router that would test it.

### What happened

The router was built: `funnel.janet` (shortest path through the corridor) and
`fit.janet` (beziers fitted inside it), about 290 lines against dot's 2,684,
because every corridor here is a y-monotone stack of axis-aligned boxes.

It works. Sixteen multi-rank edges route through it, near-misses on the
shipping graph drop from 3 to 1, and it declines nothing.

Simplex ranking is still worse — and **the router is not what fails**. Under
simplex it fits 13 of 13 corridors and falls back on none. Every curve stays
inside the box it was handed. The boxes are in the wrong places.

### The four combinations, one graph, one router

| ranking | x-placement | crosses | clips | near |
|---|---|---|---|---|
| relaxation | per-rank (default) | **1** | **1** | **1** |
| relaxation | aux graph (`VISUALIZE_AUX`) | 1 | 3 | 6 |
| simplex (`VISUALIZE_SIMPLEX`) | per-rank | 3 | 5 | 9 |
| simplex | aux graph | 5 | 10 | 15 |

Every dot pass added makes this graph worse, monotonically, and the two
combined are worse than either alone.

### What that actually means

Both ports are correct and both are optimal for what they optimise. Neither
optimises **legibility on a sparse dependency graph**, which is not the
objective dot was tuned for — dot's passes were built for graphs that are
denser and deeper than this one, where packing pays for itself.

This is now the third measurement in the same direction. Concentrate improved
corridor width and edge count and looked worse. Simplex improved total edge
span by 24% and looked worse. The aux graph draws 946 wide against 1161 and
looks worse. **Width, span and corridor count all measure packing. None of
them measures whether a reader can follow a line**, and on a graph with this
much whitespace available, packing is the wrong thing to buy.

The honest reading of the whole audit is that parity with dot was the wrong
goal for the passes that arrange the drawing. Where the port paid off is the
passes that DRAW it — transpose fixed five tangles, and the router removed
the wobble from every multi-rank edge — because those improve the picture
without contesting the space that makes it readable.

### If x-placement is tried next

It is the remaining suspect, since a corridor is only as good as the column
reserved for it and 20 of 37 were under 20px even with the looser ranking.
But `VISUALIZE_AUX` is dot's answer to exactly that and measures worse here,
so the thing to port is probably not the next dot pass. The measurement to
build first is one that scores **legibility** rather than packing — until
that exists, every one of these comparisons is decided by looking at the
picture, which is how the last three were caught.
