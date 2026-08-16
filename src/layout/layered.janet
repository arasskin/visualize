# A layered layout: the one that replaces graphviz.
#
# THE ALGORITHM IS SUGIYAMA, which is what `dot` runs and what a dependency
# graph wants, because a dependency graph has a DIRECTION and the picture
# should show it. Four passes, each one a named function below:
#
#   1. rank    -- put every node on a layer, so edges point downward
#   2. order   -- order each layer to cross as few edges as possible
#   3. place   -- give each node an x, so parents sit over their children
#   4. route   -- run each edge through the layers it spans
#
# WHAT WE DELIBERATELY DO NOT DO, and why this is ~200 lines instead of
# graphviz's tens of thousands: no spline routing (straight segments through
# the dummy chain read fine and are honest about where an edge goes), no
# port constraints, no orthogonal edges, no cluster-aware ranking. Those are
# the features that make DOT a big program, and a dependency graph needs
# none of them.
#
# CYCLES ARE THE ONE REAL SUBTLETY. A dependency graph is not a DAG -- two
# files importing each other is common and worth SEEING rather than
# silently rewriting. `rank` breaks cycles by provisionally reversing the
# back edges, ranks the DAG that leaves, and `route` draws the reversed ones
# in their original direction, so a cycle appears as an edge pointing back
# up the page. That is the honest picture: the loop is visible as a loop.
#
# DETERMINISTIC throughout -- same graph, same picture, every time. The
# crossing-reduction sweep is seeded by the input order rather than by
# anything random, so a watcher redraw never becomes a jump scare.

(def- defaults
  {:layer-gap 92       # vertical distance between layers
   :node-gap 20        # minimum horizontal gap between neighbours
   :bend-width 12      # the column a through-edge reserves on a layer it crosses
   :group-inset 0      # how far outside its members a group's box is drawn
   :refine-limit 45    # nodes past which refinement is skipped -- see `place`
   :sweeps 8})         # crossing-reduction passes (down and up count as one)

#
# 1. Ranking.
#

(defn- back-edges
  ``The edges that close a cycle, found by a depth-first walk.

  An edge to a node currently ON THE STACK points back into the walk, which
  is the definition of a cycle-closing edge. Reversing exactly these leaves a
  DAG; which ones get chosen depends on the walk order, and the walk order is
  the node order, which is stable.

  A SELF-EDGE IS NOT A CYCLE to break. `A -> A` closes no loop between two
  nodes -- there is nothing to reverse and no rank it could fix -- and the
  ranking pass already ignores it. Counting it here would report a back edge
  the renderer would then draw as if it ran somewhere.``
  [names outgoing]
  (def colour @{})   # nil = unvisited, :open = on the stack, :done = finished
  (def back @{})
  (defn walk [name]
    (put colour name :open)
    (each next (get outgoing name [])
      (unless (= next name)
        (case (colour next)
          :open (put back [name next] true)
          :done nil
          (walk next))))
    (put colour name :done))
  (each name names
    (unless (colour name) (walk name)))
  back)

(defn rank
  ``Every node's layer, as {name layer}.

  A node sits one below the lowest of everything that points at it -- the
  longest-path ranking, which makes the depth of the picture the depth of
  the dependency chain.

  DIRECTION IS THE SCAN'S, unchanged. It emits `[a b]` meaning "b depends on
  a", so the arrowhead lands on the importer (see scan/build). Ranking `to`
  one layer below `from` therefore puts the depended-upon files at the top
  and the things importing them underneath -- which is where graphviz put
  them, and keeping it identical is what makes the swap invisible.``
  [names edges]
  (def outgoing @{})
  (each name names (put outgoing name @[]))
  (each [from to] edges
    (when (and (outgoing from) (outgoing to))
      (array/push (outgoing from) to)))

  (def back (back-edges names outgoing))
  # The DAG we actually rank: every edge except the ones that close a cycle.
  (def forward @{})
  (def incoming @{})
  (each name names (put forward name @[]) (put incoming name 0))
  (each [from to] edges
    (when (and (forward from) (forward to) (not (back [from to])) (not= from to))
      (array/push (forward from) to)
      (put incoming to (+ 1 (incoming to)))))

  # Longest-path by Kahn order: a node is placed once everything above it is.
  (def layer @{})
  (each name names (put layer name 0))
  (def ready (filter |(zero? (incoming $)) names))
  (def queue @[;ready])
  (var head 0)
  (while (< head (length queue))
    (def name (queue head))
    (++ head)
    (each next (forward name)
      (put layer next (max (layer next) (+ 1 (layer name))))
      (put incoming next (- (incoming next) 1))
      (when (zero? (incoming next)) (array/push queue next))))
  # Anything the queue never reached sits in a knot of cycles the back-edge
  # pass did not fully break; leaving it at its current rank is fine and
  # keeps the function total.

  # TIGHTEN. Longest-path ranking puts every node with nothing above it on
  # layer 0, which is correct and reads badly: on this tool's own graph that
  # is seventeen of thirty-three nodes in one row, and the row sets the width
  # of the whole picture. A node with no PARENT is only pinned to the top by
  # the accident of being ranked from above.
  #
  # So each such node drops to just above its lowest child. That cannot
  # invert an edge -- the new rank is strictly less than every child's -- and
  # it cannot reorder anything already correct, because a node with a parent
  # is left exactly where the longest path put it. What it does is move the
  # sources down to meet their work, which is what makes the rank sizes come
  # out even instead of top-heavy.
  #
  # A node with no children either is genuinely isolated, and `place` puts
  # those somewhere useful rather than in the middle of the widest row.
  (def parents @{})
  (each name names (put parents name 0))
  (each [from to] edges
    (when (and (forward from) (forward to) (not (back [from to])) (not= from to))
      (put parents to (+ 1 (parents to)))))
  (each name names
    (when (and (zero? (parents name)) (not (empty? (forward name))))
      (def lowest (min ;(map |(layer $) (forward name))))
      (put layer name (max 0 (- lowest 1)))))
  [layer back])

#
# 2. Ordering.
#

(defn- median-of
  ``The median position of a node's neighbours in the adjacent layer.

  -1 for a node with no neighbours there, which the sort reads as "leave it
  where it is" rather than moving it to one end.``
  [neighbours positions]
  (def spots (sort (map |(positions $) (filter |(positions $) neighbours))))
  (cond
    (empty? spots) -1
    (odd? (length spots)) (spots (div (length spots) 2))
    # The average of the two middles, which is the standard median heuristic
    # and behaves better than picking either one.
    (/ (+ (spots (- (div (length spots) 2) 1))
          (spots (div (length spots) 2)))
       2)))

