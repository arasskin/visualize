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
