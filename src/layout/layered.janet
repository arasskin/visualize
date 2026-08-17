(import ./aux)
(import ./simplex)
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
  {:layer-gap 104      # vertical distance between layers
   :node-gap 14        # minimum horizontal gap between neighbours
   :bend-width 8       # the column a through-edge reserves on a layer it crosses
   :bend-gap 3         # between two bends: parallel lines, not labelled boxes
   :group-inset 0      # how far outside its members a group's box is drawn
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
  [names edges &opt group-of]
  (default group-of (fn [_] nil))
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

  # TIGHTEN, by moving every node that can move rather than only the sources.
  #
  # Longest-path ranking is correct and reads badly: it pins everything with
  # nothing above it to layer 0, which on this tool's own graph was seventeen
  # of thirty-three nodes in one row, and that row sets the width of the
  # whole picture. The first fix here dropped each PARENTLESS node to just
  # above its lowest child, which helped and stopped there -- a node in the
  # middle of a chain stayed wherever the longest path had put it even when
  # every one of its edges was longer than it needed to be.
  #
  # WHAT GRAPHVIZ DOES IS MINIMISE TOTAL EDGE LENGTH, by network simplex over
  # a tight spanning tree. The full algorithm maintains that tree with cut
  # values and swaps edges across the negative ones; what is below is the
  # same objective reached by relaxation, which is a great deal shorter and
  # converges to the same place on graphs this shape.
  #
  # Each round, every node moves to the rank that minimises the total length
  # of its own edges -- the median of its neighbours, clamped to what its
  # edges allow (strictly below every parent, strictly above every child).
  # A node whose neighbours pull it nowhere stays. Repeat until nothing
  # moves. Every step strictly reduces total edge length or leaves it equal,
  # so it terminates; the cap is there for the pathological case rather than
  # the expected one.
  (def parents @{})
  (def children @{})
  (each name names (put parents name @[]) (put children name @[]))
  (each [from to] edges
    (when (and (forward from) (forward to) (not (back [from to])) (not= from to))
      (array/push (children from) to)
      (array/push (parents to) from)))

  (var moved true)
  (var rounds 0)
  (while (and moved (< rounds 24))
    (set moved false)
    (++ rounds)
    (each name names
      (def up (parents name))
      (def down (children name))
      (unless (and (empty? up) (empty? down))
        # The window this node may occupy without inverting an edge.
        (def floor (if (empty? up) 0 (+ 1 (max ;(map |(layer $) up)))))
        (def ceiling (if (empty? down)
                       math/int-max
                       (- (min ;(map |(layer $) down)) 1)))
        (when (<= floor ceiling)
          # Where its edges would rather it sat -- and for a sum of absolute
          # distances that is an INTERVAL, not a point. Every rank between
          # the two middle neighbours costs exactly the same total edge
          # length: a node with one parent at rank 0 and one child at rank 6
          # is indifferent across all of 0..6. Snapping to one end of that
          # interval is a choice the objective does not care about and the
          # picture does.
          #
          # This code used to take the upper median -- `(neighbours (div n
          # 2))` -- and that tie-break was measured to be the origin of the
          # long-edge detour six later ports failed to fix: it moved
          # `src/term/client` from beside its sibling to a rank below it,
          # for zero gain in edge length, and the group box grew from two
          # ranks to three. Every long edge on that side has detoured
          # around the taller box since, and the commit that did it showed
          # IMPROVED metrics, because a box is not an ellipse and edges
          # routed around it cross nothing a scorer counts.
          #
          # So: within the interval the edges leave free, do not drift.
          # A node stays where it is unless staying costs actual length; a
          # group member spends the freedom on its siblings instead, which
          # is what keeps a box short without paying a rank of edge for it.
          (def neighbours (sorted (map |(layer $) [;up ;down])))
          (def n (length neighbours))
          (def zone-lo (neighbours (div (- n 1) 2)))
          (def zone-hi (neighbours (div n 2)))
          (def key (group-of name))
          (def ideal
            (if-let [mates (and key (filter |(and (not= $ name) (= key (group-of $)))
                                            names))]
              (if (empty? mates) (layer name)
                # The median of the siblings: where the box would like this
                # member. (The earlier blend that paid up to a rank of edge
                # length for compactness -- the `src/term/client` eight-
                # ranks-away note -- existed to fight the drift above; with
                # the drift gone, free movement inside the zone is enough.)
                (let [ranks (sorted (map |(layer $) mates))]
                  (ranks (div (length ranks) 2))))
              (layer name)))
          (def want (min zone-hi (max zone-lo ideal)))
          (def target (min ceiling (max floor want)))
          (unless (= target (layer name))
            (put layer name target)
            (set moved true))))))

  # NORMALISE. The relaxation can leave the topmost rank above zero -- every
  # node in a component may have shifted down together -- and a picture that
  # starts at rank three has an empty band across the top.
  (when (not (empty? names))
    (def top (min ;(map |(layer $) names)))
    (when (pos? top)
      (each name names (put layer name (- (layer name) top)))))

  # NETWORK SIMPLEX, behind VISUALIZE_SIMPLEX, and still not the default.
  #
  # It reaches the true optimum of the objective the relaxation approximates
  # -- see src/layout/simplex.janet, which was written and left unwired
  # because a better ranking was measurably a worse PICTURE: the drawing
  # packs onto fewer, fuller ranks and the router of the day could not find
  # a way through. Now there is a router that fits curves inside the
  # corridors, which was the stated condition for trying again, so the flag
  # exists to make the comparison one command rather than one branch.
  (when (os/getenv "VISUALIZE_SIMPLEX")
    (def forward-edges
      (filter (fn [[from to]]
                (and (forward from) (forward to)
                     (not (back [from to])) (not= from to)))
              edges))
    (def better (simplex/rank names forward-edges layer))
    (each name names
      (when-let [r (better name)] (put layer name r))))

  [layer back])

#
# 2. Ordering.
#