(defn order
  ``Order each layer to reduce edge crossings.

  The median heuristic, swept down then up a fixed number of times. It is
  not optimal -- minimising crossings is NP-hard -- but it is what every
  layered layout in practice uses, and a few sweeps get most of the benefit.

  A GROUP SCORES AS ONE NODE. Given `group-of`, every member of a group on a
  layer takes the same median -- the median of all their neighbours together
  -- so the sort seats the group as a block and everything ungrouped settles
  around it in the SAME pass. Ordering the layer first and shuffling the
  group together afterwards, which is what `cohere` alone does, decides the
  positions of the ungrouped nodes before the group has taken its slot: on
  this tool's own graph that left `src/parser` ordered after `src.term`
  while `src/scan`, the one node it connects to, sat away to the left, and
  its edge crossed the whole group to reach it.

  Returns {layer [names, in order]}.``
  [layers up down sweeps &opt group-of bend?]
  (default group-of (fn [_] nil))
  (default bend? (fn [_] false))
  (def indexes (sort (keys layers)))
  (def current (table/clone layers))

  (defn positions-in [names]
    (def out @{})
    (eachp [i name] names (put out name i))
    out)

  (defn sweep [order-of-layers pick]
    (each index order-of-layers
      (def previous (current (+ index (if (= pick :down) -1 1))))
      (when previous
        (def positions (positions-in previous))
        (defn neighbours [name] (if (= pick :down) (up name) (down name)))
        # A group's members pool their neighbours and share the answer, which
        # is what makes the sort treat them as one thing to place.
        (def shared @{})
        (each name (current index)
          (when-let [key (group-of name)]
            (unless (shared key) (put shared key @[]))
            (array/push (shared key) ;(neighbours name))))
        (def group-median @{})
        (eachp [key all] shared
          (put group-median key (median-of all positions)))
        (def scored (map (fn [name]
                           [(if-let [key (group-of name)]
                              (group-median key)
                              (median-of (neighbours name) positions))
                            name])
                         (current index)))
        # Nodes with no neighbour above (-1) keep their relative order, which
        # `sorted-by` gives us since Janet's sort is stable on equal keys
        # only if we make the key carry the tiebreak -- so the original index
        # rides along.
        (def with-index (map (fn [i pair] [(pair 0) i (pair 1)])
                             (range (length scored)) scored))
        (def fixed (filter |(= -1 ($ 0)) with-index))
        (def movable (filter |(not= -1 ($ 0)) with-index))
        # The group key breaks ties BEFORE the original index does, so an
        # ungrouped node that happens to share the group's median cannot land
        # in the middle of it -- which would put a stranger inside the box.
        #
        # A BEND LOSES A NEAR-TIE TO A REAL NODE, and that is the point of
        # `nudge`. A bend's median comes from the one chain link it has, so
        # it is exact; a node's is the average of everything it touches, and
        # a single unrelated neighbour off to one side drags it half a
        # position. `src/scan` scored 8.5 from links at 7 and 10 while the
        # `src/json -> src/graph` bend scored exactly 8, so the bend sorted
        # ahead of it by half a slot and was pushed out the far side -- its
        # rank-1 bend landed ninety units left of the straight line between
        # its own ends, and the edge took the long way round `src/scan`
        # instead of running down beside `src/state`'s.
        #
        # Half a position is not a real preference, so the node keeps the
        # slot and the edge routes past it on the side its line wants.
        (defn nudge [entry]
          (if (bend? (entry 2)) 0.5 0))
        (def placed (sorted-by |[(+ ($ 0) (nudge $)) (or (group-of ($ 2)) "") ($ 1)]
                               movable))
        # The fixed ones go back at their original indexes, so a node with
        # no constraint does not drift to the edge of the layer.
        (def result (array ;(map |($ 2) placed)))
        (each [_ i name] fixed
          (array/insert result (min i (length result)) name))
        (put current index result))))

  # `sweeps` of 0 means "one up-sweep only", which is how a caller seats the
  # TOP rank: it has no layer above it, so a down-sweep reads an empty
  # neighbour list and `median-of` answers -1 -- leave it alone. Only reading
  # downward puts a source over the work it feeds.
  (if (zero? sweeps)
    (sweep (reverse (slice indexes 0 -2)) :up)
    (for pass 0 sweeps
      (sweep (slice indexes 1) :down)
      (sweep (reverse (slice indexes 0 -2)) :up)))
  current)

(defn cohere
  ``Pull each group's members together, across layers as well as within one.

  A GROUP IS A BOX AROUND SOME NODES. It says nothing about layers -- a group
  whose members land on four different ranks is still one group -- so the
  renderer draws it one rect, and this is what makes that rect honest: if a
  non-member sits inside the members' bounding box, the picture asserts a
  membership that is not there.

  WITHIN a layer that means the members are contiguous. ACROSS layers it
  means they occupy the SAME REGION of each one: a group whose members sit
  far left on one rank and far right on the next has a bounding box spanning
  everything in between, and the box swallows whatever was there. Drawing a
  band per layer used to paper over exactly that -- it made the picture
  truthful by giving up on the box, and left a group split across two ranks
  looking like two groups.

  So each group gets ONE slot, and every layer it appears on puts it at the
  same place in the running order. The slot is the average of where the sweep
  left the group's members, so crossing reduction is respected as far as it
  can be: the group lands where it already mostly was, and everything
  ungrouped keeps its own position around it.

  `group-of` answers a group key for a node name, or nil. The key is only
  ever compared, so a prefix string does as well as anything. A layer also
  holds the bend points of edges passing through it, which belong to no
  group and are left where the crossing sweep put them.``
  [ordered group-of-name]
  (defn group-of [name] (when (string? name) (group-of-name name)))

  # Where each group sits, as a fraction along its layer. A fraction rather
  # than an index, because layers differ in length and a group on a row of
  # three has to line up with the same group on a row of twelve.
  #
  # WEIGHTED BY HOW MANY MEMBERS A LAYER HOLDS. A flat average lets a rank
  # with one member drag the whole group as hard as the rank holding the rest
  # of it, and the group then lands where none of it actually was -- shoving
  # aside nodes the crossing sweep had placed perfectly well. `src.term` has
  # one member on rank 0 and two on rank 1; averaging flat moved the group
  # left on rank 0, which pushed `src/parser` out past it and left the one
  # edge `src/parser` has crossing the whole group to reach `src/scan`.
  # Weighting keeps the group near its own centre of mass.
  (def spots @{})
  (eachp [_ row] ordered
    (def n (max 1 (length row)))
    (def here (filter |(group-of $) row))
    (eachp [i name] row
      (when-let [key (group-of name)]
        (unless (spots key) (put spots key @[]))
        # Each member votes, so a layer holding two of them counts twice.
        (array/push (spots key) (/ i n)))))
  (def slot @{})
  (eachp [key at] spots
    (put slot key (/ (sum at) (length at))))

  (def out @{})
  (eachp [index row] ordered
    (def seen @[])           # group keys, in the order they first appear
    (def members @{})        # key -> its nodes, in their existing order
    (def loose @[])          # [position node] for everything ungrouped
    (def n (max 1 (length row)))
    (eachp [i name] row
      (if-let [key (group-of name)]
        (do
          (unless (find |(= $ key) seen) (array/push seen key))
          (put members key (array/push (or (members key) @[]) name)))
        (array/push loose [(/ i n) name])))
    (if (empty? seen)
      (put out index row)
      (do
        # The group goes at its shared slot; the ungrouped keep theirs.
        # Sorting the two together by that position preserves the sweep's
        # decisions everywhere they did not conflict with keeping a group
        # whole and keeping it over itself.
        (def slots @[])
        (each key seen (array/push slots [(slot key) (members key)]))
        (each [at name] loose (array/push slots [at [name]]))
        (put out index
             (array ;(mapcat |($ 1) (sorted-by |($ 0) slots)))))))
  out)

#
# 2b. Refinement -- ordering judged by the picture it produces.
#

