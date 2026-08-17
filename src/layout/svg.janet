# Positions to a picture.
#
# THE OTHER HALF OF A LAYOUT. A layout module answers where things go; this
# turns that answer into SVG. The structure -- `g.node` with a `<title>`
# naming it and `<text>` for the label, `g.edge` with a `<title>` of
# "from->to" -- is the contract the page reads, and it is now OURS rather
# than a shape inherited from graphviz's output. web/app.js still reads
# exactly these, so the page's panning, edge highlighting and node labelling
# work unchanged.
#
# WHAT CHANGED WHEN GRAPHVIZ WENT. Two things this file now owns:
#
#   MEASURING. graphviz sized every node from the font metrics it resolved
#   through fontconfig. Nothing here can measure a font, so `width-of`
#   estimates from the character count -- deliberately generous, since a
#   label overflowing its ellipse is much worse than one rattling around in
#   it. The layout asks for this estimate BEFORE placing anything, which is
#   why `measure` is passed down rather than applied afterwards.
#
#   MULTI-LINE LABELS. A path label is wrapped a segment per line, and the
#   separator carries a real newline now that v strings decode escapes --
#   where DOT carried the two characters `\` and `n` and let graphviz split
#   them. Each line becomes its own `<tspan>`.

(import ../color)
(import ../select)
(import ./fit)

(def- pad 40)          # margin around the drawing
(def- ry-base 16)      # half-height of a single-line node
(def- line-height 14)  # a label line, in user units
(def- char-width 6.1)  # an average glyph at font-size 11 -- see width-of

(def group-inset
  ``How far outside its members a group's box is drawn.

  Exported because the layout has to keep non-members out of the rectangle
  that actually appears, not out of the members' bounding box. They were two
  separate numbers -- this one, and the gap the layout evicted to -- and the
  difference was the margin a node ended up with: seven units, which is close
  enough to nothing that `tools/replay` overlapped the `web` box by four. A
  box containing a node it does not group is the one thing a box must never
  do, so there is one number and both halves read it.``
  13)

(defn- escape [text]
  (->> (string text)
       (string/replace-all "&" "&amp;")
       (string/replace-all "<" "&lt;")
       (string/replace-all ">" "&gt;")))

(defn lines-of
  "A label as its lines. v decodes `\\n` to a real newline when it parses."
  [label]
  (string/split "\n" (string label)))

(defn width-of
  ``How wide a node has to be to hold its label.

  An ESTIMATE, and generously so. graphviz measured the real font through
  fontconfig; nothing here can, so this takes the longest line and pads it.
  Erring wide costs some empty space inside an ellipse; erring narrow puts
  the text outside it, which is the failure everyone sees.

  THE ELLIPSE IS WHY THE PADDING IS WHAT IT IS. A rectangle would need the
  text width and no more, but an ellipse is only full width across its
  middle -- a three-line label has its first and last lines up where the
  curve has already closed in.

  THE ALLOWANCE WAS BEING PAID TWICE, and that is what made the picture
  twice as wide as it needed to be. A `1.5` squeeze on top of a 96-unit
  floor meant a four-character label -- `core`, `scan`, `http`, the ordinary
  case -- was drawn 96 units wide where graphviz drew it 54. Every node
  being 78% too wide is not a cosmetic matter: `place-x` separates by drawn
  width, so the whole layout inherited it and the top rank came out 2131
  units across instead of 726.

  The numbers below are fitted to what graphviz produced for these labels at
  font-size 11 (width = 5.7*longest + 31, within a unit or two across the
  whole range). The floor is now just wide enough for the arrowhead and the
  stroke, not a second helping of padding.``
  [label]
  (def rows (lines-of label))
  (def longest (max ;(map length rows)))
  (def text-width (* longest char-width))
  # One line sits on the centre line and needs no allowance for the curve;
  # a stack of lines has its outer ones up where the curve has closed in.
  (def squeeze (if (> (length rows) 1) 1.22 1.06))
  (max 48 (+ 20 (* text-width squeeze))))

(defn height-of
  ``How tall a node has to be to hold its label's lines.

  Same reasoning as `width-of`: the lines have to fit inside the curve, not
  inside a box around it. Fitted to graphviz the same way -- it drew a
  three-line label 62 units tall and a four-line one 79, which is a line at
  ~17 units plus a constant.``
  [label]
  (def rows (lines-of label))
  (max (* 2 ry-base)
       (+ 14 (* (length rows) line-height (if (> (length rows) 1) 1.2 1)))))