(defn- median-of
  ``Where a node's neighbours in the adjacent layer sit, as one number.

  -1 for a node with no neighbours there, which the sort reads as "leave it
  where it is" rather than moving it to one end.

  THE BARYCENTRE, not the median, despite the name this has always had. The
  two are the standard pair for one-sided crossing minimisation, and the
  median is reported the weaker across sparse graphs -- Gacho et al. (WCTP
  2025) find it worst of the three heuristics they test, at every layer size
  they try.

  ON THIS TOOL'S OWN GRAPH THE TWO DRAW THE SAME PICTURE: six crossings
  either way, and the `src/select -> src/layout` bend 192 units off its
  straight line under both. The change is kept because the reported
  behaviour on sparse graphs is better and the cost is identical -- both are
  one pass over the neighbours -- not because it fixed anything here.

  The difference is what each does with a lopsided neighbourhood. A node
  pulled by four links on the left and one far right has its median sitting
  among the four, ignoring the fifth entirely; the average feels it and
  shifts. The median's guarantee -- within three times optimal -- is a bound
  the average lacks, and it is not the property that draws a good picture.``
  [neighbours positions]
  (def spots (map |(positions $) (filter |(positions $) neighbours)))
  (if (empty? spots)
    -1
    (/ (sum spots) (length spots))))

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
  [layers up down sweeps &opt group-of bend? from]
  (default group-of (fn [_] nil))
  (default bend? (fn [_] false))
  (default from 0)
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
  #
  # RESUMABLE, because dot's loop needs to drive this one pass at a time and
  # score in between. Calling it repeatedly with `sweeps` of 1 is NOT the
  # same computation: each call would start its own down-then-up sequence, so
  # every pass would begin with a down-sweep and the alternation the median
  # depends on would never happen. `from` says which pass number this is, so
  # a caller stepping through passes gets the same sequence a single call
  # with a bigger `sweeps` would have produced.
  (if (zero? sweeps)
    (sweep (reverse (slice indexes 0 -2)) :up)
    (for pass from (+ from sweeps)
      # Down on even passes, up on odd, so consecutive single-pass calls
      # alternate exactly as the loop inside one call does.
      (if (even? pass)
        (sweep (slice indexes 1) :down)
        (sweep (reverse (slice indexes 0 -2)) :up))))
  current)

(defn- crossings-between
  ``How many times the edges between two ordered layers cross.

  Every pair of links is checked: two links cross when one starts left of the
  other and ends right of it. Quadratic in the number of links, which is
  fine at the sizes `sift` calls it on and is the same counter every
  crossing-minimisation heuristic is built on.``
  [above below neighbours-of]
  (def at @{})
  (eachp [i name] above (put at name i))
  (def links @[])
  (eachp [j name] below
    (each other (neighbours-of name)
      (when-let [i (at other)]
        (array/push links [i j]))))
  (var total 0)
  (for a 0 (length links)
    (for b (+ a 1) (length links)
      (def [a1 a2] (links a))
      (def [b1 b2] (links b))
      (when (or (and (< a1 b1) (> a2 b2))
                (and (> a1 b1) (< a2 b2)))
        (++ total))))
  total)

(defn transpose
  ``Swap adjacent pairs while it helps: dot's transpose, from mincross.c.

  THE PASS WE DID NOT HAVE. The median sweep decides a whole rank from its
  neighbours' averages, and sifting tries one node in every slot -- neither
  asks the cheap exact question "would these two, side by side, be better
  the other way round?", which is what fixes the local tangles a median
  cannot see. dot runs it after every sweep; this runs it after the sweeps,
  which is the same place in the pipeline for a loop that has already
  converged.

  ONLY STRICT IMPROVEMENTS. dot also takes EQUAL-cost swaps on alternate
  passes (`c0 > 0 && reverse && c1 == c0` in transpose_step) as a way out of
  a local minimum, and that is safe there because it keeps the best ordering
  ever seen and restores it. Without that save-aside, taking ties walks the
  ranks in circles -- so this takes only what measurably helps, which is the
  monotone half of dot's rule and cannot make the picture worse.

  Only ranks touched last round are reconsidered: a swap can only change the
  crossings of the ranks it borders.``
  [rows up down &opt fixed? reverse]
  (default fixed? (fn [_] false))
  (default reverse false)
  (def current (table/clone rows))
  (def indexes (sort (keys current)))
  (def candidate @{})
  (each i indexes (put candidate i true))

  (defn crossings-at [index]
    (var total 0)
    (when-let [above (current (- index 1))]
      (+= total (crossings-between above (current index) up)))
    (when-let [below (current (+ index 1))]
      (+= total (crossings-between (current index) below down)))
    total)

  (var moved true)
  (var rounds 0)
  (while (and moved (< rounds 16))
    (set moved false)
    (++ rounds)
    (each index indexes
      (when (candidate index)
        (put candidate index false)
        (def row (current index))
        (for i 0 (- (length row) 1)
          (def a ((current index) i))
          (def b ((current index) (+ i 1)))
          # A group's members are held still: swapping one past a stranger
          # breaks the contiguity `cohere` guarantees, and this pass cannot
          # move the rest of the group with it.
          (unless (or (fixed? a) (fixed? b))
            (def before (crossings-at index))
            (def was (current index))
            (def swapped (array ;was))
            (put swapped i b)
            (put swapped (+ i 1) a)
            (put current index swapped)
            # Strictly better, or -- on a reverse pass -- equally good. The
            # equal case is dot's escape from a local minimum, and it is safe
            # only because the loop above keeps the best ordering aside.
            (def after (crossings-at index))
            (if (or (< after before)
                    (and reverse (= after before) (pos? before)))
              (do
                (set moved true)
                (put candidate index true)
                (when (current (- index 1)) (put candidate (- index 1) true))
                (when (current (+ index 1)) (put candidate (+ index 1) true)))
              (put current index was)))))))
  current)

