# Scoping a spline router

What it would take to fit curves inside the box corridors we already
compute — the missing half that keeps network simplex on the shelf.

## Why this is the blocker

Network simplex works (`src/layout/simplex.janet`) and improves the ranking
it was ported to improve: total edge span 85 → 82, rank distribution
`15 8 7 3 5 1` → `11 7 5 7 3 5 1`. Switched on, the finished picture gets
*worse* — one edge crossing a node and five clipping an outline, where the
relaxation's looser ranking yields none.

A better ranking packs nodes onto fewer, fuller ranks. dot can afford that
because it routes splines inside box corridors: hand it a crowded drawing and
it finds a path through. Ours checks a candidate line and bows it when
blocked, which needs slack in the drawing to work with. **The ranking and the
router have to improve together**, and the router is the half that is missing.

## What dot actually calls

`dotsplines.c` calls `routesplines` (in `lib/common/routespl.c`, 1,042 lines),
which calls exactly two things from `lib/pathplan`:

| function | file | lines | what it does |
|---|---|---|---|
| `Pshortestpath` | `shortest.c` | 448 | shortest path inside a polygon |
| `Proutespline` | `route.c` | 495 | fit a piecewise bezier to that path, inside barriers |

The rest of `lib/pathplan` (1,961 lines total) is support: `visibility.c`
(355) for the visibility graph, `triang.c` (150) for triangulation, `cvt.c`
(194) for polygon conversion, plus solvers and utilities.

## The measurement that shrinks the job

`Pshortestpath` works on an **arbitrary simple polygon**. It triangulates,
walks the triangle adjacency to find a channel, and runs the funnel algorithm
over that channel with a deque. That machinery — `triangulate`, `loadtriangle`,
`connecttris`, `marktripath`, `add2dq`, `splitdq`, `finddqsplit` — is most of
the 448 lines, and it exists because the polygon can be any shape.

**Ours cannot.** Measured: all 18 corridors on this tool's own graph are
strictly y-monotone stacks of axis-aligned boxes, one box per rank, each
strictly below the last. That is guaranteed by construction — a corridor is
built rank by rank from a bend chain, and ranks are ordered.

For a monotone stack of axis-aligned boxes the shortest path is the **funnel
algorithm directly on the box edges**, with no triangulation, no adjacency
walk, and no polygon conversion. It is the textbook "shortest path in a
channel" problem, roughly 80 lines.

## Estimate

| piece | dot | ours, given monotone box stacks |
|---|---|---|
| shortest path in the corridor | 448 + 150 + 194 | ~80 (funnel over box edges) |
| bezier fitting inside barriers | 495 | ~150 (fit, test, subdivide) |
| the `routesplines` wrapper | 1,042 | ~60 (we already have the corridors) |
| visibility graph | 355 | 0 — not needed for monotone channels |
| **total** | **2,684** | **~290** |

The wrapper is small because the expensive part of `routespl.c` is building
the box corridor from the layout, and `layered.janet` already does that and
hands it to the renderer.

## What it would buy, and the risk

**Buy:** network simplex switches on (one line in `rank`), and with it a 24%
better ranking and a more balanced picture. Beyond that, the router stops
being the constraint on every future layout improvement — the pattern through
five ports has been "measured better, looked the same or worse", and this is
the reason.

**Risk:** bezier fitting that fails to converge is the classic failure, and
dot's `splinefits` handles it by subdividing and retrying. Falling back to the
current checking router when a fit fails is cheap insurance and keeps the
worst case at today's picture.

**Verification is already in place**: `tools/overlap.janet` measures edges
against nodes on the finished SVG and currently reads 0/0/1. A router that
regresses that is wrong, whatever else it improves — which is the check the
last five attempts were missing until late.

## Recommendation

Worth doing, at roughly 290 lines, because it is the one change that unblocks
the others rather than trading against them. Order: funnel first (it is
testable in isolation against hand-computed channels), then fitting, then
switch simplex on and measure the pair together.