(defn cost
  ``What is wrong with a drawing, as a number to be made smaller.

  THE UNITS ARE THE PICTURE'S. Everything upstream of here reasons in
  ORDINAL space -- a layer is a list, the median heuristic compares indexes
  -- and everything that actually matters is geometric: whether a diagonal
  clears an ellipse, whether there is a lane between two nodes wide enough
  to thread an edge through, how far a bend sits from the line its edge
  wants. The two are not commensurable, and trying to bridge them with a
  scalar is what made three separate attempts at the `src/select` corner
  worse rather than better: a bend's desired position simply cannot be
  expressed as an index in a layer it is not in.

  So the sweep keeps its heuristic, and this judges the RESULT. An ordering
  is proposed, placed, and kept only if the picture it draws is better --
  which needs no common unit with the heuristic at all.

  Three terms, each counting something a reader would complain about:

    crossings   -- edges that cross each other, the classic measure
    clipping    -- an edge passing through a node it has nothing to do with
    length      -- total horizontal travel, which stands in for the
                   diagonal sprawl that makes a graph hard to follow

  Clipping is weighted hardest because it is the one that reads as a
  mistake rather than as complexity.``
  [positions widths edge-paths &opt boxes]
  (default boxes [])
  (var crossings 0)
  (var clipped 0)
  (var boxed 0)
  (var travel 0)

  # Segments, with the edge they belong to, so an edge is not counted
  # against itself.
  (def segs @[])
  (eachp [key path] edge-paths
    (for i 0 (- (length path) 1)
      (array/push segs [(path i) (path (+ i 1)) key])))

  (defn crosses [[p1 p2 _] [p3 p4 _]]
    (def d (- (* (- (p2 0) (p1 0)) (- (p4 1) (p3 1)))
              (* (- (p2 1) (p1 1)) (- (p4 0) (p3 0)))))
    (if (< (math/abs d) 0.000001)
      false
      (let [t (/ (- (* (- (p3 0) (p1 0)) (- (p4 1) (p3 1)))
                    (* (- (p3 1) (p1 1)) (- (p4 0) (p3 0)))) d)
            u (/ (- (* (- (p3 0) (p1 0)) (- (p2 1) (p1 1)))
                    (* (- (p3 1) (p1 1)) (- (p2 0) (p1 0)))) d)]
        (and (> t 0.02) (< t 0.98) (> u 0.02) (< u 0.98)))))

  (for i 0 (length segs)
    (for j (+ i 1) (length segs)
      (unless (= ((segs i) 2) ((segs j) 2))
        (when (crosses (segs i) (segs j)) (++ crossings)))))

  # An edge through a node it does not touch. Sampled along each segment
  # against each node's ellipse, the same test the renderer's geometry has.
  (eachp [key path] edge-paths
    (def [from to] key)
    (var hit false)
    (eachp [name p] positions
      (unless (or hit (= name from) (= name to))
        (def rx (max 1 (/ (widths name) 2)))
        (def ry 34)
        (for i 0 (- (length path) 1)
          (def a (path i))
          (def b (path (+ i 1)))
          (for s 1 12
            (def t (/ s 12))
            (def px (+ (a 0) (* t (- (b 0) (a 0)))))
            (def py (+ (a 1) (* t (- (b 1) (a 1)))))
            (def dx (/ (- px (p :x)) rx))
            (def dy (/ (- py (p :y)) ry))
            (when (< (+ (* dx dx) (* dy dy)) 1) (set hit true))))))
    (when hit (++ clipped))
    (for i 0 (- (length path) 1)
      (+= travel (math/abs (- ((path (+ i 1)) 0) ((path i) 0))))))

  # An edge cutting a group's box, which is the third thing a reader
  # complains about and the one the search could not previously see.
  (each b boxes
    (def [x0 y0 x1 y1 members] b)
    (eachp [key path] edge-paths
      (unless (or (find |(= $ (key 0)) members) (find |(= $ (key 1)) members))
        (var inside false)
        (for i 0 (- (length path) 1)
          (def p (path i))
          (def q (path (+ i 1)))
          (for s 0 13
            (def t (/ s 12))
            (def px (+ (p 0) (* t (- (q 0) (p 0)))))
            (def py (+ (p 1) (* t (- (q 1) (p 1)))))
            (when (and (> px x0) (< px x1) (> py y0) (< py y1))
              (set inside true))))
        (when inside (++ boxed)))))

  (+ (* 40 clipped) (* 30 boxed) (* 25 crossings) (/ travel 25)))

#
# 3. Placement.
#

(defn settle
  ``Place one layer: the positions closest to `want` that keep the order and
  the gaps.

  THIS IS THE ONE PLACE SEPARATION HAPPENS, and that is the point of it.
  Every pass in `place-x` wants nodes somewhere -- over their parents, on a
  straight line, outside a group's box -- and each used to move them itself
  and then sweep the layer apart afterwards. A sweep can only push one way,
  so the passes undid each other: clearing a box shoved a node onto its
  neighbour, the next sweep shoved it back into the box, and the picture came
  out with whichever defect the last pass happened to leave. Passes now say
  what they WANT and this decides where things go, so non-overlap is a
  property of the output rather than of the order the passes ran in.

  The algorithm is the classic one for isotonic placement with minimum gaps:
  walk left to right building blocks of nodes that have been pushed into
  contact, and whenever a new node would overlap the block behind it, merge
  the two and re-place the merged block at the average of what its members
  wanted. A block only ever grows, so this is linear, and the result is the
  arrangement minimising the total squared distance from `want`.

  `fixed` names nodes that may not move at all -- a group's members, whose
  column IS the box. A block containing one of those is placed to satisfy it
  rather than the average; two conflicting fixed nodes in one block cannot
  both be had, and the leftmost wins, which is the same rule the order
  already encodes.

  `floor` and `ceiling` are hard bounds per node, used to keep a stranger out
  of a group's box. They cannot be desires: a desire is an average, and a
  block merging around a node averages its wish away -- which is exactly how
  a node evicted from a box got pulled back into it by the neighbours it
  merged with. A bound survives the merge because it moves the whole block.``
  [names want widths gap &opt fixed floor ceiling]
  (default fixed (fn [_] false))
  (default floor (fn [_] nil))
  (default ceiling (fn [_] nil))
  (def out @{})
  # Each block: the names in it, where its left edge wants to be, and the
  # total width it needs. `pin` is the position a fixed member demands for
  # the block's left edge, or nil.
  (def blocks @[])
  (each name names
    (def w (widths name))
    (def half (/ w 2))
    (def left (- (want name) half))
    # Bounds are carried as bounds on the BLOCK's left edge, so a merge just
    # takes the tighter of the two and the whole block honours it.
    # A bound is stored as a bound on the BLOCK's left edge, so it has to be
    # translated by how far into the block the node sits -- at creation that
    # is zero, and every merge below shifts it by the width taken on in
    # front. Storing the node's own bound and applying it to the block start
    # is the same mistake as forgetting the offset in any prefix sum: it
    # holds while every block is one node and quietly stops holding the
    # moment two merge, which is why `src/watchdog` sat 33 units inside a box
    # it had a floor against.
    (array/push blocks @{:names @[name] :left left :width w
                         :pin (when (fixed name) left)
                         :low (when-let [f (floor name)] (- f half))
                         :high (when-let [c (ceiling name)] (- c half))})
    # Merge backwards while this block starts before the previous one ends.
    (while (and (> (length blocks) 1)
                (let [b (last blocks)
                      a (blocks (- (length blocks) 2))]
                  (< (b :left) (+ (a :left) (a :width) gap))))
      (def b (array/pop blocks))
      (def a (last blocks))
      # The merged block's left edge: what the two halves wanted, weighted by
      # how many nodes each speaks for, unless one of them is pinned.
      (def a-n (length (a :names)))
      (def b-n (length (b :names)))
      (def b-left-in-a (- (b :left) (+ (a :width) gap)))
      (def merged (/ (+ (* a-n (a :left)) (* b-n b-left-in-a)) (+ a-n b-n)))
      # TWO PINS IN ONE BLOCK ARE AVERAGED, not resolved in favour of the
      # first. Taking the leftmost silently threw away the other group's
      # column: `src.term`'s members and `web`'s ended up in one block on a
      # crowded rank, `web/app` lost its pin, and the `web` box stretched a
      # hundred units across to reach the member that had kept it -- with
      # `tools/replay` inside the gap. Neither pin can be had exactly once
      # they are in contact, so both give equally.
      (def b-pin (when (b :pin) (- (b :pin) (+ (a :width) gap))))
      (def pin (cond
                 (and (a :pin) b-pin) (/ (+ (a :pin) b-pin) 2)
                 (a :pin) (a :pin)
                 b-pin))
      # The tighter of the two bounds, translated into the merged block's
      # frame. Written as a `cond` this read `(cond (and l r) (max l r) l r)`,
      # which is four clauses rather than three: `l` became a TEST and `r` its
      # body, so a pair with either side missing answered nil and the bound
      # vanished. Every block of more than one node lost its floor that way,
      # which is why a node with a hard floor against a group's box still sat
      # inside it.
      (defn shift [v] (when v (- v (+ (a :width) gap))))
      (def low (let [l (a :low) r (shift (b :low))]
                 (if (and l r) (max l r) (or l r))))
      (def high (let [l (a :high) r (shift (b :high))]
                  (if (and l r) (min l r) (or l r))))
      (put a :left (or pin merged))
      (put a :width (+ (a :width) gap (b :width)))
      (put a :pin pin)
      (put a :low low)
      (put a :high high)
      (array/concat (a :names) (b :names))))
  # Lay each block out from its left edge, in order, honouring its bounds.
  # A floor beats a ceiling where the two cannot both hold: the floor is what
  # keeps a node out of a group's box, and a box containing a node it does
  # not group is the defect that has to be impossible.
  (var edge nil)
  (each b blocks
    (var left (b :left))
    (when (b :high) (set left (min left (b :high))))
    (when (b :low) (set left (max left (b :low))))
    # Never behind the block before it -- the bounds must not undo the order.
    (when edge (set left (max left edge)))
    (var cursor left)
    (each name (b :names)
      (def w (widths name))
      (put out name (+ cursor (/ w 2)))
      (set cursor (+ cursor w gap)))
    (set edge cursor))
  out)