(defn- bounds
  ``The drawing's extent, as [x y width height].

  `sizes` holds HALF-dimensions -- they are an ellipse's rx and ry, and are
  used as such everywhere else in this file. Halving them again here drew a
  viewBox a quarter of a node too tight on every side, which clipped the
  outermost group's dashed box and cut the top off its label.``
  [places sizes]
  (var minx math/inf) (var miny math/inf)
  (var maxx (- math/inf)) (var maxy (- math/inf))
  (eachp [name p] places
    (def half-w ((sizes name) :w))
    (def half-h ((sizes name) :h))
    (set minx (min minx (- (p :x) half-w))) (set maxx (max maxx (+ (p :x) half-w)))
    (set miny (min miny (- (p :y) half-h))) (set maxy (max maxy (+ (p :y) half-h))))
  (if (= minx math/inf)
    [0 0 100 100]
    [(- minx pad) (- miny pad)
     (+ (- maxx minx) (* 2 pad)) (+ (- maxy miny) (* 2 pad))]))

(defn- on-ellipse
  ``Where the line toward (tx,ty) leaves the ellipse at (p) of half-size
  (rx,ry), plus `extra` beyond it.

  The real intersection this time, not the approximation the force layout
  shipped with: with variable-width nodes the error is visible, and the
  parametric solution is three lines.``
  [p rx ry tx ty extra &opt turn]
  (def dx (- tx (p :x)))
  (def dy (- ty (p :y)))
  (def d (max 0.0001 (math/sqrt (+ (* dx dx) (* dy dy)))))
  # `turn` rotates the approach by a few tenths of a radian, which is how a
  # fan of edges into one node lands at a spread of points rather than all
  # at the same one. Zero for an edge with nothing to share the node with.
  (def angle (+ (math/atan2 dy dx) (or turn 0)))
  (def ux (math/cos angle))
  (def uy (math/sin angle))
  # The scale that puts (ux,uy) on the unit circle in ellipse space.
  (def k (/ 1 (max 0.0001 (math/sqrt (+ (/ (* ux ux) (* rx rx))
                                        (/ (* uy uy) (* ry ry)))))))
  [(+ (p :x) (* ux (+ k extra))) (+ (p :y) (* uy (+ k extra)))])

(defn- spline
  ``An SVG path through every one of `pts`, curved.

  A CURVE THAT PASSES THROUGH ITS POINTS, not near them. Catmull-Rom is the
  spline with that property, and converting each of its segments to a cubic
  bezier is how it gets drawn with the two commands SVG has. The conversion
  is the standard one: for points p0 p1 p2 p3, the segment from p1 to p2
  has control points p1 + (p2-p0)/6 and p2 - (p3-p1)/6.

  The ends are handled by duplicating the first and last points, so every
  segment has the two neighbours the formula wants and the curve starts and
  finishes pointing the way the edge does.``
  [pts]
  (if (< (length pts) 2)
    ""
    (let [n (length pts)
          at (fn [i] (pts (min (max i 0) (- n 1))))
          out @[(string/format "M%.1f,%.1f" ((at 0) 0) ((at 0) 1))]]
      (for i 0 (- n 1)
        (def p0 (at (- i 1)))
        (def p1 (at i))
        (def p2 (at (+ i 1)))
        (def p3 (at (+ i 2)))
        # A sixth is the Catmull-Rom-to-bezier constant; smaller would flatten
        # the curve toward the polyline it replaces, larger would overshoot
        # the waypoints it exists to hit.
        (array/push out
          (string/format "C%.1f,%.1f %.1f,%.1f %.1f,%.1f"
                         (+ (p1 0) (/ (- (p2 0) (p0 0)) 6))
                         (+ (p1 1) (/ (- (p2 1) (p0 1)) 6))
                         (- (p2 0) (/ (- (p3 0) (p1 0)) 6))
                         (- (p2 1) (/ (- (p3 1) (p1 1)) 6))
                         (p2 0) (p2 1))))
      (string/join out " "))))