(defn sift
  ``Try every node at every position in its layer; keep what crosses least.

  THE MEDIAN SWEEP CANNOT SEE PAST ITS TWO LAYERS, and some orderings only
  make sense from further away. On this tool's own graph the
  `src/select -> src/layout` bend has to sit between `src/layout/force` and
  `src/layout/layered` -- an arrangement that crosses five times where the
  swept one crosses six -- and no median can find it: force and layered have
  no parents at all, so a down-sweep scores them both -1, and all four nodes
  share the single child `src/layout`, so an up-sweep scores them all the
  same. Both directions are blind here; the ordering falls through to the
  scan's input order, which means nothing about the picture.

  Sifting does not reason about any of that. It lifts a node out, tries it in
  every slot, counts the crossings each way, and puts it where the count is
  lowest -- so it finds the arrangement without needing to know why it is
  better. That is what makes it safe in a way the tiebreak it replaces was
  not: a move is kept only when the measured count DROPS, so a pass can
  improve the picture or leave it alone, never make it worse.

  Local optimisation, so it is a refinement of the sweep rather than a
  replacement: `order` gets the layer roughly right and this walks it the
  last step. Reference [7] in Gacho et al. reports it beating barycentre and
  median on sparse graphs, which is what this draws.

  `fixed?` names nodes that may not be moved -- a group's members, whose
  contiguity `cohere` has already established and which sifting has no way to
  preserve.``
  [ordered up down &opt fixed?]
  (default fixed? (fn [_] false))
  (def current (table/clone ordered))
  (def indexes (sort (keys current)))

  (defn cost-at
    "Crossings above and below a layer, as it currently stands."
    [index]
    (var total 0)
    (when-let [above (current (- index 1))]
      (+= total (crossings-between above (current index) (fn [n] (get up n [])))))
    (when-let [below (current (+ index 1))]
      (+= total (crossings-between (current index) below (fn [n] (get down n [])))))
    total)

  (each index indexes
    (def row (current index))
    (when (> (length row) 1)
      (each name row
        (unless (fixed? name)
          (def before (current index))
          (def was (find-index |(= $ name) before))
          (def without (filter |(not= $ name) before))
          # THE SLOT IT IS ALREADY IN, which is not slot zero and not `was`
          # either: pulling the node out shifts everything after it down one,
          # so re-inserting at `was` puts it back exactly where it started
          # only because the slice before it is unchanged. Keeping this as
          # the baseline is what makes a tie a no-op.
          (var best-at was)
          (var best-cost nil)
          (put current index before)
          (set best-cost (cost-at index))
          (for slot 0 (+ 1 (length without))
            (unless (= slot was)
              (def trial (array ;(slice without 0 slot) name ;(slice without slot)))
              (put current index trial)
              (def cost (cost-at index))
              # STRICTLY BETTER, or the node does not move. A tie is not an
              # improvement, and taking it anyway walks every node to
              # whichever end the scan reaches first -- which reversed every
              # rank of this tool's own graph at an identical crossing count,
              # and drew a picture with eighty-three crossings where the
              # ordering it came from had six.
              (when (< cost best-cost)
                (set best-cost cost)
                (set best-at slot))))
          (def final (array ;(slice without 0 best-at) name ;(slice without best-at)))
          (put current index final)))))
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
  merged with. A bound survives the merge because it moves the whole block.

  `gap` is the minimum space between neighbours: either a number, or a
  function of the two names it falls between. TWO BENDS NEED LESS ROOM THAN
  TWO NODES -- a bend is a line, not a box with a label in it, and the gap
  that keeps two labelled ellipses legible is far more than two parallel
  lines need to read as parallel. Given the same gap as everything else, the
  nine edges converging on `src/core` were spaced 32 units apart and read as
  a splayed fan rather than a bundle.``
  [names want widths gap &opt fixed floor ceiling weight]
  (default fixed (fn [_] false))
  (default floor (fn [_] nil))
  (default ceiling (fn [_] nil))
  # HOW HARD EACH NODE ARGUES when a block averages. Graphviz's position
  # pass calls this priority, and it is why long chains come out straight
  # there: a bend carrying an edge through a layer has one thing to want
  # and nothing else holding it, so when it merges with a node that is
  # already near where it wants to be, the bend should win. Equal weights
  # let a single well-placed node drag a whole chain sideways.
  (default weight (fn [_] 1))
  # A scalar gap is the same gap everywhere, which is what every caller but
  # `place-x` wants.
  (def gap-between (if (function? gap) gap (fn [_ _] gap)))
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
                         :weight (weight name)
                         :pin (when (fixed name) left)
                         :low (when-let [f (floor name)] (- f half))
                         :high (when-let [c (ceiling name)] (- c half))})
    # Merge backwards while this block starts before the previous one ends.
    # The gap that matters is the one between the two names in contact --
    # the last of the block behind and the first of this one.
    (while (and (> (length blocks) 1)
                (let [b (last blocks)
                      a (blocks (- (length blocks) 2))]
                  (< (b :left) (+ (a :left) (a :width)
                                  (gap-between (last (a :names)) (first (b :names)))))))
      (def b (array/pop blocks))
      (def a (last blocks))
      (def gap (gap-between (last (a :names)) (first (b :names))))
      # The merged block's left edge: what the two halves wanted, weighted by
      # how many nodes each speaks for, unless one of them is pinned.
      # By total WEIGHT rather than node count: a chain of bends outvotes a
      # node that is merely nearby, which is what keeps a long edge straight
      # through a crowded rank instead of being bent around whatever it
      # happened to touch.
      (def a-n (a :weight))
      (def b-n (b :weight))
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
      (put a :weight (+ (a :weight) (b :weight)))
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
    (var previous nil)
    (each name (b :names)
      (def w (widths name))
      (when previous (set cursor (+ cursor (gap-between previous name))))
      (put out name (+ cursor (/ w 2)))
      (set cursor (+ cursor w))
      (set previous name))
    (set edge cursor))
  out)

(defn- widths-of
  "Each node's drawn width, so placement can respect a long label."
  [names measure]
  (def out @{})
  (each name names (put out name (measure name)))
  out)