(defn- widths-of
  "Each node's drawn width, so placement can respect a long label."
  [names measure]
  (def out @{})
  (each name names (put out name (measure name)))
  out)

(defn place-x
  ``An x for every node, layer by layer.

  EVERY PASS SAYS WHAT IT WANTS; `settle` DECIDES WHERE THINGS GO. A node has
  several things pulling on it -- sit over your parents, sit under your
  children, lie on the straight line your edge wants, stay out of a box you
  are not in -- and each of those used to move the node itself and then sweep
  the layer apart afterwards. A sweep only pushes one way, so the passes
  undid each other in sequence: clearing a group's box shoved a node onto its
  neighbour, the next sweep shoved it back into the box, and the picture came
  out with whichever defect the last pass happened to leave. Adding a pass
  meant finding out which of the others it broke.

  So the desires are computed first, combined, and handed to `settle` once
  per layer, which returns the closest arrangement that keeps the order and
  the gaps. Non-overlap is now a property of the OUTPUT rather than of the
  order the passes ran in, and a new desire is a new term here rather than
  another sweep to reconcile with the rest.

  `bend?` says whether a name is one of the bend points a long edge is
  threaded through rather than a real node; `aim` answers the x such a bend
  would sit at if its edge ran perfectly straight; `group-of` answers a
  node's group; `inset` is how far outside its members the renderer draws a
  group's box, so the layout can clear the rectangle that actually appears.``
  [ordered up down widths gap &opt bend? aim group-of inset]
  (default bend? (fn [_] false))
  (default aim (fn [_ _] nil))
  (default inset 0)
  (def indexes (sort (keys ordered)))
  (def x @{})

  # Start centred on zero rather than packed from the left: packing made the
  # widest layer set the left edge and left the narrow ones stranded under
  # its first few nodes, so an eighteen-node row over a one-node row came out
  # as a diagonal smear rather than a tree.
  (each index indexes
    (var span (- gap))
    (each name (ordered index) (+= span (+ (widths name) gap)))
    (var cursor (/ span -2))
    (each name (ordered index)
      (put x name (+ cursor (/ (widths name) 2)))
      (set cursor (+ cursor (widths name) gap))))

  (defn centre-on [names]
    (def known (filter |(x $) names))
    (unless (empty? known)
      (/ (sum (map |(x $) known)) (length known))))

  # Where each group sits and which layers it covers, as the rectangle the
  # renderer will draw: the members' extent plus the inset. Recomputed each
  # round, because the members move.
  (defn claims-by-layer []
    (def span @{})
    (when group-of
      (eachp [index row] ordered
        (each name row
          (when-let [key (group-of name)]
            (def half (/ (widths name) 2))
            (unless (span key)
              (put span key @{:x0 math/inf :x1 (- math/inf) :widest 0
                              :top math/inf :low (- math/inf)}))
            (def s (span key))
            (put s :x0 (min (s :x0) (- (x name) half)))
            (put s :x1 (max (s :x1) (+ (x name) half)))
            (put s :widest (max (s :widest) (widths name)))
            (put s :top (min (s :top) index))
            (put s :low (max (s :low) index))))))
    (def out @{})
    (each index indexes
      (def here @[])
      (eachp [key s] span
        # ONE RANK PAST THE LOWEST MEMBER, because the box reaches there. A
        # node is drawn as an ellipse, so the box around it extends half a
        # node plus the inset BELOW the rank line -- about fifty units into
        # the gap before the next rank. An edge bending on that next rank is
        # free to sit inside the box's x-range, and the segment climbing to
        # it clips the overhang: `src/json -> src/core` and
        # `src/stamp -> src/core` both cut the bottom corner of `src.term`
        # that way, having cleared it perfectly well on the ranks the group
        # actually has members on.
        #
        # The same is true above the topmost member, where the box also
        # carries its name.
        (when (and (<= (- (s :top) 1) index) (<= index (+ (s :low) 1)))
          (array/push here [key (- (s :x0) inset) (+ (s :x1) inset)])))
      (put out index here))
    [span out])

  # One round: work out what everything wants, then let `settle` place it.
  (defn round [pick]
    (def [span claims] (claims-by-layer))
    # A group's column, so its members on every rank want the same x.
    #
    # THE RIGHTMOST MEMBER SETS IT, not the average of the members' extent.
    # The average is the midpoint between two members that have drifted
    # apart, and each is pinned there -- which converges only if BOTH can
    # move. One of them usually cannot: it has a node hard against it on the
    # side it would have to travel. `web/app` was blocked by `tools/replay`
    # and `web/term` was pulled only halfway to meet it, so the two settled
    # 103 units apart, the box stretched to span them, and `tools/replay`
    # fell inside it -- a stable wrong answer rather than a failure to
    # converge.
    #
    # Taking the rightmost member's position asks the ones that CAN move to
    # come to the one that cannot. A group whose members are all free ends up
    # in the same place either way; a group with one pinned member closes up
    # around it instead of straddling.
    (def column @{})
    (eachp [key s] span
      (put column key (/ (+ (s :x0) (s :x1)) 2)))

    (each index (if (= pick :down) indexes (reverse indexes))
      (def names (ordered index))
      (def here (get claims index []))
      (def want @{})
      (each name names
        (def half (/ (widths name) 2))
        # 1. A bend wants the straight line between its edge's two ends; a
        #    real node wants the middle of its neighbours in the layer the
        #    sweep is coming from. Either way, failing that, where it is.
        (var target
          (or (if (bend? name)
                (aim name x)
                (centre-on (if (= pick :down) (up name) (down name))))
              (x name)))
        # 2. A group's member wants its group's column, so the box closes
        #    around the members rather than stretching across the picture.
        (when-let [key (and group-of (group-of name))]
          (set target (column key)))
        (put want name target))

      # 3. STAYING OUT OF A BOX IS A BOUND, NOT A WISH. A wish is an average,
      #    and a block of nodes pushed into contact places itself at the
      #    average of what its members wanted -- so a node that wished itself
      #    clear of a box got that wish averaged away by the neighbours it
      #    merged with, and the box swallowed it anyway. As a bound it moves
      #    the whole block instead.
      #
      #    Which side it goes is the ORDER's to say: a node ordered before
      #    the group goes left of it, one ordered after goes right. Deciding
      #    by which half of the box the node happens to sit in ignores the
      #    order, and putting the order back then drags it across the group --
      #    which is how `src/watchdog` ended up on the far side of `web` from
      #    the node it points at.
      (def low @{})
      (def high @{})
      (eachp [i name] names
        (unless (and group-of (group-of name))
          (def half (/ (widths name) 2))
          (each [key x0 x1] here
            (def mates (seq [[j m] :pairs names
                             :when (= key (and group-of (group-of m)))] j))
            (def before? (if (empty? mates)
                           (< (want name) (/ (+ x0 x1) 2))
                           (< i (min ;mates))))
            (if before?
              (put high name (min (get high name math/inf) (- x0 half gap)))
              (put low name (max (get low name (- math/inf)) (+ x1 half gap)))))))

      # A BOX TAKES UP THE ROOM A BOX TAKES UP. `settle` is told each member
      # is `inset` wider on both sides than the node itself, because that is
      # the rectangle the renderer draws, and the extra is what leaves
      # somewhere for a node ordered between two groups to stand.
      #
      # Without it the boxes are packed as though they were their bare
      # members, and two can end up 29 units apart with a 65-unit node
      # ordered between them: `tools/replay`, floored right of `src.term` and
      # ceilinged left of `web`, the two bounds flatly contradicting each
      # other. No eviction can solve that, because the room was never made.
      #
      # The member is then re-centred inside its widened slot, so the padding
      # buys space around the group without moving the group.
      # A MEMBER STANDS FOR ITS WHOLE BOX. A group two members wide on the
      # rank below is that wide here too, because the rectangle spans both --
      # so the one member on this rank has to take up the room the box takes
      # up, or its neighbours pack against the NODE and end up inside the
      # BOX. `src/stamp` sat right against `src/term/pty`, which was the only
      # `src.term` member on its rank, and was swallowed by the part of the
      # box that reached over from the two members on the rank beneath.
      #
      # Sharing the span among the members present means two members on a
      # rank still occupy it exactly once between them.
      (def members-here @{})
      (when group-of
        (each n names
          (when-let [key (group-of n)]
            (put members-here key (+ 1 (get members-here key 0))))))
      (defn padded [name]
        (if-let [key (and group-of (group-of name))]
          (let [s (get span key)
                whole (if s (+ (- (s :x1) (s :x0)) (* 2 inset)) (widths name))
                share (/ whole (max 1 (get members-here key 1)))]
            (max (+ (widths name) (* 2 inset)) share))
          (widths name)))
      (defn seat [lo hi]
        (settle names (fn [n] (want n)) padded gap
                (fn [n] (and group-of (group-of n) true))
                lo hi))
      (def first-pass (seat (fn [n] (low n)) (fn [n] (high n))))

      # THE BOUNDS ARE RE-DERIVED FROM WHERE THE MEMBERS ACTUALLY LANDED.
      # They were computed from the claim as it stood BEFORE this layer was
      # seated, and seating moves the members -- so the box slides out from
      # under the node that was just cleared of it, and the eviction misses
      # by however far the members shifted. Measuring the box again from the
      # placed members and re-seating closes that gap.
      #
      # IT IS THE WHOLE BOX, over every rank, not just the members on this
      # one. A group two members wide on the rank below is that wide here
      # too, because the rectangle spans both -- so measuring only the
      # member on this layer left `src/stamp` and `src/watchdog` clear of
      # `src/term/pty` and still 37 units inside the box that reaches over
      # them from the rank beneath.
      (when group-of
        (def edge @{})
        (eachp [name at] first-pass
          (when-let [key (group-of name)]
            (def half (/ (widths name) 2))
            (unless (edge key) (put edge key @{:x0 math/inf :x1 (- math/inf)}))
            (def e (edge key))
            (put e :x0 (min (e :x0) (- at half)))
            (put e :x1 (max (e :x1) (+ at half)))))
        # The re-derived box only TIGHTENS the bounds computed before seating;
        # it never replaces them. The bound from `here` covers the group over
        # every rank it spans, and this one sees only the members on this
        # layer -- so replacing would drop the width a group two-wide on the
        # rank below contributes, and `src/stamp` and `src/watchdog` would
        # clear `src/term/pty` while still sitting inside the box that
        # reaches over them from beneath.
        (eachp [key e] edge
          (eachp [i name] names
            (unless (group-of name)
              (def half (/ (widths name) 2))
              (def x0 (- (e :x0) inset))
              (def x1 (+ (e :x1) inset))
              (def mates (seq [[j m] :pairs names :when (= key (group-of m))] j))
              (if (and (not (empty? mates)) (< i (min ;mates)))
                (put high name (min (get high name math/inf) (- x0 half gap)))
                (put low name (max (get low name (- math/inf)) (+ x1 half gap))))))))

      # Both bounds together can be unsatisfiable -- a node ordered between
      # two groups that have closed up around it. The floor wins, because a
      # box holding a node it does not group is the defect that has to be
      # impossible; the crowding it causes is caught by the separation
      # `settle` does anyway.
      (eachp [name lo] low
        (when (and (get high name) (> lo (get high name)))
          (put high name nil)))

      (def placed (if group-of
                    (seat (fn [n] (low n)) (fn [n] (high n)))
                    first-pass))
      (eachp [name at] placed (put x name at))))

  # Down and up, a few times: a layer can only be seated against a layer that
  # has already been seated, so the two directions have to alternate.
  #
  # RE-CENTRED AFTER EACH ROUND, or the picture walks. A block that cannot
  # have what it wants is placed at the nearest position that works, and
  # `settle` resolves ties by pushing right -- so every round nudged the
  # whole drawing a little further that way and the next round measured from
  # there. The `web` group marched right by about a hundred units per round
  # and never converged. Shifting every layer by the same amount cannot
  # change a single relative position, so this costs the layout nothing and
  # makes it settle.
  (for pass 0 5
    (round :down)
    (round :up)
    (def all (values x))
    (unless (empty? all)
      (def drift (/ (+ (min ;all) (max ;all)) 2))
      (eachp [name at] x (put x name (- at drift)))))
  x)

