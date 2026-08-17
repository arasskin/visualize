# Network simplex: ranks with the least total weighted edge length there is.
#
# WHY THIS EXISTS, MEASURED. The relaxation it replaces is coordinate descent
# -- each node moves to the best rank its own edges allow, until nothing
# moves -- and it reaches a LOCAL optimum that is provably stuck: on this
# tool's own graph not one of thirty-five nodes could improve, and the total
# edge span was 84 ranks against dot's 68. Twenty-four per cent, and every
# extra rank of edge is a bend, every bend wants a column, and the columns
# are what crowd a rank until an edge has nowhere to route. Five separate
# ports downstream of ranking could not fix a cost that was already paid
# here.
#
# WHAT A RELAXATION CANNOT REACH is an arrangement where several nodes have
# to move together. Simplex can, because it does not move nodes at all: it
# maintains a SPANNING TREE of tight edges (edges at exactly their minimum
# length), and every tree edge cuts the tree in two. Re-ranking one side of
# that cut by one moves a whole subtree at once. The cut value says what such
# a move would cost -- the weight leaving minus the weight entering -- so a
# negative cut value is a move that pays, and the algorithm is: find one,
# make it, repeat.
#
# THE PIECES, all from graphviz's lib/common/ns.c:
#
#   feasible tree   a spanning tree of tight edges. Start from any feasible
#                   ranking, grow a tight subtree, and when it stops growing
#                   pull in the nearest non-tight edge by shifting the whole
#                   subtree until that edge becomes tight.
#   cut values      per tree edge, the net weight crossing the cut it makes.
#   leave edge      any tree edge with a negative cut value.
#   enter edge      the non-tree edge, crossing the same cut the other way,
#                   with the least slack -- the one that limits how far the
#                   subtree can move.
#   exchange        swap them, shift the subtree by that slack, recompute.
#
# Cut values here are recomputed rather than updated incrementally. dot
# maintains them through the exchange with low/lim intervals, which is what
# most of its 1400 lines are for; recomputing is O(V*E) per iteration and
# fine at the sizes a dependency graph reaches. The ANSWER should be
# identical -- only the constant differs.
#
# STATE: IT WORKS, AND IT IS NOT WIRED IN. Both halves are the point.
#
# It works: on the hand-computed case below it finds exactly the optimum,
# and on this tool's own graph it takes total edge span from 85 to 82 with a
# better-balanced distribution (11 7 5 7 3 5 1 against 15 8 7 3 5 1). That
# is the objective dot optimises and the gap the audit measured.
#
#   a -> b -> c -> d, a -> d, e -> d.  Longest path leaves e at rank 0 and
#   its edge spanning 3; the optimum drops e to rank 2 for a span of 7
#   against 9. The relaxation finds this one too -- it is a single-node move
#   -- but it is the smallest case where a wrong cut-value sign shows up,
#   and getting it right was what fixed this file.
#
# It is not wired in because A BETTER RANKING IS NOT A BETTER PICTURE. With
# simplex ranking the finished drawing has one edge crossing a node and five
# clipping an outline, where the relaxation's ranking yields none of either.
# Shorter edges mean nodes packed onto fewer, fuller ranks, and the ordering
# and placement passes then have less room to keep lines clear.
#
# THE FIRST EXPLANATION WAS WRONG, AND MEASURING IT IS WHAT SHOWED THAT.
# This header used to say the missing half was the ROUTER: dot can afford a
# tight ranking because it fits splines inside box corridors, ours only
# checked a candidate line and bowed it, so the two had to improve together.
# The router was then built -- funnel.janet and fit.janet, the port scoped
# in docs/dotgen-audit.md -- and the prediction was testable.
#
# It was false. Behind VISUALIZE_SIMPLEX, with the new router, this ranking
# draws 3 edges crossing a node, 5 clipping an outline and 9 passing close,
# against the relaxation's 1/1/1 on the same graph. And the router is not
# the thing failing: it fits 13 of 13 corridors under simplex ranking and
# falls back on none of them. Every curve stays inside the box it was
# given. The boxes are in the wrong places.
#
# THE SUSPECT MOVED TWICE AND SETTLED SOMEWHERE ELSE. First the router was
# blamed (wrong, above); then x-placement; then the second audit rendered
# every layout commit against the SAME tree and found the origin of the
# famous detour in the RELAXATION'S TIE-BREAK -- `rank` snapped nodes to
# the upper median of their neighbours inside an interval the objective was
# indifferent across, a group box grew a rank for zero gain, and every long
# edge detoured around it. Fixed in layered.janet, and the fix is a reason
# this file stays unwired: the relaxation with interval-aware ties draws
# the group shapes a reader wants, which no total-edge-length optimum asks
# for. See docs/dotgen-audit.md for the full account.