(defn- crossing-count
  ``How many times the drawn lines cross, over the whole picture.

  THE NUMBER A READER COUNTS, which is not the one a sweep optimises. The
  median works on one layer pair at a time and cannot see what a change costs
  three ranks away; this measures the finished geometry, so a pass that
  improves its own rank at the expense of the drawing is caught rather than
  congratulated.

  Every link between adjacent layers is a segment between two placed points,
  and two segments cross when each one's ends fall on opposite sides of the
  other. Sharing an endpoint is not a crossing -- a fan out of one node would
  otherwise score as a pile of them.``
  [rows x up]
  (def y-of @{})
  (eachp [index row] rows
    (each name row (put y-of name index)))
  (def segs @[])
  (eachp [index row] rows
    (each name row
      (each other (up name)
        (when (and (x name) (x other) (y-of other))
          (array/push segs [[(x other) (y-of other)] [(x name) index]])))))
  (defn side [ax ay bx by cx cy]
    (- (* (- bx ax) (- cy ay)) (* (- by ay) (- cx ax))))
  (var total 0)
  (for i 0 (length segs)
    (for j (+ i 1) (length segs)
      (def [[x1 y1] [x2 y2]] (segs i))
      (def [[x3 y3] [x4 y4]] (segs j))
      (def d1 (side x3 y3 x4 y4 x1 y1))
      (def d2 (side x3 y3 x4 y4 x2 y2))
      (def d3 (side x1 y1 x2 y2 x3 y3))
      (def d4 (side x1 y1 x2 y2 x4 y4))
      (when (and (< (* d1 d2) 0) (< (* d3 d4) 0))
        (++ total))))
  total)

(defn reseat-bends
  ``Move each bend to the slot its edge's straight line actually points at.

  A BEND'S POSITION IN THE ORDER IS NOT A FACT ABOUT THE GRAPH. A real node
  is somewhere because of what it connects to; a bend is only there to
  reserve a column for an edge passing through, and where that column should
  be is a question about the line, not about the crossing count. The sweep
  scores a bend like a node anyway, because that is all the median knows how
  to do, and `settle` then honours the order it produced -- so a bend ordered
  to the right of a cluster cannot be drawn to the left of it however much
  its line wants to be there.

  On this tool's own graph that is the `src/select -> src/layout` edge. Both
  its ends sit left: `src/select` at x=-374 on rank 1, `src/layout` at
  x=-398 on rank 3, so the line crosses rank 2 at x=-386, between
  `src/layout/force` (-441) and `src/layout/layered` (-349). The sweep
  ordered its bend after `src/layout/svg`, which pins it to x=-194 -- 192
  units out -- and the edge swings right around the whole cluster and cuts
  back underneath, crossing `src/color -> src/layout/svg` on the way. Moving
  the bend to where its line wants removes that crossing and adds none: six
  become five.

  So this reorders BENDS ONLY, by their aim, leaving every real node exactly
  where the sweep and the sift put it. A bend changing places with another
  bend cannot change what the picture asserts; it is the same edges through
  the same ranks, drawn straighter.

  A BEND MAY PASS A REAL NODE DOING IT, and that is the point rather than a
  side effect: the whole defect is a bend stuck on the wrong side of a
  cluster its line runs through. What must not change is the order of the
  real nodes among THEMSELVES -- that is what the sweep decided and what the
  crossing count rests on -- so they keep their relative sequence exactly,
  and only the bends are threaded back in where their aim asks.

  ONE BEND AT A TIME, AND ONLY IF IT PAYS. Moving every bend onto its line at
  once is not the same thing as moving each bend that helps: on this tool's
  own graph the wholesale version took the drawing from six crossings to
  twelve, because a bend whose line happens to run through a crowd drags the
  crowd apart to make room. Moving only the `src/select -> src/layout` bend
  gives five. So each candidate is tried, the crossings are counted, and the
  move is kept only when the number DROPS -- which makes this pass unable to
  make the picture worse, whatever the aims happen to say.

  `aim` answers where a bend's line crosses its layer, in the same units as
  `positions`; `positions` is where everything currently sits; `cost` counts
  the crossings of a whole candidate ordering, so the test is the drawing
  rather than any one rank.``
  [ordered positions aim bend? cost]
  (def current (table/clone ordered))
  (var best (cost current))
  (each index (sort (keys current))
    (def bends (filter bend? (current index)))
    (each name bends
      (def row (current index))
      (def was (find-index |(= $ name) row))
      (def want (aim name))
      (when want
        (def without (filter |(not= $ name) row))
        # Where the aim falls among the nodes that are left: the first slot
        # whose occupant already sits beyond it.
        (def slot (or (find-index |(> (get positions $ math/inf) want) without)
                      (length without)))
        # A bend already in the slot its line points at has nothing to try,
        # and trying anyway costs a placement of the whole graph -- which is
        # what this pass spends its time on. Most bends are already right.
        (unless (= slot was)
          (def trial (array ;(slice without 0 slot) name ;(slice without slot)))
          (put current index trial)
          (def now (cost current))
          (if (< now best)
            (set best now)
            # No better: put the row back exactly as it was.
            (put current index row))))))
  current)