#
# 4. The unconnected.
#

(defn shelve
  ``Positions for the nodes that have no edges, as {name {:x :y}}.

  They are packed into rows beneath the graph rather than left in the top
  rank, where they would set the width of a picture they are not part of.
  `width` bounds a row so a long tail wraps instead of running off to the
  right; the rows are centred on zero like every layer above them.

  A GROUP STILL HOLDS HERE. The renderer draws a box around the members it
  finds on a row, so members have to stay adjacent on the shelf for exactly
  the reason they do on a layer -- otherwise the box swallows whatever got
  between them. `group-of` is the same test `cohere` uses.``
  [loose top measure gap layer-gap &opt width group-of]
  (default width 900)
  (default group-of (fn [_] nil))
  (def out @{})
  (unless (empty? loose)
    # Grouped members first, in group order, so a group lands contiguously;
    # the ungrouped keep their input order after them.
    (def seen @[])
    (def members @{})
    (def rest @[])
    (each name loose
      (if-let [key (group-of name)]
        (do
          (unless (find |(= $ key) seen) (array/push seen key))
          (put members key (array/push (or (members key) @[]) name)))
        (array/push rest name)))
    (def sorted (array ;(mapcat |(members $) seen) ;rest))

    # Rows next, so each one can be centred once its members are known.
    (def rows @[@[]])
    (var used 0)
    (each name sorted
      (def w (measure name))
      (def row (last rows))
      (when (and (not (empty? row)) (> (+ used gap w) width))
        (array/push rows @[])
        (set used 0))
      (array/push (last rows) name)
      (set used (+ used (if (empty? row) 0 gap) w)))
    (eachp [r row] rows
      (var span (- gap))
      (each name row (+= span (+ (measure name) gap)))
      (var cursor (/ span -2))
      (def y (+ top (* r layer-gap)))
      (each name row
        (def half (/ (measure name) 2))
        (put out name {:x (+ cursor half) :y y})
        (set cursor (+ cursor (measure name) gap)))))
  out)