(defn- tree-of
  "Adjacency for an undirected view of the tree edges."
  [names tree]
  (def out @{})
  (each n names (put out n @[]))
  (eachp [pair _] tree
    (def [from to] pair)
    (array/push (out from) to)
    (array/push (out to) from))
  out)

(defn- component
  "Every node reachable from `start` over `adjacency`."
  [start adjacency]
  (def seen @{start true})
  (def stack @[start])
  (while (def n (array/pop stack))
    (each next (get adjacency n [])
      (unless (seen next)
        (put seen next true)
        (array/push stack next))))
  seen)

(defn rank
  ``Ranks minimising total weighted edge length, as {name rank}.

  `edges` is the acyclic edge list -- back edges must already be removed --
  and `weight-of` gives each edge's weight, defaulting to 1. `minlen` is the
  minimum rank difference an edge requires, defaulting to 1.

  Starts from `initial`, which must be feasible (every edge at least its
  minimum length); the caller's longest-path ranking is exactly that.``
  [names edges initial &opt weight-of minlen limit]
  (default weight-of (fn [_ _] 1))
  (default minlen 1)
  (default limit 200)

  (def rank-of (table/clone initial))
  (defn slack [from to]
    (- (- (rank-of to) (rank-of from)) minlen))

  # A TIGHT TREE is one where every edge in it has zero slack. Grown
  # greedily: from any node, take any tight edge to somewhere new. When it
  # stops growing, the tree does not span the graph yet, and the fix is
  # dot's: find the least-slack edge with exactly one end in the tree and
  # shift the whole tree by that slack, which makes that edge tight without
  # breaking any edge already tight.
  # A DISCONNECTED GRAPH HAS NO SPANNING TREE, and a dependency graph is
  # usually disconnected -- this tool's own has six parser files that import
  # nothing and are imported by nothing. dot connects the components with
  # zero-weight edges before ranking (`connectGraph` in position.c) so the
  # tree can span; the same trick here, except the components are ranked
  # INDEPENDENTLY and normalised at the end, which gives the same answer
  # without inventing edges that would drag unrelated nodes into line.
  (defn build-tight-tree [seed within]
    (def tree @{})
    (var members @{seed true})
    (var grew true)
    (while grew
      (set grew false)
      (each [from to] edges
        (when (and (within from) (within to)
                   (not= (truthy? (members from)) (truthy? (members to)))
                   (zero? (slack from to)))
          (put tree [from to] true)
          (put members from true)
          (put members to true)
          (set grew true))))
    [tree members])

  # The components, over the undirected graph: each is ranked on its own.
  (def whole @{})
  (each n names (put whole n @[]))
  (each [from to] edges
    (when (and (whole from) (whole to))
      (array/push (whole from) to)
      (array/push (whole to) from)))
  (def done @{})
  (each seed names
    (unless (done seed)
      (def within (component seed whole))
      (each n (keys within) (put done n true))
      (def local-names (filter |(within $) names))
      (when (> (length local-names) 1)
        # A FEASIBLE TIGHT TREE for this component, growing it and shifting
        # when it stalls until it spans.
        (var tree nil)
        (var guard 0)
        (while (< guard (length local-names))
          (++ guard)
          (def [t m] (build-tight-tree seed within))
          (set tree t)
          (if (>= (length m) (length local-names))
            (set guard (length local-names))
            (do
              (var best nil)
              (each [from to] edges
                (when (and (within from) (within to)
                           (not= (truthy? (m from)) (truthy? (m to))))
                  (def sl (slack from to))
                  (when (or (nil? best) (< sl (best 0)))
                    (set best [sl from to]))))
              (if-not best
                (set guard (length local-names))
                (let [[sl from to] best
                      delta (if (m from) sl (- sl))]
                  (each n local-names
                    (when (m n) (put rank-of n (+ (rank-of n) delta)))))))))

        (when tree
          # CUT VALUES. Removing a tree edge splits the tree in two; the cut
          # value is the weight crossing from the tail's side to the head's
          # minus the weight crossing back. Negative means that side would
          # rather move, and moving it pays.
          (defn cut-value [pair]
            (def [from to] pair)
            (def without (table/clone tree))
            (put without pair nil)
            (def adjacency (tree-of local-names without))
            (def tail-side (component from adjacency))
            (var total 0)
            (each [a b] edges
              (when (and (within a) (within b))
                (def wa (truthy? (tail-side a)))
                (def wb (truthy? (tail-side b)))
                (cond
                  (and wa (not wb)) (+= total (weight-of a b))
                  (and (not wa) wb) (-= total (weight-of a b)))))
            [total tail-side])

          (var rounds 0)
          (var improving true)
          (while (and improving (< rounds limit))
            (++ rounds)
            (set improving false)
            (var leave nil)
            (var leave-side nil)
            (eachp [pair _] tree
              (unless leave
                (def [value side] (cut-value pair))
                (when (neg? value)
                  (set leave pair)
                  (set leave-side side))))
            (when leave
              # ENTER EDGE: of the non-tree edges crossing back over that
              # cut, the one with least slack -- it is what limits how far
              # the subtree can move before something else goes tight.
              (var enter nil)
              (var best-slack nil)
              (each [a b] edges
                (when (and (within a) (within b) (not (tree [a b])))
                  (when (and (not (leave-side a)) (leave-side b))
                    (def sl (slack a b))
                    (when (or (nil? best-slack) (< sl best-slack))
                      (set best-slack sl)
                      (set enter [a b])))))
              (when (and enter (pos? best-slack))
                (each n local-names
                  (when (leave-side n)
                    (put rank-of n (+ (rank-of n) best-slack))))
                (put tree leave nil)
                (put tree enter true)
                (set improving true))))))))

  # NORMALISE PER COMPONENT, not once over the whole graph.
  #
  # Each component is ranked on its own, and the tree-shifting inside a
  # component moves it bodily -- so two components that both want to start
  # at the top can end up on different ranks for no reason, and the picture
  # grows a rank for every one of them. This graph has eight components and
  # gained two ranks that way.
  #
  # dot avoids the question by joining the components with zero-weight edges
  # before ranking (`connectGraph`), so there is one tree and one frame of
  # reference. Normalising each component to start at zero reaches the same
  # arrangement without inventing edges: within a component every relative
  # rank is what simplex decided, and between components there is nothing to
  # decide.
  (def seen @{})
  (each seed names
    (unless (seen seed)
      (def within (component seed whole))
      (each n (keys within) (put seen n true))
      (def local (filter |(within $) names))
      (unless (empty? local)
        (def top (min ;(map |(rank-of $) local)))
        (each n local (put rank-of n (- (rank-of n) top))))))

  # BALANCE, from the tail of rank.c -- ported, correct, and PROVABLY
  # INERT for the purpose it was ported for. Both halves are the finding.
  #
  # dot's pass: a node whose in-weight equals its out-weight can move
  # anywhere its edges allow without changing total edge length, so dot
  # puts it on the emptiest rank in that window. It was ported here as the
  # last named piece between this layout and dot's crossing count -- the
  # ordering passes measured at their instance's floor (see the ledger in
  # layered.janet's mincross loop), and thinning the crowded ranks was the
  # only lever left.
  #
  # FIRST TRY, NODE-COUNTED like dot's: it produced beautifully even rows
  # -- 6 4 7 7 7 4 4 2 -- while the BEND columns piled 11 deep on the
  # middle ranks, and drawn crossings doubled from 22 to 44. dot can count
  # nodes because in dot the virtual chain nodes ARE nodes by the time
  # balance runs; here bends are derived later, so a node-only count
  # balances the wrong quantity.
  #
  # SECOND TRY counts bends too, and every candidate rank is scored by the
  # squared load of the WHOLE graph (a move changes its own edges' spans,
  # so its own bends move with it). This is the honest objective -- and it
  # cannot move anything on graphs of this shape. Hand-computed on a
  # synthetic case built to be favourable, a free node with a three-rank
  # window and a crowd of seven on its home rank: squared load 149 at
  # every position in the window, flat. Moving the node off a rank removes
  # a node from it and adds a bend to it -- its own edge now spans that
  # rank -- and occupancy is conserved EXACTLY. The freedom dot spends is
  # freedom this model does not have: with bends counted, a free node's
  # rank is not a free variable at all.
  #
  # So the pass stays, inert by proof rather than by accident: it is what
  # rank.c does, it is correct, and the crossing gap to dot is NOT here.
  # Whoever hunts that gap next should look where dot and this layout
  # genuinely differ in kind -- dot ranks its virtual chain nodes as
  # first-class nodes throughout, which changes what every later pass
  # sees, and no single tail pass reproduces that.
  #
  # A node is FREE when in-weight equals out-weight, which for an unweighted
  # dependency graph means equal counts of parents and children. dot's
  # condition exactly; the asymmetric case is left alone because moving it
  # would change the objective simplex just minimised.
  (def parents @{})
  (def children @{})
  (each n names (put parents n @[]) (put children n @[]))
  (each [from to] edges
    (when (and (parents from) (parents to) (not= from to))
      (array/push (children from) to)
      (array/push (parents to) from)))
  # OCCUPANCY COUNTS BENDS, NOT JUST NODES, and that correction is the
  # whole difference between this pass helping and hurting. dot's balance
  # counts nodes because in dot the virtual chain nodes ARE nodes on the
  # rank -- they were inserted before ranking's tail runs. Here bends are
  # derived later, so a node-only count balanced the wrong quantity: it
  # produced beautifully even rows of 6 4 7 7 7 4 4 2 while the bend
  # columns piled 11 deep on the middle ranks, and crossings doubled. An
  # edge spanning r ranks lays a bend on each rank strictly between its
  # ends, which is exactly what this counts.
  (def occupancy @{})
  (each n names (put occupancy (rank-of n) (+ 1 (get occupancy (rank-of n) 0))))
  (defn count-bends [delta]
    (each [from to] edges
      (when (and (parents from) (parents to) (not= from to))
        (def a (rank-of from))
        (def b (rank-of to))
        (def lo (min a b))
        (def hi (max a b))
        (for r (+ lo 1) hi
          (put occupancy r (+ (get occupancy r 0) delta))))))
  (count-bends 1)
  (each n names
    (def up (parents n))
    (def down (children n))
    (when (and (not (empty? up)) (not (empty? down))
               (= (length up) (length down)))
      # The window its edges allow: strictly below every parent, strictly
      # above every child, minlen respected at both ends.
      (def low (+ (max ;(map |(rank-of $) up)) minlen))
      (def high (- (min ;(map |(rank-of $) down)) minlen))
      (when (< low high)
        (def here (rank-of n))
        # THE MOVE CHANGES ITS OWN EDGES' BENDS, so a candidate is judged
        # by the occupancy the whole graph would have, not by the row's
        # current load. Moving a node up shortens its parents' edges and
        # lengthens its children's -- the bends move with it, and a pass
        # that ignored that would trade a crowded row for a crowded
        # column and call it progress.
        (defn spread-if [r]
          (put rank-of n r)
          (each k (keys occupancy) (put occupancy k 0))
          (each m names (put occupancy (rank-of m) (+ 1 (get occupancy (rank-of m) 0))))
          (count-bends 1)
          # The cost of a row is its load SQUARED, summed: two rows of
          # five beat one of ten, which is what "spread out" means and
          # what a plain maximum cannot express.
          (var total 0)
          (eachp [_ load] occupancy (+= total (* load load)))
          total)
        (var best here)
        (var best-cost (spread-if here))
        (for r low (+ high 1)
          (unless (= r here)
            (def c (spread-if r))
            (when (< c best-cost)
              (set best-cost c)
              (set best r))))
        (spread-if best))))
  rank-of)