(defn untangle-bundles
  ``Keep the chains that converge on one node in the order they arrive.

  EDGES THAT END AT THE SAME PLACE SHOULD NOT CROSS EACH OTHER. Five chains
  reach `src/graph` on this tool's own graph, and two of them crossed --
  `src/json` and `src/state` -- for no reason a reader could see. Neither
  node had moved; the bends had simply been ordered rank by rank, each
  against whatever else happened to share its layer, and nothing kept one
  chain on one side of another all the way down.

  That is the whole defect. Two chains ending at the same node cross exactly
  when they swap sides on the way down, so the fix is to pick one order for
  the bundle and hold it on every rank.

  WHICH ORDER IS FOUND BY MEASURING, not by a rule about where the chains
  start. Both obvious rules were tried on this graph and both give the
  ordering that was already there: by the source's x, and by where each chain
  first appears. The order that actually draws fewest crossings puts
  `src/json` between `src/scan` and `src/state`, which neither rule predicts
  -- `src/json` sits furthest right of all five sources and belongs fourth of
  five. Its chain starts a rank higher than its siblings', so it enters the
  bundle already on the wrong side of them, and no property of its endpoints
  says where it should slot in.

  So each chain is lifted out and tried in every position, keeping what
  measures best -- the same shape as `sift`, one layer up: there the unit is
  a node in a rank, here it is a whole chain in a bundle.

  `reseat-bends` cannot find this. It moves ONE bend at a time and keeps what
  measures better, and no single move helps: the chain has to change sides on
  two ranks together or not at all, and either bend alone draws worse. That
  is why this is its own pass rather than another aim.

  Only bends move, and only relative to each other -- a real node keeps its
  slot, so the ordering the sweep and the sift agreed on is untouched.``
  [ordered positions chain-of bend? cost]
  (var current (table/clone ordered))
  # Every chain, grouped by the node it ends at.
  (def bundles @{})
  (eachp [_ row] ordered
    (each name row
      (when (bend? name)
        (when-let [[target chain] (chain-of name)]
          (unless (bundles target) (put bundles target @{}))
          (put (bundles target) chain true)))))

  # Rewrite every rank so a bundle's chains sit in `wanted` order among the
  # slots they already hold. Everything else on each rank keeps its place.
  (defn arrange [rows wanted]
    (def rank-of @{})
    (eachp [k chain] wanted
      (each nm chain (put rank-of nm k)))
    (def out (table/clone rows))
    (each index (sort (keys rows))
      (def row (rows index))
      (def mine (filter |(rank-of $) row))
      (when (> (length mine) 1)
        (def slots (seq [[i n] :pairs row :when (rank-of n)] i))
        (def in-order (sorted-by |(rank-of $) mine))
        (def fixed (array ;row))
        (eachp [k i] slots (put fixed i (in-order k)))
        (put out index fixed)))
    out)

  # A BUNDLE ALREADY IN ORDER IS SKIPPED, and most of them are. Chains whose
  # bends hold the same relative order on every rank they share cannot cross
  # each other, so there is nothing for the search to find -- and the search
  # is expensive, since scoring one candidate means placing the whole graph.
  # Nine chains reach `src/core` on this tool's own graph and never cross;
  # trying them anyway cost ninety placements and two seconds to confirm what
  # the order already said.
  (defn tangled? [members]
    # Where each chain sits on each rank, as {rank position}.
    #
    # THE SOURCE COUNTS AS PART OF THE CHAIN. A chain that starts one rank
    # lower than its sibling has no bend on the rank where the sibling is
    # still a NODE, so comparing bends alone finds no rank they disagree on
    # and reports a tangle that is plainly drawn as untangled. `src/json`
    # against `src/state` is exactly that: they agree on ranks 2 and 3, and
    # cross between ranks 1 and 2, where `src/state` is its own node.
    (def track @[])
    (each chain members
      (def seen @{})
      (each index (sort (keys current))
        (when-let [at (find-index |(find (fn [b] (= b $)) chain) (current index))]
          (put seen index at)))
      # The node the chain leaves from, on the rank it leaves from. A bend's
      # name carries its own edge, so the source is read off it.
      (when-let [nm (first chain)]
        (def from (nm 1))
        (each index (sort (keys current))
          (when-let [at (find-index |(= $ from) (current index))]
            (put seen index at))))
      (array/push track seen))
    # Two chains are tangled when they hold opposite relative order on two
    # ranks they BOTH appear on -- which is a swap, and a swap is a crossing.
    (var answer false)
    (for i 0 (length track)
      (for j (+ i 1) (length track)
        (def a (track i))
        (def b (track j))
        (def shared (filter |(get b $) (sort (keys a))))
        (when (> (length shared) 1)
          (def signs (map |(cmp (get a $) (get b $)) shared))
          (unless (all |(= $ (first signs)) signs)
            (set answer true)))))
    answer)

  (eachp [target chains] bundles
    (def members (keys chains))
    (when (and (> (length members) 1) (tangled? members))
      # Start from the order the chains are already in, by where their
      # deepest bend sits -- so a bundle that is already right is left alone.
      (defn deepest [chain]
        (get positions (last chain) 0))
      (var best (sorted-by deepest members))
      (var best-cost (cost (arrange current best)))
      # Each chain, lifted out and tried in every slot. One pass is enough:
      # a bundle is a handful of chains, and the move that matters is a
      # single chain crossing the others.
      (each chain members
        (def without (filter |(not= $ chain) best))
        (each slot (range (+ 1 (length without)))
          (def trial (array ;(slice without 0 slot) chain ;(slice without slot)))
          (def now (cost (arrange current trial)))
          (when (< now best-cost)
            (set best-cost now)
            (set best trial))))
      (set current (arrange current best))))
  current)

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
  group's box, so the layout can clear the rectangle that actually appears.

  `gap` is a number, or a function of the two names it falls between -- see
  `settle`. The bounds and the initial packing below need a single figure to
  do arithmetic with, and take the one the function gives for a pair of real
  nodes: those are the ones a bound has to clear.``
  [ordered up down widths gap &opt bend? aim group-of inset]
  (default bend? (fn [_] false))
  (default aim (fn [_ _] nil))
  (default inset 0)
  (def indexes (sort (keys ordered)))
  # One number for the arithmetic that cannot ask about a specific pair. The
  # widest gap is the safe one there: a bound computed with a narrower figure
  # would let a node sit closer to a group's box than `settle` will allow,
  # and the two would disagree about where the edge of the box is.
  #
  # PROBED WITH A REAL NODE, not with a stand-in. Asking `(gap :node :node)`
  # hands two keywords to a function whose whole job is deciding what KIND of
  # thing is on either side, and it answers only because the lookup it happens
  # to do tolerates a keyword. An earlier version did arithmetic on them and
  # took the render down with "could not find method :+ for :bend-gap".
  #
  # It has to be a NODE rather than a bend: this figure is what the bounds are
  # computed with, and a bound has to clear a node's gap, the wider of the two.
  (def a-node
    (do
      (var found nil)
      (each index indexes
        (each name (get ordered index [])
          (when (and (nil? found) (not (bend? name)))
            (set found name))))
      found))
  (def flat-gap
    (cond
      (not (function? gap)) gap
      a-node (gap a-node a-node)
      # Every name on every rank is a bend, which cannot happen for a real
      # graph -- a bend exists to carry an edge between two nodes. Nothing
      # sensible to measure, so nothing is claimed.
      0))
  (def x @{})

  # Start centred on zero rather than packed from the left: packing made the
  # widest layer set the left edge and left the narrow ones stranded under
  # its first few nodes, so an eighteen-node row over a one-node row came out
  # as a diagonal smear rather than a tree.
  (each index indexes
    (var span (- flat-gap))
    (each name (ordered index) (+= span (+ (widths name) flat-gap)))
    (var cursor (/ span -2))
    (each name (ordered index)
      (put x name (+ cursor (/ (widths name) 2)))
      (set cursor (+ cursor (widths name) flat-gap))))

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
        # the gap before the next rank. A node on that rank can stand tall
        # enough to collide with the overhang, so the claim reaches it. The
        # same is true above the topmost member, where the box carries its
        # name.
        #
        # FOR NODES, NOT FOR BENDS. The fourth element says whether this is
        # a rank the group actually has members on; on the overhang ranks
        # the claim binds only real nodes. It used to bind bends too --
        # added when `src/stamp -> src/core` cut the box's bottom corner --
        # and that was the right problem with the wrong constraint: the
        # corner is clipped by the SEGMENT between two bends, not by where
        # one bend stands, and a bend well inside the box's x-range is fine
        # when its upstream bend has cleared the box with room. Walling the
        # whole x-range off pushed every passing bundle a full box-width
        # sideways for one rank and snapped it back the next -- the S-curves
        # on every long edge down the right side. The segment-vs-corner
        # problem is the ROUTER's now: the corridor carries the box overhang
        # as an obstacle (see `path-through`), and the fitted curve rounds
        # the corner instead of detouring around a wall.
        (when (and (<= (- (s :top) 1) index) (<= index (+ (s :low) 1)))
          (array/push here [key (- (s :x0) inset) (+ (s :x1) inset)
                            (and (<= (s :top) index) (<= index (s :low)))])))
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
        #    real node wants the middle of EVERYTHING it touches, with the
        #    layer this sweep comes from counted first.
        #
        #    READING ONE SIDE AT A TIME WEIGHS THE SIDES EQUALLY, however
        #    many edges each holds. `src/layout` has five parents averaging
        #    x=-421 and one child, `src/graph`, at x=-54: the up-sweep sees
        #    only the child, the down-sweep only the parents, and the node
        #    settles halfway between at -253 -- dragged a hundred units right
        #    of where five of its six edges want it, by the one that does
        #    not. Its parents then string out to the left reaching for it,
        #    and the whole `src/layout/*` cluster leans away from the nodes
        #    it belongs under.
        #
        #    EVERY NEIGHBOUR COUNTED ONCE, both sides together. Letting the
        #    swept side lead keeps the bias, because the sweeps alternate and
        #    the last one wins: `src/layout` still landed at -268 against a
        #    centroid of -361, since the final up-sweep reads its one child
        #    and nothing else. Weighing all six edges equally is the whole
        #    point, and it makes the answer the same whichever direction the
        #    sweep is going -- which is what stops the node oscillating
        #    between two desires and settling in the middle of them.
        (var target
          (or (if (bend? name)
                (aim name x)
                (centre-on (array ;(up name) ;(down name))))
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
          (each [key x0 x1 member-rank?] here
            # A bend on an overhang rank passes freely -- the box is not
            # there, only its shadow, and the router keeps the segment off
            # the corner. See the note in `claims-by-layer`.
            (when (or member-rank? (not (bend? name)))
              (def mates (seq [[j m] :pairs names
                               :when (= key (and group-of (group-of m)))] j))
              (def before? (if (empty? mates)
                             (< (want name) (/ (+ x0 x1) 2))
                             (< i (min ;mates))))
              (if before?
                (put high name (min (get high name math/inf) (- x0 half flat-gap)))
                (put low name (max (get low name (- math/inf)) (+ x1 half flat-gap))))))))

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
                lo hi
                # PRIORITY, the way graphviz's position pass uses it: a bend
                # is a point on a line and wants exactly one thing, so when
                # it comes into contact with a real node it should carry the
                # argument. A node has a label, neighbours on two sides and
                # usually somewhere reasonable to be already; a bend pushed
                # aside puts a visible kink in an edge that spans the
                # picture.
                #
                # TWO TO ONE, MEASURED. Straightness costs width -- the
                # bends win their arguments and the nodes they displace end
                # up further out -- and the trade runs 1078, 1102, 1119,
                # 1126 pixels wide at weights two, three, four and six on
                # this tool's own graph. Two takes most of the straightening
                # for half the spread; past four the picture only gets
                # wider.
                (fn [n] (if (bend? n) 2 1))))
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
                (put high name (min (get high name math/inf) (- x0 half flat-gap)))
                (put low name (max (get low name (- math/inf)) (+ x1 half flat-gap))))))))

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
  # RUN UNTIL IT STOPS IMPROVING, rather than a fixed five rounds.
  #
  # MEASURED, AND THE HONEST RESULT IS THAT FIVE WAS ALREADY ENOUGH HERE:
  # this tool's own graph goes 8496, 7795, 7792 and is done at pass three.
  # So this buys no better picture on the graph it was written against --
  # what it buys is not guessing. Five is arbitrary on a graph of another
  # shape: a wide one with long chains may still be straightening at ten,
  # and a small one finishes at two and spends the rest of the budget
  # re-centring, which a redraw pays for on every file save.
  #
  # The measure is the objective graphviz's position pass uses: total
  # weighted edge length, where a segment carrying a bend counts double, so
  # straightening a long chain is worth more than nudging a short edge.
  #
  # A round that fails to beat the previous by half a percent is the end:
  # past that the picture is moving without getting better, and the extra
  # rounds cost time on every redraw the watcher triggers.
  (defn total-length []
    (var sum 0)
    (eachp [name here] x
      (each other (down name)
        (when (x other)
          # A segment carrying a bend is part of a long edge; weighing it
          # heavier is what makes the layout spend its effort on the chains
          # that read worst when they wander.
          (def weight (if (or (bend? name) (bend? other)) 2 1))
          (+= sum (* weight (math/abs (- here (x other))))))))
    sum)

  (var previous math/inf)
  (var pass 0)
  (while (< pass 24)
    (++ pass)
    (round :down)
    (round :up)
    (def all (values x))
    (unless (empty? all)
      # RE-CENTRED AFTER EACH ROUND, or the picture walks. A block that
      # cannot have what it wants is placed at the nearest position that
      # works, and `settle` resolves ties by pushing right -- so every round
      # nudged the whole drawing further that way and the next measured from
      # there. The `web` group marched right by about a hundred units per
      # round and never converged. Shifting every layer by the same amount
      # cannot change a relative position, so this costs nothing.
      (def drift (/ (+ (min ;all) (max ;all)) 2))
      (eachp [name at] x (put x name (- at drift))))
    (def now (total-length))
    (when (os/getenv "VISUALIZE_LAYOUT_TRACE")
      (eprintf "  pass %d: length %.0f" pass now))
    (if (< now (* previous 0.995))
      (set previous now)
      (set pass 24)))
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
      (def [layer back] (rank names edges (opts :group-of)))

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
      # ORDERING, THE WAY dot RUNS IT (the mincross loop in mincross.c):
      # one sweep, one transpose, score, keep if best, stop when a pass
      # fails to beat the best by the convergence ratio, with a patience
      # counter so a single flat pass does not end it.
      #
      # KEEPING THE BEST ASIDE is the point. A monotone chain of passes can
      # only walk into the nearest local minimum; holding the best ordering
      # ever seen lets a pass end up worse without costing anything, which
      # is what makes the search wider than the walk.
      #
      # THE SWEEP HAS TO BE RESUMABLE for this to be the same computation --
      # see `order`'s `from`. Driving it with repeated one-sweep calls that
      # each restarted the down/up alternation is what made an earlier
      # attempt at this loop draw five crossings where two is normal.
      #
      # WITHOUT dot's TIE-TAKING, and that was measured rather than assumed.
      # dot lets alternate passes accept equal-cost transpositions as a way
      # out of a local minimum. Enabled here it narrows the drawing by
      # thirteen pixels and puts an edge through a node's outline -- 1149
      # wide with one clip against 1162 with none. Thirteen pixels is not
      # worth a clip, so the flag stays off; the loop around it is the part
      # that pays.
      (def bend-name? (fn [name] (not (nil? (dummy-layer name)))))
      (def held-still (fn [name] (and group-of (group-of name) true)))
      # THE SCORE HAS TO SEE THE EDGES. `crossings-between` asks a node for
      # its neighbours in the OTHER row, and the two tables here are keyed
      # the way the rest of this function keys them -- `up` for what points
      # at a node, `down` for what it points at. Consulting the wrong one
      # answers an empty list for every node, which scores every ordering as
      # zero crossings: the loop then keeps its first attempt and exits,
      # which is exactly what it did.
      (def score
        (fn [rows]
          (var total 0)
          (def ranks (sort (keys rows)))
          (each i ranks
            (def below (get rows (+ i 1)))
            (when (and below (indexed? below) (indexed? (rows i)))
              (+= total (crossings-between (rows i) below
                                           (fn [n] (get up n []))))))
          total))

      (var current (table/clone layers))
      (var best (table/clone layers))
      (var best-cross math/inf)
      (var patience 0)
      (var pass 0)
      (def passes (max 8 (* 2 (tuning :sweeps))))
      (while (and (< pass passes) (< patience 4) (pos? best-cross))
        (set current (order current
                            (fn [name] (get up name []))
                            (fn [name] (get down name []))
                            1 group-of bend-name? pass))
        (set current (transpose current
                                (fn [n] (get up n []))
                                (fn [n] (get down n []))
                                held-still))
        (def now (score current))
        (if (< now best-cross)
          (do
            (set best (table/clone current))
            # Only a real improvement buys more passes: dot's .995 ratio, so
            # shaving one crossing off a hundred does not reset the clock.
            (when (< now (* 0.995 best-cross)) (set patience 0))
            (set best-cross now))
          (++ patience))
        (++ pass))
      (def swept best)
      # THEN SIFT, which is the step the sweep cannot do for itself: it tries
      # each node in every slot and keeps what measures best, so it finds the
      # orderings the median is blind to -- the ones where both adjacent
      # layers say the same thing about every node on the rank. A move is
      # kept only when the count drops, so this can improve the picture or
      # leave it alone, never spoil it.
      #
      # A GROUP'S MEMBERS ARE HELD STILL. `cohere` below is what guarantees a
      # group stays contiguous, and sifting moves one node at a time with no
      # idea that the others have to follow -- so it would pull a member out
      # of its group and `cohere` would drag it back, undoing the crossing
      # count sifting had just measured.
      (def sifted (sift swept
                        (fn [name] (get up name []))
                        (fn [name] (get down name []))
                        (fn [name] (and group-of (group-of name) true))))
      # THEN TRANSPOSE, the exact local question the other two passes do not
      # ask: is this adjacent pair better swapped? Cheap, and it catches the
      # tangles a median averages away.
      (def flipped (transpose sifted
                              (fn [name] (get up name []))
                              (fn [name] (get down name []))
                              (fn [name] (and group-of (group-of name) true))))
      (def ordered (if group-of (cohere flipped group-of) flipped))

      # A dummy is measured as the room its edge needs to pass, which is a
      # narrow column rather than nothing: at zero width the separation pass
      # would let a chain sit flush against a node and the edge would graze
      # it.
      (def widths (widths-of names measure))
      (eachp [name _] dummy-layer (put widths name (tuning :bend-width)))

      # A bend carries its own edge in its name, so the line it should be
      # sitting on is a lerp between where that edge's two ends have ended
      # up. `where` is the table of positions as they stand, which the pass
      # is still moving -- so this is read fresh on every sweep.
      (def bend? (fn [name] (not (nil? (dummy-layer name)))))
      (def aim
        (fn [name where]
          (when-let [on (dummy-layer name)]
            (def [_ from to _] name)
            (def a (layer from))
            (def b (layer to))
            (when (and a b (not= a b) (where from) (where to))
              (def t (/ (- on a) (- b a)))
              (+ (where from)
                 (* t (- (where to) (where from))))))))
      (def bend-group
        # Only real nodes belong to a group; a bend is passing through and
        # must not be pulled into somebody's box.
        (when-let [of (opts :group-of)]
          (fn [name] (when (string? name) (of name)))))
      # TWO BENDS SIT CLOSER THAN TWO NODES. The gap between neighbours is
      # what keeps two labelled ellipses apart and legible; two bends are
      # parallel lines and need far less. Given the node's gap they read as a
      # splayed fan rather than a bundle -- the nine edges converging on
      # `src/core` were 32 units apart across the last four ranks.
      #
      # Only bend-to-bend is narrowed. A bend beside a real node keeps the
      # full gap, because that gap is what stops the edge grazing the box.
      (def gap-between
        (fn [a b]
          (if (and (bend? a) (bend? b))
            (tuning :bend-gap)
            (tuning :node-gap))))
      (defn seat [rows]
        (place-x rows
                 (fn [name] (get up name []))
                 (fn [name] (get down name []))
                 widths
                 gap-between
                 bend?
                 aim
                 bend-group
                 # How far outside its members the renderer draws the box. An
                 # option rather than an import: this file deliberately knows
                 # nothing about SVG, so the seam passes it down (see
                 # src/layout.janet).
                 (tuning :group-inset)))

      # PLACE, THEN LET THE BENDS FIND THEIR LINE, THEN PLACE AGAIN. A bend's
      # slot in the order came from the median sweep, which scores it like a
      # node because that is all a median can do -- but a bend is only a
      # reserved column, and which side of a cluster it belongs on is a
      # question about its edge's line, not about crossings. `settle` honours
      # the order it is given, so a bend ordered onto the wrong side stays
      # there however far its line is from it.
      #
      # One placement answers where every line actually runs; `reseat-bends`
      # threads each bend back in where its line crosses the rank; the second
      # placement is the picture. Kept only if it draws fewer crossings,
      # measured on the finished geometry -- see `crossing-count`.
      (def first-x (seat ordered))
      (def neighbours-up (fn [name] (get up name [])))
      # What a candidate ordering actually draws: seat it, then count the
      # lines. Placement is the whole point -- a bend's slot only matters for
      # where `settle` can put it -- so a cheaper test that skipped the
      # re-seat would be measuring an arrangement nobody is going to see.
      (defn cost [rows]
        (crossing-count rows (seat rows) neighbours-up))
      (def reseated (reseat-bends ordered first-x
                                  (fn [name] (aim name first-x))
                                  bend?
                                  cost))

      # THEN UNTANGLE THE BUNDLES. Chains ending at the same node cross each
      # other exactly when they swap sides on the way down, and `reseat-bends`
      # cannot fix that: it moves one bend at a time, and a chain that has to
      # change sides on two ranks together gets no credit for doing half of
      # it. So the chains into a shared target are ordered once, by where each
      # enters, and held to it.
      (def reseated-x (seat reseated))
      (def untangled
        (untangle-bundles reseated reseated-x
                          # A bend's chain: the edge it belongs to, and every
                          # bend of that edge in rank order. The name carries
                          # its own edge, so this is a lookup rather than a
                          # search.
                          (fn [name]
                            (when (dummy-layer name)
                              (def [_ from to _] name)
                              (when-let [chain (chains [from to])]
                                [to chain])))
                          bend?
                          cost))
      # X, EITHER WAY. The relaxation below is what has always run; the aux
      # graph is dot's formulation, where separation and straightness are
      # one weighted optimisation rather than two passes that cannot see
      # each other. Selected by VISUALIZE_AUX so the two can be measured on
      # the same graph -- see docs/dotgen-audit.md for why it exists.
      (def x
        (if (os/getenv "VISUALIZE_AUX")
          (let [rows untangled
                # A GROUP IS A COLUMN, and the aux graph has to be told so
                # or it scatters the members across their ranks and the box
                # drawn round them swallows whatever is between. Expressed
                # as containment edges rather than pins: every member is
                # tied to the group's own slack node with a heavy weight, so
                # the optimiser keeps them in line while still being free to
                # move the whole column.
                pinned nil
                solved (aux/solve rows widths
                                  # Every segment a line is actually drawn
                                  # along: node to bend, bend to bend, bend
                                  # to node. These are what straightness is
                                  # about, not the logical edges.
                                  (let [segs @[]]
                                    (eachp [pair chain] chains
                                      (def [from to] pair)
                                      (def path (array from ;chain to))
                                      (for i 0 (- (length path) 1)
                                        (array/push segs [(path i) (path (+ i 1))])))
                                    (each [from to] edges
                                      (unless (chains [from to])
                                        (array/push segs [from to])))
                                    segs)
                                  gap-between bend? pinned
                                  (when group-of
                                    (fn [name]
                                      (when (string? name) (group-of name)))))]
            (or solved (seat untangled)))
          (seat untangled)))

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

      # CORRIDORS, from dot's maximal_bbox in dotsplines.c. For each bend,
      # the free space it has on its rank: from the right edge of whatever
      # is ordered before it to the left edge of whatever is ordered after.
      #
      # WHY A ROUTE IS NOT ENOUGH. The bends say where the edge passes, and
      # every pass so far has tried to put them somewhere sensible -- but a
      # bend's slot is chosen by crossing count, and crossing count is
      # indifferent between two slots that cross the same number of times.
      # When one of those is beside the line and the other is three hundred
      # units away past a group, nothing in ordering prefers the near one,
      # and the edge takes the detour.
      #
      # dot does not solve that in ordering either. It hands the router the
      # BOX the bend may move within, and the spline is fitted inside the
      # chain of boxes -- so an edge whose bend sits far from its line can
      # still be drawn near it, as long as it stays in the free space. The
      # boxes are the permission; the route is only the default.
      (def corridors @{})
      (eachp [pair chain] chains
        (def [from to] pair)
        (when (and (points from) (points to))
          (put corridors pair
               (map (fn [name]
                      (def rank (dummy-layer name))
                      (def row (get ordered rank []))
                      (def at (find-index |(= $ name) row))
                      (def here (x name))
                      # Left wall: the right edge of the previous occupant,
                      # plus the gap that keeps lines legible. Nothing to the
                      # left means the bend may go as far as it likes.
                      (def left
                        (if (and at (pos? at))
                          (let [n (row (- at 1))]
                            (+ (x n) (/ (widths n) 2) (gap-between n name)))
                          (- here 1000)))
                      (def right
                        (if (and at (< at (- (length row) 1)))
                          (let [n (row (+ at 1))]
                            (- (x n) (/ (widths n) 2) (gap-between name n)))
                          (+ here 1000)))
                      [left right (* rank (tuning :layer-gap))])
                    chain))))

      {:points points :routes routes :corridors corridors :back back})))