#
# The layout proper.
#

(defn place
  ``Positions for `graph`, as {name {:x :y}}, plus the routing a renderer
  needs for edges that span more than one layer.

  Returns {:points {name {:x :y}} :routes {[from to] [[x y] ...]}}. The
  routes are the bend points a long edge passes through -- the dummy chain
  every layered layout builds -- so an edge crossing three layers goes
  AROUND the nodes in between instead of straight through them, which is
  the single most visible thing graphviz did that a force layout does not.

  THE DUMMIES ARE REAL NODES HERE, and that is the difference between a
  picture that reads and one that does not. They used to be invented after
  placement by interpolating x along the straight line -- which put the bend
  points exactly where the line already was, so an edge spanning three
  layers still went THROUGH whatever sat between its ends. Measured on this
  tool's own graph, 26 of 42 edges crossed an unrelated node.

  A dummy that exists BEFORE ordering takes part in the crossing sweep and
  gets separated by `place-x` like anything else, so the edge is given a
  column of its own on every layer it crosses and the nodes there move aside
  for it. That is why a dummy is measured too: its width is the room the
  edge needs, not zero.

  `measure` is a function from a node name to its drawn width, so the
  renderer's idea of how wide a label is reaches the layout that has to
  leave room for it.``
  [graph &opt opts]
  (default opts {})
  (def tuning (merge (table ;(kvs defaults)) opts))
  (def nodes (get graph :nodes []))
  (def edges (get graph :edges []))
  (def all-names (map |($ :name) nodes))
  (def measure (or (opts :measure) (fn [_] 108)))

  # THE UNCONNECTED ARE LAID OUT SEPARATELY, and they have to be, because
  # they have no relationships for a layered layout to express. A node with
  # no edges gets ranked 0 like any other source and then sits in the top
  # row taking up width -- on this tool's own graph the five parser files
  # are exactly that, and they were 413 units of the widest rank while
  # saying nothing about the dependencies the picture is drawing.
  #
  # A node left with no edges STAYS ON THE GRAPH -- see the README; it says
  # "this is here and nothing you are looking at uses it", which is a fact
  # about the picture rather than a defect in it. So they are not dropped,
  # they are shelved: packed into rows under the graph, where they read as
  # the list they are.
  (def touched @{})
  (each [from to] edges (put touched from true) (put touched to true))
  (def names (filter |(touched $) all-names))
  (def loose (filter |(not (touched $)) all-names))

  (if (empty? names)
    # Nothing is connected: the shelf is the whole picture.
    {:points (shelve loose 0 measure (tuning :node-gap) (tuning :layer-gap)
                     nil (opts :group-of))
     :routes @{}}
    (do
      (def [layer back] (rank names edges))

      # The dummy chains. One per edge spanning more than one layer, each a
      # list of [name layer] the edge is threaded through. The name is a
      # tuple rather than a string so it can never collide with a real node.
      (def chains @{})
      (def dummy-layer @{})
      (each [from to] edges
        (when (and (layer from) (layer to) (not= from to))
          (def span (- (layer to) (layer from)))
          (when (> (math/abs span) 1)
            (def stride (if (pos? span) 1 -1))
            (def chain @[])
            (var at (+ (layer from) stride))
            (while (not= at (layer to))
              (def name [:bend from to at])
              (put dummy-layer name at)
              (array/push chain name)
              (set at (+ at stride)))
            (put chains [from to] chain))))

      # Neighbour lists, over the ranked (acyclic) view: `up` is what sits
      # above a node, `down` is what sits below it. A long edge contributes
      # its CHAIN rather than itself, so every link spans exactly one layer
      # and the sweeps below see a proper layered graph.
      (def up @{})
      (def down @{})
      (each name names (put up name @[]) (put down name @[]))
      (eachp [name _] dummy-layer (put up name @[]) (put down name @[]))
      (defn link [a b]
        (array/push (down a) b)
        (array/push (up b) a))
      (each [from to] edges
        (when (and (get up from) (get up to) (not= from to))
          # A reversed edge is ordered by where it actually got ranked, not
          # by how it was written, or the crossing pass fights the ranking.
          (def [a b] (if (< (layer from) (layer to)) [from to] [to from]))
          (if-let [chain (chains [from to])]
            # The chain runs from `from` to `to`; walk it in ranked order so
            # every link points down the page.
            (let [ordered (if (< (layer from) (layer to)) chain (reverse chain))]
              (link a (first ordered))
              (for i 0 (- (length ordered) 1)
                (link (ordered i) (ordered (+ i 1))))
              (link (last ordered) b))
            (link a b))))

      # Layers, as {index [names]}, in input order to start with -- dummies
      # included, since they are ordinary members of their layer from here on.
      (def layers @{})
      (each name names
        (def index (layer name))
        (put layers index (array/push (or (layers index) @[]) name)))
      (eachp [name index] dummy-layer
        (put layers index (array/push (or (layers index) @[]) name)))

      # THE SWEEP KNOWS ABOUT GROUPS, so there is one pass here rather than a
      # sweep followed by a fight with it. `order` scores a group's members as
      # one node (see its docstring), which seats the group and everything
      # around it in the same decision -- where cohering afterwards had
      # already fixed the ungrouped nodes' positions before the group moved.
      #
      # `cohere` still runs, and still last, because scoring a group together
      # makes its members *want* the same slot without guaranteeing they get
      # it: a member whose own median lands elsewhere can still be separated
      # from the rest by the tiebreak. Cohesion is the guarantee; the shared
      # median is what makes it cheap.
      (def group-of (when-let [of (opts :group-of)]
                      (fn [name] (when (string? name) (of name)))))
      (def swept (order layers
                        (fn [name] (get up name []))
                        (fn [name] (get down name []))
                        (tuning :sweeps)
                        group-of
                        (fn [name] (not (nil? (dummy-layer name))))))
      (def ordered (if group-of (cohere swept group-of) swept))

      # A dummy is measured as the room its edge needs to pass, which is a
      # narrow column rather than nothing: at zero width the separation pass
      # would let a chain sit flush against a node and the edge would graze
      # it.
      (def widths (widths-of names measure))
      (eachp [name _] dummy-layer (put widths name (tuning :bend-width)))

      # REFINE BY THE PICTURE, not by the heuristic. `order` reasons in
      # ordinal space and cannot see a lane between two nodes or an edge
      # clipping an ellipse; `cost` sees exactly those and nothing else. So
      # the sweep's answer is taken as the starting point -- it is a good
      # one -- and adjacent pairs are swapped only where actually drawing
      # the result is better.
      #
      # STRICTLY BETTER, so this cannot make the picture worse than the
      # ordering it was handed. That is what makes it safe to bolt onto a
      # layout that is already close: the worst case is that it changes
      # nothing.
      (defn place-with [layout]
        (place-x layout
                 (fn [name] (get up name []))
                 (fn [name] (get down name []))
                 widths
                 (tuning :node-gap)
                 (fn [name] (not (nil? (dummy-layer name))))
                 (fn [name where]
                   (when-let [on (dummy-layer name)]
                     (def [_ from to _] name)
                     (def a (layer from))
                     (def b (layer to))
                     (when (and a b (not= a b) (where from) (where to))
                       (def t (/ (- on a) (- b a)))
                       (+ (where from) (* t (- (where to) (where from)))))))
                 (when-let [of (opts :group-of)]
                   (fn [name] (when (string? name) (of name))))
                 (tuning :group-inset)))

      # Every edge as the polyline it will actually be drawn as: its ends
      # plus whatever bends its chain has, in rank order.
      (defn paths-for [xs]
        (def out @{})
        (each [from to] edges
          (when (and (xs from) (xs to) (not= from to))
            (def bends (or (chains [from to]) []))
            (def line @[[(xs from) (* (layer from) (tuning :layer-gap))]])
            (each b bends
              (array/push line [(xs b) (* (dummy-layer b) (tuning :layer-gap))]))
            (array/push line [(xs to) (* (layer to) (tuning :layer-gap))])
            (put out [from to] line)))
        out)

      (defn positions-of [xs]
        (def out @{})
        (each name names
          (when (xs name)
            (put out name {:x (xs name) :y (* (layer name) (tuning :layer-gap))})))
        out)

      # The boxes as the renderer will draw them, so `cost` can count an
      # edge cutting one. Same shape the eviction uses: the members' extent
      # plus the inset the renderer adds.
      (defn boxes-of [xs]
        (def out @[])
        (when group-of
          (def span @{})
          (each name names
            (when-let [key (group-of name)]
              (when (xs name)
                (def half (/ (widths name) 2))
                (def y (* (layer name) (tuning :layer-gap)))
                (unless (span key)
                  (put span key @{:x0 math/inf :x1 (- math/inf)
                                  :y0 math/inf :y1 (- math/inf) :who @[]}))
                (def e (span key))
                (put e :x0 (min (e :x0) (- (xs name) half)))
                (put e :x1 (max (e :x1) (+ (xs name) half)))
                (put e :y0 (min (e :y0) (- y 40)))
                (put e :y1 (max (e :y1) (+ y 40)))
                (array/push (e :who) name))))
          (eachp [_ e] span
            (def pad (tuning :group-inset))
            (array/push out [(- (e :x0) pad) (- (e :y0) pad)
                             (+ (e :x1) pad) (+ (e :y1) pad)
                             (e :who)])))
        out)

      (defn score-of [layout]
        (def xs (place-with layout))
        (cost (positions-of xs) widths (paths-for xs) (boxes-of xs)))

      (def refined (table/clone ordered))
      (eachp [index row] refined (put refined index (array ;row)))
      # BOUNDED, because this is the expensive pass. Every candidate swap
      # re-places the whole graph and re-scores it, and scoring compares
      # every edge segment with every other -- so the work grows as roughly
      # the fourth power of the graph. On sixty dense nodes that was
      # twenty-eight seconds for a picture the sweep draws in twenty
      # milliseconds.
      #
      # A dependency graph a person reads is small; a big one is a wall of
      # spaghetti no reordering rescues. So refinement is for the graphs it
      # can help, and anything larger keeps the sweep's answer, which is the
      # answer this had before the pass existed.
      # WHERE THE DEFECTS ARE, not every adjacent pair. Trying them all meant
      # a full re-placement and re-score for each -- a second on twenty
      # nodes, five on forty -- for a picture the sweep draws in twenty
      # milliseconds, and this tool redraws on every keystroke in the config.
      # A swap can only help where something is already wrong, so the
      # candidates are the entities an offending edge touches: the two ends
      # of an edge that clips a node, the node it clips, and the ends of a
      # pair that cross.
      # EVERY KIND OF DEFECT NOMINATES ITS OWN CANDIDATES. Looking only for
      # edges through nodes made the pass blind to the other two thirds of
      # what `cost` measures: `src/json -> src/graph` crossing
      # `src/state -> src/graph` clips nothing, so neither edge was ever
      # proposed for a swap, and neither were the edges cutting a group's
      # box. The score could see those and the search could not reach them.
      (defn troubled [xs]
        (def out @{})
        (def places (positions-of xs))
        (def lines (paths-for xs))
        (defn blame [key]
          (put out (key 0) true)
          (put out (key 1) true))

        # 1. An edge through a node it has nothing to do with -- the node is
        #    a candidate too, since moving IT is often the cheaper fix.
        (eachp [key path] lines
          (def [from to] key)
          (eachp [name p] places
            (unless (or (= name from) (= name to))
              (def rx (max 1 (/ (widths name) 2)))
              (for i 0 (- (length path) 1)
                (def a (path i))
                (def b (path (+ i 1)))
                (for s 1 12
                  (def t (/ s 12))
                  (def px (+ (a 0) (* t (- (b 0) (a 0)))))
                  (def py (+ (a 1) (* t (- (b 1) (a 1)))))
                  (def dx (/ (- px (p :x)) rx))
                  (def dy (/ (- py (p :y)) 34))
                  (when (< (+ (* dx dx) (* dy dy)) 1)
                    (put out name true) (blame key)))))))

        # 2. Two edges that cross each other. Both are candidates: which of
        #    them should move is exactly what trying the swap settles.
        (def segs @[])
        (eachp [key path] lines
          (for i 0 (- (length path) 1)
            (array/push segs [(path i) (path (+ i 1)) key])))
        (defn meets [[p1 p2 _] [p3 p4 _]]
          (def d (- (* (- (p2 0) (p1 0)) (- (p4 1) (p3 1)))
                    (* (- (p2 1) (p1 1)) (- (p4 0) (p3 0)))))
          (if (< (math/abs d) 0.000001)
            false
            (let [t (/ (- (* (- (p3 0) (p1 0)) (- (p4 1) (p3 1)))
                          (* (- (p3 1) (p1 1)) (- (p4 0) (p3 0)))) d)
                  u (/ (- (* (- (p3 0) (p1 0)) (- (p2 1) (p1 1)))
                          (* (- (p3 1) (p1 1)) (- (p2 0) (p1 0)))) d)]
              (and (> t 0.02) (< t 0.98) (> u 0.02) (< u 0.98)))))
        (for i 0 (length segs)
          (for j (+ i 1) (length segs)
            (unless (= ((segs i) 2) ((segs j) 2))
              (when (meets (segs i) (segs j))
                (blame ((segs i) 2))
                (blame ((segs j) 2))))))

        # 3. An edge cutting a group's box. The members are candidates as
        #    well as the edge, since sliding the group is sometimes what
        #    opens the lane.
        (when group-of
          (def boxes @{})
          (eachp [name p] places
            (when-let [key (group-of name)]
              (def half (/ (widths name) 2))
              (unless (boxes key)
                (put boxes key @{:x0 math/inf :x1 (- math/inf)
                                 :y0 math/inf :y1 (- math/inf) :who @[]}))
              (def e (boxes key))
              (put e :x0 (min (e :x0) (- (p :x) half)))
              (put e :x1 (max (e :x1) (+ (p :x) half)))
              (put e :y0 (min (e :y0) (- (p :y) 40)))
              (put e :y1 (max (e :y1) (+ (p :y) 40)))
              (array/push (e :who) name)))
          (eachp [key e] boxes
            (eachp [pair path] lines
              (unless (or (= key (group-of (pair 0))) (= key (group-of (pair 1))))
                (var inside false)
                (for i 0 (- (length path) 1)
                  (def a (path i))
                  (def b (path (+ i 1)))
                  (for s 0 13
                    (def t (/ s 12))
                    (def px (+ (a 0) (* t (- (b 0) (a 0)))))
                    (def py (+ (a 1) (* t (- (b 1) (a 1)))))
                    (when (and (> px (e :x0)) (< px (e :x1))
                               (> py (e :y0)) (< py (e :y1)))
                      (set inside true))))
                (when inside
                  (blame pair)
                  (each m (e :who) (put out m true)))))))
        out)

      (when (and (opts :refine)
                 (<= (length names) (tuning :refine-limit)))
        (var best (score-of refined))
        (var moved true)
        (var rounds 0)
        # A HARD CEILING ON THE WORK, in candidate swaps. Each one re-places
        # the whole graph and re-scores it -- about fifteen milliseconds on
        # this tool's own graph -- so the budget IS the time this pass costs.
        # "Where the defects are" narrows the candidates well on most graphs
        # and a graph can defeat it: forty-four nodes with groups put most of
        # the layout in the troubled set and ran for eleven seconds without
        # one. The budget is what makes the pass safe to run unconditionally,
        # since it stops when spent and keeps the best ordering it found --
        # which is never worse than the one it started from.
        # The budget is in candidate swaps, and each one re-places and
        # re-scores the whole graph -- so it IS the time this pass costs,
        # and the cost of one swap grows with the graph. Scaling the budget
        # down as the graph grows keeps the total roughly flat: a small
        # graph gets a thorough search, a big one gets what it can afford.
        (var budget (max 20 (math/floor (/ 2600 (max 1 (length names))))))
        (while (and moved (< rounds 3) (pos? budget))
          (set moved false)
          (++ rounds)
          (def hot (troubled (place-with refined)))
          (each index (sort (keys refined))
            (def row (refined index))
            (for i 0 (- (length row) 1)
              # A group's members stay put: their order IS the box, and
              # `cohere` has already settled it.
              (def a (row i))
              (def b (row (+ i 1)))
              (defn implicated [n]
                (or (hot n)
                    (and (not (string? n)) (or (hot (n 1)) (hot (n 2))))))
              (unless (or (not (pos? budget))
                          (and group-of (group-of a)) (and group-of (group-of b)))
                (-- budget)
                (put row i b)
                (put row (+ i 1) a)
                (def try (score-of refined))
                (if (< try (- best 0.0001))
                  (do (set best try) (set moved true))
                  (do (put row i a) (put row (+ i 1) b))))))))

      (def x (place-x refined
                      (fn [name] (get up name []))
                      (fn [name] (get down name []))
                      widths
                      (tuning :node-gap)
                      (fn [name] (not (nil? (dummy-layer name))))
                      # A bend carries its own edge in its name, so the line
                      # it should be sitting on is a lerp between where that
                      # edge's two ends have ended up. `at` is the table of
                      # positions as they stand, which the pass is still
                      # moving -- so this is read fresh on every sweep.
                      (fn [name where]
                        (when-let [on (dummy-layer name)]
                          (def [_ from to _] name)
                          (def a (layer from))
                          (def b (layer to))
                          (when (and a b (not= a b) (where from) (where to))
                            (def t (/ (- on a) (- b a)))
                            (+ (where from)
                               (* t (- (where to) (where from)))))))
                      # Only real nodes belong to a group; a bend is passing
                      # through and must not be pulled into somebody's box.
                      (when-let [of (opts :group-of)]
                        (fn [name] (when (string? name) (of name))))
                      # How far outside its members the renderer draws the
                      # box. An option rather than an import: this file
                      # deliberately knows nothing about SVG, so the seam
                      # passes it down (see src/layout.janet).
                      (tuning :group-inset)))

      (def points @{})
      (each name names
        (put points name {:x (x name)
                          :y (* (layer name) (tuning :layer-gap))}))

      # The unconnected go on a shelf ABOVE the graph, which is where a
      # reader looks first. They are what the scan found and could not place
      # in the dependency structure, so they are read and dismissed on the
      # way in rather than discovered under the picture after it.
      #
      # The shelf is laid out from its own top downward, so its LAST row has
      # to land clear of rank 0 -- the height it needs is known only after
      # the rows are packed, which is why `shelve` is asked once and shifted
      # rather than positioned in one go.
      (unless (empty? loose)
        (def shelf (shelve loose 0 measure (tuning :node-gap)
                           (tuning :layer-gap) nil (opts :group-of)))
        (def rows (+ 1 (/ (max ;(map |($ :y) (values shelf))) (tuning :layer-gap))))
        (def lift (* (+ rows 0.35) (tuning :layer-gap)))
        (eachp [name p] shelf
          (put points name {:x (p :x) :y (- (p :y) lift)})))

      # Routes: where the edge's own chain actually landed. Placement has
      # already pushed those bends clear of the nodes sharing their layers,
      # so reading the positions back is the whole of the routing.
      (def routes @{})
      (eachp [pair chain] chains
        (def [from to] pair)
        (when (and (points from) (points to))
          (put routes pair
               (map (fn [name] [(x name) (* (dummy-layer name) (tuning :layer-gap))])
                    chain))))

      {:points points :routes routes :back back})))
