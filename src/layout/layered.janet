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

  Returns {layer [names, in order]}.``
  [layers up down sweeps]
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
        (def scored (map (fn [name]
                           [(median-of (if (= pick :down) (up name) (down name))
                                       positions)
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
        (def placed (sorted-by |[($ 0) ($ 1)] movable))
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
# 3. Placement.
#

(defn- widths-of
  "Each node's drawn width, so placement can respect a long label."
  [names measure]
  (def out @{})
  (each name names (put out name (measure name)))
  out)

(defn place-x
  ``An x for every node, layer by layer.

  Each node is pulled toward the average x of its neighbours in the layer
  above, then the layer is swept left-to-right to push apart anything that
  now overlaps. Repeated a few times, this is the priority method, and it is
  what makes a parent sit over the middle of its children instead of every
  layer being packed flush left.

  `bend?` says whether a name is one of the bend points a long edge is
  threaded through rather than a real node, and `aim` answers the x such a
  bend would sit at if its edge ran perfectly straight -- see the
  straightening pass at the end. `group-of` answers a node's group, so a
  group can be stacked over itself and boxed with one rect.``
  [ordered up down widths gap &opt bend? aim group-of]
  (default bend? (fn [_] false))
  (default aim (fn [_ _] nil))
  (def x @{})
  # A first pass: pack each layer left to right, so everything has a value.
  #
  # CENTRED ON ZERO, not packed from it. Packing every layer flush left made
  # the widest layer set the left edge and left the narrow ones stranded
  # under its first few nodes -- an eighteen-node top row over a one-node
  # bottom row came out as a diagonal smear rather than a tree. Centring
  # each layer before the pull passes start gives them a common axis to be
  # pulled away from.
  (def indexes (sort (keys ordered)))
  (each index indexes
    (var span (- gap))
    (each name (ordered index) (+= span (+ (widths name) gap)))
    (var cursor (/ span -2))
    (each name (ordered index)
      (def half (/ (widths name) 2))
      (put x name (+ cursor half))
      (set cursor (+ cursor (widths name) gap))))

  (defn centre-on [names]
    (def known (filter |(x $) names))
    (if (empty? known)
      nil
      (/ (sum (map |(x $) known)) (length known))))

  (defn compact [index pick]
    (def names (ordered index))
    # Desired positions from the adjacent layer.
    (def wanted (map (fn [name]
                       (or (centre-on (if (= pick :down) (up name) (down name)))
                           (x name)))
                     names))
    (each [i name] (pairs names) (put x name (wanted i)))

    # SEPARATE LEFT TO RIGHT, ONCE. Each node is pushed right just far enough
    # to clear its left neighbour, which makes the layer non-overlapping in a
    # single pass and cannot reintroduce an overlap behind itself.
    #
    # The obvious second sweep right-to-left is NOT here, and that was a bug
    # while it was: enforcing the same constraint from the other end pushes
    # nodes back left into the neighbours the first sweep had just cleared,
    # so a dense layer came out overlapping despite both passes "succeeding".
    # The rightward bias it was meant to cancel is undone by re-centring
    # below instead, which cannot violate the constraint because it moves the
    # whole layer at once.
    (var edge-x nil)
    (each name names
      (def half (/ (widths name) 2))
      (when (and edge-x (< (- (x name) half) edge-x))
        (put x name (+ edge-x half)))
      (set edge-x (+ (x name) half gap)))
    # Re-centre the layer on where it WANTED to be. Shifting every node by
    # the same amount preserves both the order and the separation just
    # established, and it is what stops a run of pull-then-separate rounds
    # from marching the whole picture rightward.
    (def drift (- (/ (sum wanted) (max 1 (length wanted)))
                  (/ (sum (map |(x $) names)) (max 1 (length names)))))
    (each name names (put x name (+ (x name) drift))))

  # STACK EACH GROUP OVER ITSELF.
  #
  # `cohere` put a group at the same place in the running ORDER of every
  # layer it appears on, which is as far as ordering can get it: the layers
  # differ in what else they hold, so the same ordinal slot is still a
  # different x. A group's members then sit above one another only roughly,
  # and the one box drawn around them stretches sideways to reach them all --
  # swallowing whatever sits in the gap.
  #
  # A GROUP'S FOOTPRINT IS RESERVED ON EVERY RANK IT SPANS. Aligning members
  # into one column is not enough on its own: a group two wide on one rank
  # and one wide on the next still covers the full width of the wider rank,
  # and a stranger on the narrow rank falls into the corner of the box. That
  # is exactly how `src.term` kept swallowing `src_stamp`.
  #
  # So the pass works out the group's x-range over all its members, then
  # clears that range on every layer between its topmost and lowest member:
  # anything ungrouped sitting inside gets pushed to whichever side it is
  # nearer. The layer grows rather than the box telling a lie.
  #
  # This is not slack-only, and cannot be -- no amount of shuffling within
  # the existing gaps moves a node out of a range it is sitting in the middle
  # of.
  #
  # IT RUNS BETWEEN THE PULL ROUNDS, not after them. Run once at the end it
  # left every node it moved wherever the eviction dropped it, with nothing
  # to draw it back toward its neighbours: `src/parser` ended up 317 units
  # from `src/scan`, the only node it connects to, and its edge crossed the
  # picture to get there. Alternating the two lets a layer settle again after
  # each adjustment, so the claim is honoured AND the nodes go back to
  # sitting over their work.
  (defn regroup []
    (when group-of
      # Where each group is, and which layers it spans.
      (def span @{})
      (eachp [index row] ordered
        (each name row
          (when-let [key (group-of name)]
            (def half (/ (widths name) 2))
            (unless (span key)
              (put span key @{:x0 math/inf :x1 (- math/inf)
                              :top math/inf :low (- math/inf)}))
            (def s (span key))
            (put s :x0 (min (s :x0) (- (x name) half)))
            (put s :x1 (max (s :x1) (+ (x name) half)))
            (put s :top (min (s :top) index))
            (put s :low (max (s :low) index)))))

      (each index indexes
        (def names (ordered index))
        # Every group whose vertical extent covers this layer claims its
        # x-range here, whether or not it has a member on this row.
        (def claims @[])
        (eachp [key s] span
          (when (and (<= (s :top) index) (<= index (s :low)))
            (array/push claims [key (s :x0) (s :x1)])))
        (unless (empty? claims)
          (each name names
            (unless (group-of name)
              (def half (/ (widths name) 2))
              (each [_ x0 x1] claims
                # Overlapping the claim at all is enough to be inside the
                # box once the renderer insets it.
                (when (and (< (- (x name) half) x1) (> (+ (x name) half) x0))
                  # OUT THE SIDE ITS EDGES POINT. Evicting by which half of
                  # the box the node happens to sit in ignores the only thing
                  # that says where it belongs -- and sent `src/parser` out
                  # the right side of `src.term` when the one node it
                  # connects to, `src/scan`, was away to the left. Its edge
                  # then crossed the group to get there. The neighbours it is
                  # joined to decide; only a node with none falls back to
                  # whichever side is nearer.
                  (def near (array ;(up name) ;(down name)))
                  (def pull (if (empty? near)
                             (x name)
                             (/ (sum (map |(or (x $) (x name)) near))
                                (length near))))
                  (put x name
                       (if (< pull (/ (+ x0 x1) 2))
                         (- x0 half gap)      # its work is to the left
                         (+ x1 half gap)))))))) # its work is to the right

        # Re-separate the layer, treating a claimed range as occupied.
        #
        # The separation has to know about the claims or it undoes the
        # eviction on the spot: packing left to right walks a node straight
        # back into the gap the previous step just cleared it out of, and the
        # box swallows it again.
        #
        # IN THE LAYER'S OWN ORDER, not sorted by x. Sorting by x lets a
        # group's column silently rewrite the ordering the crossing sweep
        # decided: `src.term` took a column left of `src/parser` even though
        # the order put `src/parser` first, so separation had to shove
        # `src/parser` right, past the whole group, to keep them apart -- and
        # its one edge then crossed the group to reach `src/scan`. Walking
        # the order instead means a member that would have to jump a
        # neighbour to reach its column simply does not get there.
        (var edge-x nil)
        (each name names
          (def half (/ (widths name) 2))
          (when (and edge-x (< (- (x name) half) edge-x))
            (put x name (+ edge-x half)))
          (unless (group-of name)
            (each [_ x0 x1] claims
              (when (and (< (- (x name) half) x1) (> (+ (x name) half) x0))
                (put x name (+ x1 half gap)))))
          (set edge-x (+ (x name) half gap))))

      # Members converge on their group's centre, so the footprint tightens
      # rather than drifting wider every pass.
      (eachp [key s] span
        (def mid (/ (+ (s :x0) (s :x1)) 2))
        (each index indexes
          (def here (filter |(= key (group-of $)) (ordered index)))
          (when (= 1 (length here))
            (put x (first here) mid))))))

  (for pass 0 4
    (each index (slice indexes 1) (compact index :down))
    (each index (reverse (slice indexes 0 -2)) (compact index :up)))

  # A FINAL SEPARATION, over every layer, pulling nothing.
  #
  # The rounds above alternate pull-then-separate, and a layer's last touch
  # is not always the separating half: the down sweep skips layer 0 and the
  # up sweep skips the last one, so a middle layer can end a round having
  # been pulled toward a neighbour and re-centred without being swept again.
  # That is where the overlaps came from -- two of them, on the one layer
  # whose ordering made it land that way, which is exactly the kind of bug
  # that renders fine on a small graph and not on a real one. This pass
  # costs nothing and makes non-overlap a property of the OUTPUT rather than
  # of the iteration order.
  (each index indexes
    (var edge-x nil)
    (each name (ordered index)
      (def half (/ (widths name) 2))
      (when (and edge-x (< (- (x name) half) edge-x))
        (put x name (+ edge-x half)))
      (set edge-x (+ (x name) half gap))))

  # STRAIGHTEN THE CHAINS, INTO SLACK ONLY.
  #
  # A long edge reads as one line or it reads as a zigzag, and the zigzag is
  # what put it through the nodes it was meant to route around: a bend pushed
  # off its line by whatever sat left of it on that layer sends the segment
  # below it back across the layer diagonally.
  #
  # Priority placement -- pinning the bend and making real nodes give way --
  # was tried and is not here: it dragged whole layers apart to satisfy one
  # edge and grew the picture by 60% to straighten a handful. This does the
  # cheap half instead. Each bend moves toward the line between its edge's
  # ends, but only as far as the gap to its neighbours already allows, so the
  # layer's order and separation are untouched and the picture cannot grow.
  # A bend with room straightens; one hemmed in stays where it is.
  #
  # Swept a few times, and down then up, because a chain settles a layer at a
  # time: one pass moves each bend toward its neighbours, the next carries
  # that along the chain.
  (for pass 0 6
  (each index (if (even? pass) indexes (reverse indexes))
    (def names (ordered index))
    (eachp [i name] names
      (when (bend? name)
        (def half (/ (widths name) 2))
        (def left (if (> i 0)
                   (let [l (names (- i 1))] (+ (x l) (/ (widths l) 2) gap half))
                   (- math/inf)))
        (def right (if (< i (- (length names) 1))
                     (let [r (names (+ i 1))] (- (x r) (/ (widths r) 2) gap half))
                     math/inf))
        # Where the edge would like this bend: on the straight line between
        # its own two ends. Averaging the neighbouring LINKS instead does
        # nothing useful -- they are bent too, so the average preserves the
        # kink rather than pulling it out.
        (when-let [target (aim name x)]
          (put x name (max left (min right target))))))))

  # THE CLAIM GOES LAST. Every pass above moves nodes -- the final separation
  # and the chain straightening both do -- so applying it any earlier just
  # gets it undone by whatever runs next. Re-applied a few times because each
  # round of eviction shifts the group's own footprint a little.
  (for pass 0 4 (regroup))

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

      (def swept (order layers
                        (fn [name] (get up name []))
                        (fn [name] (get down name []))
                        (tuning :sweeps)))

      # Groups last, so cohesion overrides crossing reduction where the two
      # disagree. That is the right precedence: a couple more crossings is a
      # picture that is harder to read, whereas a box around a node that is
      # not in the group is a picture that is WRONG.
      #
      # BUT THE REST OF THE LAYER GETS TO SETTLE AROUND IT. Cohering once and
      # stopping leaves every ungrouped node where it was before the group
      # moved, which is how `src/parser` ended up ordered after `src.term` on
      # rank 0 while the one node it connects to, `src/scan`, sat away to the
      # left -- its edge then crossed the whole group. Sweeping again after
      # the group has taken its slot lets the median heuristic re-seat
      # everything else around it, and re-cohering keeps the group whole; a
      # few rounds converge.
      (def ordered
        (if-let [group-of (opts :group-of)]
          (do
            (var current (cohere swept group-of))
            (for round 0 3
              (set current (order current
                                  (fn [name] (get up name []))
                                  (fn [name] (get down name []))
                                  2))
              (set current (cohere current group-of)))
            # A LAST UP-SWEEP, then cohere. The top rank has nothing above it,
            # so the down-sweep leaves every node there exactly where it was
            # -- `median-of` answers -1 for a node with no neighbours in the
            # layer it is reading from. Only the up-sweep can seat rank 0 by
            # its children, and that is the one thing `src/parser` needed: its
            # single edge runs down to `src/scan`.
            (set current (order current
                                (fn [name] (get up name []))
                                (fn [name] (get down name []))
                                0))
            (cohere current group-of))
          swept))

      # A dummy is measured as the room its edge needs to pass, which is a
      # narrow column rather than nothing: at zero width the separation pass
      # would let a chain sit flush against a node and the edge would graze
      # it.
      (def widths (widths-of names measure))
      (eachp [name _] dummy-layer (put widths name (tuning :bend-width)))

      (def x (place-x ordered
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
                        (fn [name] (when (string? name) (of name))))))

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