(defn- path-through
  ``The `d` of an edge: a straight line when one reaches, the routed
  polyline when it does not.

  THE SIMPLEST LINE THAT WORKS. An edge that can run straight from its
  source to its target without touching anything else should do exactly
  that -- it is the clearest way to say what the edge says. Only when the
  straight line is blocked does the edge need the bend points the layout
  reserved for it, and then it uses all of them.

  NEVER BOTH. Curving the first stretch and leaving the rest straight was
  tried and reads badly: seventeen of the edges on this tool's own graph
  came out as an arc that suddenly became a polyline, and the join is
  visible on every one of them. An edge is one kind of line for its whole
  length.

  `places` and `sizes` are every node's centre and half-size, so the
  straight line can be checked against the nodes it would pass. Without
  them -- the force layout does not pass them -- the straight line is used
  whenever the layout gave no bends, which is what this did before.``
  [a b ra rb bends &opt from to places sizes box-rects paths turn corridor]

  (defn hits-anything?
    ``Is a straight line from (x1,y1) to (x2,y2) clear of everything it has
    no business touching -- nodes, group boxes it is not part of, and the
    straight lines of other edges?

    ALL THREE ARE THE SAME KIND OF MESS. A line through a node, a line
    through a box around a group it does not belong to, and two lines
    crossing in open space all read as the picture failing to keep its
    subjects apart; a reader notices the last of them first. An edge that
    would cause any of them takes its reserved route instead, or curves.``
    [x1 y1 x2 y2]
    (if (or (nil? places) (nil? sizes))
      false
      (do
        (var hit false)
        # Nodes.
        (for k 0 33
          (def t (/ k 32))
          (def px (+ x1 (* t (- x2 x1))))
          (def py (+ y1 (* t (- y2 y1))))
          (eachp [name p] places
            (unless (or (= name from) (= name to) hit)
              (def s (sizes name))
              (def dx (/ (- px (p :x)) (max 0.001 (s :w))))
              (def dy (/ (- py (p :y)) (max 0.001 (s :h))))
              # A whisker inside the ellipse rather than on it, so a line
              # that merely grazes the outline is not counted as blocked.
              (when (< (+ (* dx dx) (* dy dy)) 0.94)
                (set hit true)))))
        # Group boxes, unless this edge has an end inside the box -- an edge
        # that starts or finishes in a group is entitled to be in its box.
        (unless (or hit (nil? box-rects))
          (each r box-rects
            (unless (or hit
                        (get (r :members) from)
                        (get (r :members) to))
              (for k 0 33
                (def t (/ k 32))
                (def px (+ x1 (* t (- x2 x1))))
                (def py (+ y1 (* t (- y2 y1))))
                (when (and (>= px (r :x0)) (<= px (r :x1))
                           (>= py (r :y0)) (<= py (r :y1)))
                  (set hit true))))))
        # Other edges' straight lines. Edges sharing an endpoint always meet
        # there and are not crossing in any sense a reader minds.
        (unless (or hit (nil? paths))
          (defn side [ax ay bx by cx cy]
            (- (* (- bx ax) (- cy ay)) (* (- by ay) (- cx ax))))
          (each o paths
            (def pts (o :points))
            (for i 0 (- (length pts) 1)
              (unless hit
              (def ox1 ((pts i) 0)) (def oy1 ((pts i) 1))
              (def ox2 ((pts (+ i 1)) 0)) (def oy2 ((pts (+ i 1)) 1))
              (def d1 (side ox1 oy1 ox2 oy2 x1 y1))
              (def d2 (side ox1 oy1 ox2 oy2 x2 y2))
              (def d3 (side x1 y1 x2 y2 ox1 oy1))
              (def d4 (side x1 y1 x2 y2 ox2 oy2))
              (when (and (< (* d1 d2) 0) (< (* d3 d4) 0))
                # SHARING AN ENDPOINT IS NOT A LICENCE TO CROSS ANYWHERE.
                # Edges into the same node must meet at that node, and a
                # crossing in the fan just outside it is what a fan looks
                # like -- but skipping the pair entirely threw away the
                # crossings that happen ranks earlier, which are the ones a
                # reader sees. `src/config -> src/graph` cut across three of
                # its own siblings on the way down and was still called
                # clear, because all four end at `src/graph`.
                #
                # So the crossing point is found and only ignored when it is
                # close to the shared node.
                (def dx (- x2 x1)) (def dy (- y2 y1))
                (def ox (- ox2 ox1)) (def oy (- oy2 oy1))
                (def det (- (* dx oy) (* dy ox)))
                (def t (if (< (math/abs det) 0.000001)
                         0.5
                         (/ (- (* (- ox1 x1) oy) (* (- oy1 y1) ox)) det)))
                (def px (+ x1 (* t dx)))
                (def py (+ y1 (* t dy)))
                (var near false)
                (each end [from to]
                  (when (and (or (= (o :from) end) (= (o :to) end))
                             (places end))
                    (def p (places end))
                    (def s (sizes end))
                    # Within about a node's width of where they converge.
                    (def gx (- px (p :x))) (def gy (- py (p :y)))
                    (when (< (+ (* gx gx) (* gy gy))
                             (let [r (+ (* 2.2 (s :w)) (* 2.2 (s :h)))] (* r r)))
                      (set near true))))
                (unless near (set hit true)))))))
        hit)))

  # THE ARROW LANDS ON THE NODE. The path runs to the boundary itself, and
  # the marker's refX puts the arrow's TIP at that point rather than its
  # tail -- so the head touches the ellipse the way it does in dot's output.
  # Stopping short by the marker's length, which is what the 9 here used to
  # do, subtracted the arrowhead twice and left every edge floating a
  # visible gap away from the node it points at.
    # SLIDE EACH BEND ALONG ITS CORRIDOR toward the straight line, which
    # is dot's routing step: the bends say where the edge may pass, the
    # corridor says how far either way it may move, and the line between
    # the endpoints says where it would rather be. A bend whose slot sits
    # far from its line -- because crossing count was indifferent between
    # that slot and a near one -- can now be drawn near it anyway, as long
    # as it stays inside the free space its rank actually has.
    (def bends
      (if (empty? corridor)
        bends
        (let [ax (a :x) ay (a :y) bx (b :x) by (b :y)
              span (- by ay)]
          (map (fn [i bend]
                 (def box (get corridor i))
                 (if-not box
                   bend
                   (let [[left right _] box
                         # Where the straight line is at this bend's rank.
                         t (if (zero? span) 0.5 (/ (- (bend 1) ay) span))
                         wants (+ ax (* t (- bx ax)))]
                     [(min right (max left wants)) (bend 1)])))
               (range (length bends)) bends))))

  (def straight-from (on-ellipse a (ra :w) (ra :h) (b :x) (b :y) 0))
  (def straight-to (on-ellipse b (rb :w) (rb :h) (a :x) (a :y) 0 turn))

  (if (not (hits-anything? (straight-from 0) (straight-from 1)
                           (straight-to 0) (straight-to 1)))
    # Straight reaches. Say it that way, bends or no bends -- a chain of
    # bends the edge does not need is a detour drawn for its own sake.
    (string/format "M%.1f,%.1f L%.1f,%.1f"
                   (straight-from 0) (straight-from 1)
                   (straight-to 0) (straight-to 1))
    (if (empty? bends)
      # BLOCKED, AND NOTHING TO ROUTE THROUGH. Bends exist only for edges
      # spanning more than one rank, so an edge to the next rank down has no
      # reserved column to detour along -- and the layout has already decided
      # every node's x, so there is nowhere else for the line to go. Straight
      # is blocked and the polyline IS the straight line.
      #
      # A curve is the one thing left, and here it is the whole edge rather
      # than a first stretch glued to a polyline: there are no bends to mix
      # with, so nothing to look inconsistent against. One quadratic, source
      # to target.
      #
      # WHICH WAY IT BOWS IS CHOSEN BY WHAT IS IN THE WAY. The control point
      # can sit above the straight line or below it, and a fixed choice suits
      # half the graph and hurts the other half: `src/v -> src/layout` has to
      # dip below `src/layout/force`, which stands beside its source, while
      # `src/select -> src/v` has to stay above the same node, which stands
      # beside its target. Both are tried, the one that clears wins, and if
      # neither clears the shallower one does.
      (let [[x1 y1] straight-from
            [x2 y2] straight-to
            mx (/ (+ x1 x2) 2)
            my (/ (+ y1 y2) 2)
            # Perpendicular to the chord, scaled to a fraction of its length:
            # enough to clear a neighbouring node, gentle enough that the edge
            # still reads as running from one node to the other.
            dx (- x2 x1)
            dy (- y2 y1)
            len (max 0.001 (math/sqrt (+ (* dx dx) (* dy dy))))
            bow (* 0.15 len)
            nx (* (/ (- dy) len) bow)
            ny (* (/ dx len) bow)
            one [(+ mx nx) (+ my ny)]
            other [(- mx nx) (- my ny)]
            hit (fn [c]
                  (var worst 0)
                  (for k 0 25
                    (def t (/ k 24))
                    (def u (- 1 t))
                    (def px (+ (* u u x1) (* 2 u t (c 0)) (* t t x2)))
                    (def py (+ (* u u y1) (* 2 u t (c 1)) (* t t y2)))
                    (when (and places sizes)
                      (eachp [name p] places
                        (unless (or (= name from) (= name to))
                          (def s (sizes name))
                          (def ex (/ (- px (p :x)) (max 0.001 (s :w))))
                          (def ey (/ (- py (p :y)) (max 0.001 (s :h))))
                          (def d (+ (* ex ex) (* ey ey)))
                          (when (< d 1)
                            (set worst (max worst (* (s :w) (- 1 (math/sqrt d))))))))))
                  worst)
            # A GENTLE BOW OFTEN IS NOT ENOUGH. Both sides are tried at
            # increasing depth and the first that clears wins: a neighbour
            # standing right beside the source needs a wider detour than a
            # node merely near the line, and settling for the shallower of
            # two blocked arcs drew an edge straight through something.
            best (do
                   (var found nil)
                   (each scale [1 1.8 2.8 4]
                     (unless found
                       (def sx (* nx scale))
                       (def sy (* ny scale))
                       (def up [(+ mx sx) (+ my sy)])
                       (def down [(- mx sx) (- my sy)])
                       (cond
                         (zero? (hit up)) (set found up)
                         (zero? (hit down)) (set found down))))
                   found)
            # NOTHING CLEARS: least NODE-penetration wins, straight line
            # included. "Blocked" and "through a node" are different
            # verdicts -- the straight line is refused for crossing another
            # edge's line or a group box as readily as for a node, and the
            # old fallback (shallower of the two gentlest bows) threw that
            # distinction away: `color -> config` had a straight line that
            # entered NO node, and drew a bow through `layout/layered`
            # instead, because the straight line's reason for rejection was
            # never consulted. A crossing in open space is a blemish; a
            # line through a node is a lie about the graph. So every
            # candidate -- the straight line (a Q with its control on the
            # chord) and both sides at every depth -- is scored by how
            # deeply it enters nodes, and the least wins. Order breaks
            # ties: straight first, then shallow before deep, so the edge
            # never bends more than the least-bad answer requires.
            c (or best
                  (do
                    (def candidates @[[mx my]])
                    (each scale [1 1.8 2.8 4]
                      (array/push candidates [(+ mx (* nx scale)) (+ my (* ny scale))])
                      (array/push candidates [(- mx (* nx scale)) (- my (* ny scale))]))
                    (var pick (first candidates))
                    (var least math/inf)
                    (each cand candidates
                      (def h (hit cand))
                      (when (< h least) (set least h) (set pick cand)))
                    pick))]
        (string/format "M%.1f,%.1f Q%.1f,%.1f %.1f,%.1f"
                       x1 y1 (c 0) (c 1) x2 y2))
      # Blocked, and the layout reserved a route: follow it -- as a CURVE.
      #
      # The bends are where the edge must pass, not corners it must turn.
      # Drawn as line segments they read as plumbing: every multi-rank edge
      # arrives at its target having visibly changed direction two or three
      # times, and a reader tracks the kinks instead of the connection. A
      # curve through the same points says the same thing about where the
      # edge goes and nothing about corners that are not there.
      #
      # ROUTED INSIDE THE CORRIDOR WHEN THERE IS ONE, and through the bends
      # themselves when there is not.
      #
      # THE DIFFERENCE IS WHAT THE BENDS MEAN. A Catmull-Rom through the
      # bend points has to pass through them, which treats each bend as a
      # place the edge must visit. It is not: the bend is where the layout
      # PARKED the edge on that rank, and the box around it is how far it
      # may move. Fitting inside the boxes uses that freedom, so an edge
      # whose bend sits far from its line can still be drawn near it.
      # See funnel.janet and fit.janet, and docs/pathplan-scope.md.
      #
      # THE FALLBACK IS NOT DECORATION. The router returns nil rather than
      # a curve that leaves the corridor, and a corridor is only as good as
      # the layout that built it; when it declines, the spline through the
      # bends is the answer that shipped before and still draws.
      (let [first-target (first bends)
            last-source (last bends)
            [x1 y1] (on-ellipse a (ra :w) (ra :h)
                                (first-target 0) (first-target 1) 0)
            [x2 y2] (on-ellipse b (rb :w) (rb :h)
                                (last-source 0) (last-source 1) 0 turn)
            pts (array [x1 y1] ;(map |[($ 0) ($ 1)] bends) [x2 y2])
            # Tangents from the ellipse exits, so the fitted curve leaves
            # and arrives at the angles the fan logic already chose.
            fitted (when (and corridor (>= (length corridor) 2))
                     (fit/route [x1 y1] [x2 y2] corridor
                                [(- (first-target 0) x1) (- (first-target 1) y1)]
                                [(- x2 (last-source 0)) (- y2 (last-source 1))]))]
        (if fitted
          (string/join
            (array (string/format "M%.1f,%.1f" x1 y1)
                   ;(map (fn [[c1 c2 end]]
                           (string/format "C%.1f,%.1f %.1f,%.1f %.1f,%.1f"
                                          (c1 0) (c1 1) (c2 0) (c2 1)
                                          (end 0) (end 1)))
                         fitted))
            " ")
          (spline pts))))))

