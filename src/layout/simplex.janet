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
# STATE: NOT WIRED IN, AND NOT YET CORRECT. It runs, it terminates, and it
# changes nothing: measured on this tool's own graph it returns a span of 91
# against the relaxation's 91, where dot reaches 68 and the arithmetic floor
# (one rank per edge, 53 edges) is 53. There are forty ranks of slack it
# provably could remove and it removes none, so a move it should be finding
# is not being found.
#
# Two things are known to be wrong or unfinished:
#
#   - The tight tree is built per COMPONENT (a dependency graph is usually
#     disconnected -- this one has eight components), and the per-component
#     shifting spreads them onto eight ranks where six suffice. dot connects
#     components with zero-weight edges first (`connectGraph`); doing that
#     rather than ranking each alone would keep them overlaid.
#
#   - No negative cut value is ever acted on, which is the real defect. The
#     cut-value sign convention here has not been verified against a case
#     with a known answer, and a sign error would make every move look like
#     a cost. That is the first thing to check.
#
# It is committed unwired because the diagnosis it produced is worth more
# than the code: the target is 84 -> 68, the floor is 53, and the relaxation
# is stuck at a local optimum that no single-node move escapes.

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

  # NORMALISE, so the topmost rank is zero: the shifts above are relative and
  # a picture starting at rank three has an empty band across the top.
  (unless (empty? names)
    (def top (min ;(map |(rank-of $) names)))
    (each n names (put rank-of n (- (rank-of n) top))))
  rank-of)