(defn draw
  ``The graph as SVG, laid out by `places`.

  `places` is {name {:x :y}}; `opts` carries what the config decided --
  :groups, :filled, :font, :weights -- and :routes, the bend points a
  layered layout produces for an edge that spans more than one layer.

  GROUP BOXES are drawn when the layout says they would be honest: a
  layered layout keeps a group roughly contiguous, so a box around its
  members means something. The force layout passes :boxes false, because a
  box drawn around scattered members would claim a structure the picture
  does not have.``
  [graph places &opt opts]
  (default opts {})
  (def nodes (get graph :nodes []))
  (def edges (get graph :edges []))
  (def groups (or (opts :groups) []))
  (def ours (or (graph :ours) {}))
  (def sizes-in (or (graph :sizes) {}))
  (def font (or (opts :font) "Comic Sans MS"))
  (def routes (or (opts :routes) {}))
  # The free space each bend has on its rank -- see the corridor note in
  # layered.janet. Empty for the force layout, which has no ranks.
  (def corridors (or (opts :corridors) {}))
  (def weights (or (opts :weights) {}))
  (def filled (opts :filled))

  # Every node's half-width and half-height, which both the bounds and the
  # edge clipping need.
  (def label-of @{})
  (each node nodes (put label-of (node :name) (or (node :label) (node :name))))
  (def sizes @{})
  (eachp [name _] places
    (def label (or (label-of name) name))
    (put sizes name {:w (/ (width-of label) 2) :h (/ (height-of label) 2)}))

  # THE SAME TEST THE LAYOUT USED. `select/group-for` understands `~`, which
  # a plain prefix check does not -- and if the two disagreed, the layout
  # would keep one set of nodes together and the renderer would draw the box
  # around a different one.
  (defn group-for [name] (select/group-for name groups ours))

  # THE BOXES, AS RECTANGLES, before anything is drawn. They are drawn below
  # as part of the picture, but an edge has to be able to ask whether a
  # straight line would cut through one on its way -- and a box a node is not
  # in is as much an obstacle as a node, since a line through it reads as
  # touching a group it has nothing to do with.
  (def box-rects @[])
  (when (opts :boxes)
    (each g groups
      (def members (filter |(and (places $) (= g (group-for $)))
                           (map |($ :name) nodes)))
      (when (not (empty? members))
        (var minx math/inf) (var maxx (- math/inf))
        (var miny math/inf) (var maxy (- math/inf))
        (each name members
          (def p (places name))
          (def s (sizes name))
          (set minx (min minx (- (p :x) (s :w)))) (set maxx (max maxx (+ (p :x) (s :w))))
          (set miny (min miny (- (p :y) (s :h)))) (set maxy (max maxy (+ (p :y) (s :h)))))
        (array/push box-rects
                    {:members (from-pairs (map |[$ true] members))
                     :x0 (- minx group-inset) :x1 (+ maxx group-inset)
                     :y0 (- miny group-inset 12) :y1 (+ maxy group-inset)}))))

  (def [vx vy vw vh] (bounds places sizes))
  (def out @"")

  (buffer/push-string out
    (string/format
      `<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="%d %d %d %d">`
      (math/floor vw) (math/floor vh)
      (math/floor vx) (math/floor vy) (math/floor vw) (math/floor vh)))
  # markerUnits="userSpaceOnUse" is the whole of this: without it the marker
  # scales with the STROKE WIDTH, and a marker sized in stroke-widths on a
  # thin line drew arrowheads the size of the nodes. In user space the size
  # is the size.
  (buffer/push-string out
    `<defs><marker id="arrow" viewBox="0 0 10 10" refX="10" refY="5"`
    ` markerUnits="userSpaceOnUse" markerWidth="9" markerHeight="9"`
    ` orient="auto">`
    `<path d="M0,0 L10,5 L0,10 z" fill="var(--edge, #888)"/></marker></defs>`)

  # Group boxes first, under everything: a box is context, not content.
  #
  # ONE RECT, around the members. A group is a box around some nodes and says
  # nothing about layers, so a group whose members land on four ranks is
  # still one group and gets one box with one name on it.
  #
  # This used to be a band per layer, which was a workaround for the box
  # being WRONG rather than for groups being layer-shaped: a single rect
  # around members scattered across two ranks swallowed whatever sat between
  # them, so the renderer gave up on the box instead of the layout fixing the
  # scatter. `layered/cohere` now keeps a group over itself across layers as
  # well as contiguous within one, which is what makes the honest box the
  # simple one.
  (when (opts :boxes)
    (each g groups
      (def members (filter |(and (places $) (= g (group-for $)))
                           (map |($ :name) nodes)))
      (when (not (empty? members))
        (def inset group-inset)
        (def head 12)   # room for the name, above the topmost member
        (var minx math/inf) (var maxx (- math/inf))
        (var miny math/inf) (var maxy (- math/inf))
        (each name members
          (def p (places name))
          (def s (sizes name))
          (set minx (min minx (- (p :x) (s :w)))) (set maxx (max maxx (+ (p :x) (s :w))))
          (set miny (min miny (- (p :y) (s :h)))) (set maxy (max maxy (+ (p :y) (s :h)))))
        (buffer/push-string out
          (string/format `<g class="cluster"><title>%s</title>` (escape (g :prefix)))
          (string/format
            `<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="8" fill="none" stroke="%s" stroke-width="1" stroke-dasharray="4 3" opacity="0.7"/>`
            (- minx inset) (- miny inset head)
            (+ (- maxx minx) (* 2 inset)) (+ (- maxy miny) (* 2 inset) head)
            (escape (g :color)))
          (string/format
            `<text x="%.1f" y="%.1f" font-family="%s" font-size="11" fill="%s">%s</text>`
            (+ (- minx inset) 4) (- miny inset head -1) (escape font)
            (escape (g :color)) (escape (g :prefix))))
        (buffer/push-string out `</g>`))))

  # WHERE EVERY OTHER EDGE IS GOING TO BE, so each can ask whether going
  # straight would cut across one. Two lines crossing in open space is as
  # much of a mess as a line through a node, and it is the kind a reader
  # notices first; an edge that would cause one takes its route instead.
  #
  # AN EDGE WITH BENDS IS COMPARED AGAINST ITS ROUTE, not against the
  # straight line it will not be drawn as. The layout reserved those bends
  # because the edge spans ranks, so the route is what appears -- and
  # comparing against the straight version misses exactly the crossings that
  # matter. `src/config -> src/graph` cut across the routes of three of its
  # own siblings and was called clear, because straight-to-straight none of
  # the four intersect: their routes swing wide and its straight line went
  # through the space they swung into.
  # WHERE EACH ARROW LANDS, so a dozen edges into one node do not all arrive
  # at the same point. Twelve arrowheads stacked on `src/core` read as one
  # dark smear and say nothing about how many edges there are; spread along
  # the boundary they are countable.
  #
  # The spread is by ARRIVAL ANGLE: edges are sorted by the direction they
  # come from and given evenly spaced slots within the arc they already
  # occupy, so an edge never crosses its neighbours to reach its slot and the
  # fan keeps the order the layout put them in. A node with one or two
  # incoming edges gets no offset at all -- there is nothing to separate.
  (def fan @{})
  (do
    (def incoming @{})
    (each [from to] edges
      (when (and (places from) (places to) (not= from to))
        (put incoming to (array/push (or (incoming to) @[]) from))))
    (eachp [to sources] incoming
      (when (> (length sources) 2)
        (def b (places to))
        (def angled
          (sorted-by (fn [from]
                       (def a (places from))
                       (math/atan2 (- (a :y) (b :y)) (- (a :x) (b :x))))
                     sources))
        (def n (length angled))
        # Half a node-width of arc, centred: wide enough to separate the
        # heads, narrow enough that an edge still points at its target.
        (def spread (min 1.1 (* 0.16 n)))
        (eachp [i from] angled
          (put fan [from to] (- (* spread (/ i (- n 1))) (/ spread 2)))))))

  (def paths @[])
  (each [from to] edges
    (def a (places from))
    (def b (places to))
    (when (and a b (not= from to))
      (def bends (or (get routes [from to]) []))
      (def p (on-ellipse a ((sizes from) :w) ((sizes from) :h)
                         (if (empty? bends) (b :x) ((first bends) 0))
                         (if (empty? bends) (b :y) ((first bends) 1)) 0))
      (def q (on-ellipse b ((sizes to) :w) ((sizes to) :h)
                         (if (empty? bends) (a :x) ((last bends) 0))
                         (if (empty? bends) (a :y) ((last bends) 1)) 0))
      (array/push paths {:from from :to to
                         :points (array [(p 0) (p 1)]
                                        ;(map |[($ 0) ($ 1)] bends)
                                        [(q 0) (q 1)])})))

  # Edges next, so nodes sit on top of them.
  (each [from to] edges
    (def a (places from))
    (def b (places to))
    (when (and a b (not= from to))
      (def bends (or (get routes [from to]) []))
      (buffer/push-string out
        (string/format `<g class="edge"><title>%s-&gt;%s</title>`
                       (escape from) (escape to))
        (string/format
          `<path d="%s" stroke="var(--edge, #888)" stroke-width="1.2" fill="none" marker-end="url(#arrow)"/>`
          (path-through a b (sizes from) (sizes to) bends
                        from to places sizes box-rects paths
                        (get fan [from to] 0)
                        (get corridors [from to] [])))
        `</g>`)))

  (each node nodes
    (def name (node :name))
    (def p (places name))
    (when p
      (def label (or (node :label) name))
      (def rows (lines-of label))
      (def s (sizes name))
      (def claimed (group-for name))
      (def hue (if claimed (claimed :color) color/ungrouped))
      (def weight (or (weights name) 0))
      (def fill (color/tint hue weight))
      # The label sits centred on the node, so a two-line label starts half a
      # line above the middle.
      (def top (- (p :y) (/ (* (- (length rows) 1) line-height) 2) -4))
      (buffer/push-string out
        (string/format `<g class="node"><title>%s</title>` (escape name))
        (string/format
          `<ellipse cx="%.1f" cy="%.1f" rx="%.1f" ry="%.1f" fill="%s" stroke="%s" stroke-width="1.2"/>`
          (p :x) (p :y) (s :w) (s :h)
          (if filled (escape fill) "none")
          (escape hue))
        (string/format
          `<text text-anchor="middle" font-family="%s" font-size="11" fill="%s">`
          (escape font)
          (escape (if filled (color/ink fill) (color/ink-on-page hue)))))
      (eachp [i row] rows
        (buffer/push-string out
          (string/format `<tspan x="%.1f" y="%.1f">%s</tspan>`
                         (p :x) (+ top (* i line-height)) (escape row))))
      (buffer/push-string out `</text></g>`)))

  (buffer/push-string out "</svg>")
  (string out))
