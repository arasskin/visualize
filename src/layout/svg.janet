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
(import ./funnel)

(def- pad 40)          # margin around the drawing
(def- ry-base 16)      # half-height of a single-line node
(def- line-height 14)  # a label line, in user units
(def- char-width 6.1)  # an average glyph at font-size 11 -- see width-of

(def- bend-radius
  ``How far before its corner a routed edge starts turning, and how far
  after it stops. THE dial for the character of the long edges: the line
  runs dead straight between the corners the funnel chose, and each turn
  occupies this much of the runs either side. Half a rank gap reads as
  sweeping; a few units reads as plumbing. See fit/rounded.``
  36)

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
    ``What a straight line from (x1,y1) to (x2,y2) touches that it has no
    business touching: :solid for a node or a group box it is not part of,
    :line for another edge's straight line, nil for clear.

    THE TWO VERDICTS ARE NOT THE SAME KIND OF MESS, which is why this
    reports a kind rather than a boolean. A node or a box is a REGION: a
    curve can go around it, so :solid is an instruction to bow or take the
    reserved route. Another edge's line is a DIVIDER: if this edge's
    endpoints lie on opposite sides of it, every curve between them
    crosses it somewhere -- bowing moves the crossing, adds a kink, and
    fixes nothing. The boolean version of this function sent line-blocked
    edges into the bow machinery anyway, and `fit -> svg` came out bent
    around a crossing it still had.``
    [x1 y1 x2 y2]
    (if (or (nil? places) (nil? sizes))
      nil
      (do
        (var hit nil)
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
                (set hit :solid)))))
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
                  (set hit :solid))))))
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
                (unless near (set hit :line)))))))
        hit)))

  # THE ARROW LANDS ON THE NODE. The path runs to the boundary itself, and
  # the marker's refX puts the arrow's TIP at that point rather than its
  # tail -- so the head touches the ellipse the way it does in dot's output.
  # Stopping short by the marker's length, which is what the 9 here used to
  # do, subtracted the arrowhead twice and left every edge floating a
  # visible gap away from the node it points at.

  (defn with-overhangs
    ``The corridor plus everything solid the chain passes, as extra gates.

    The corridor's own gates keep a bend inside its slot AT each rank
    line, and nothing else: the bands between ranks are open, and both
    group boxes and node ellipses stand in them. A group box is drawn
    taller than its members' ranks -- half a node plus the inset hangs
    past the first and last -- and a segment between two legally-placed
    bends can cut that overhanging corner; a node's ellipse bulges into
    the band and a diagonal curve can graze its shoulder. The placement
    pass used to prevent the first by walling the box's whole x-range off
    one rank further, which pushed every passing bundle a box-width
    sideways and back -- the S-curves this replaces. Keeping curves off
    solids between rank lines is a ROUTING job, so the solids join the
    corridor here as gates and the funnel rounds them instead.

    EACH OBSTACLE PICKS ITS SIDE ONCE, at the midpoint of the stretch the
    path shares with it. Deciding per gate line looked more precise and
    was wrong: the interpolated path drifts across an obstacle's centre
    line between its top and bottom, the two edges then clipped opposite
    sides, and the gates contradicted each other -- the funnel refused
    and the whole edge silently fell back to the spline that checks
    nothing, which is how `stamp -> core` cut a box corner while the code
    to prevent exactly that sat unreachable.

    THE SHAPE OF THE INSERTION: at each horizontal edge of an obstacle,
    one gate ON the edge, clipped to its chosen side, and one just
    OUTSIDE it, clipped only by whatever else reaches that y -- the
    outside gate is what tells the funnel the space past the obstacle is
    open. Two obstacles side by side each clip their own side, which is
    how a path threads the channel between them.``
    [start goal corridor &opt extra]
    (do
      (do
        (def [sx sy] start)
        (def [gx gy] goal)
        # The path as the renderer knows it so far: endpoints and slid
        # bends, for deciding which side of an obstacle the chain passes.
        (def pts (array [sx sy] ;(map (fn [[x y]] [x y]) bends) [gx gy]))
        (defn path-x [y]
          (var out sx)
          (for i 0 (- (length pts) 1)
            (def [ax ay] (pts i))
            (def [bx by] (pts (+ i 1)))
            (when (and (<= ay y) (<= y by) (< ay by))
              (set out (+ ax (* (- bx ax) (/ (- y ay) (- by ay)))))))
          out)
        # Clearance matches a bend's slot: enough that the line reads as
        # beside the obstacle, not against it.
        (def pad 8)
        (def obstacles @[])
        (defn consider [x0 x1 y0 y1 &opt side]
          (when (and (< y0 gy) (> y1 sy))
            # The side, decided once, where the path and the obstacle
            # actually share the page -- unless the caller has already
            # decided it. A path that passes THROUGH an obstacle gives
            # this heuristic a coin to flip, and pass-between search
            # (route-dodging) flips it deliberately instead.
            (def my (/ (+ (max y0 sy) (min y1 gy)) 2))
            (array/push obstacles
                        {:x0 x0 :x1 x1 :y0 y0 :y1 y1
                         :right? (if (nil? side)
                                   (>= (path-x my) (/ (+ x0 x1) 2))
                                   side)})))
        # Group boxes the edge does not belong to.
        (when box-rects
          (each r box-rects
            (unless (or (get (r :members) from) (get (r :members) to))
              (consider (r :x0) (r :x1) (r :y0) (r :y1)))))
        # Node ellipses standing near the path -- their bounding boxes,
        # which is what dot's maximal_bbox subtracts too. Only the ones
        # the path actually passes: an obstacle two hundred units away
        # would still pick a side, and enough far-off sides eventually
        # contradict each other for no drawing benefit.
        #
        # NEARNESS IS CHECKED ACROSS THE WHOLE BAND, not at the centre
        # height alone. A diagonal sweeps sideways as it crosses a node's
        # vertical extent, and `json -> graph` passed dead through
        # `src/http`'s shoulder while measuring 53.6 units away at http's
        # centre line -- 0.7 past the cutoff, excluded, unprotected. Top,
        # centre and bottom of the band catch what a single sample cannot.
        (when (and places sizes)
          (eachp [name p] places
            (unless (or (= name from) (= name to))
              (def s (sizes name))
              (def margin (+ (s :w) 28))
              (when (some (fn [y] (< (math/abs (- (path-x y) (p :x))) margin))
                          [(- (p :y) (s :h)) (p :y) (+ (p :y) (s :h))])
                (consider (- (p :x) (s :w)) (+ (p :x) (s :w))
                          (- (p :y) (s :h)) (+ (p :y) (s :h)))))))
        # MANDATORY EXTRAS, no proximity vote: the caller found the routed
        # curve inside these after the fact. Discovery from the raw path
        # cannot see where a DETOUR will wander -- `scan -> watch` dodged
        # its known obstacle straight through two nodes it was never warned
        # about -- so the router re-routes with the invaded nodes added,
        # until the result invades nothing.
        (when extra
          (each r extra
            (consider (r :x0) (r :x1) (r :y0) (r :y1) (r :right?))))
        (if (empty? obstacles)
          corridor
          (do
            (defn clipped
              "The free interval at y, after every obstacle reaching it."
              [y]
              (var left -2000)
              (var right 2000)
              (each o obstacles
                (when (and (<= (o :y0) y) (<= y (o :y1)))
                  (if (o :right?)
                    (set left (max left (+ (o :x1) pad)))
                    (set right (min right (- (o :x0) pad))))))
              [left right])
            (def stations @[])
            # A STATION KEEPS THE EDGE IN ITS OWN LANE -- the lane AT THAT
            # HEIGHT, which between rank lines is the interpolated channel,
            # not the gate above. The side clip alone says only "past the
            # obstacle", and every edge whose lane conflicts with the box
            # then corners at the SAME point, the clip's edge --
            # `watchdog -> core` lay on top of `stamp -> core` there. The
            # first fix carried the gate ABOVE the station down to it, and
            # manufactured the opposite artifact: watchdog's lane runs
            # diagonally, its rank-1 gate pinned the path to a column its
            # chord had already left, and a perfectly straight lane drew a
            # corner. The channel lerp is the lane's actual span at the
            # station's y: intersected with the clip, an edge whose lane
            # clears the obstacle keeps its straight line, and one whose
            # lane conflicts falls back to the clip edge and rounds the
            # corner there -- distinct corners for distinct lanes, straight
            # lines for lanes that were never in the way.
            (each o obstacles
              # THE BAND IS CLAMPED INTO THE EDGE'S SPAN before stations
              # are placed. A node standing at the source's or target's own
              # rank has band edges outside (sy, gy), and stations placed
              # at the true edges were all filtered out -- the obstacle was
              # added, silently ignored, and re-added by the dodging loop
              # forever: `scan -> watch`, one rank tall, invaded two nodes
              # whose bands both straddled its endpoints. The obstacle
              # still constrains whatever slice of it the edge crosses;
              # the stations mark that slice.
              (def y0c (max (o :y0) (+ sy 0.5)))
              (def y1c (min (o :y1) (- gy 0.5)))
              # AN EDGE THAT STARTS INSIDE AN OBSTACLE'S BAND cannot be
              # constrained at its entry: the start point is FIXED, and a
              # gate at (or clamped to) the start's height demanding the
              # far side of the obstacle forces the funnel into a
              # horizontal teleport through whatever stands between --
              # `stamp -> core` jumped 400 units sideways at its own
              # starting height, through `src/watchdog`, to satisfy a gate
              # for an obstacle whose band its source shares. Only the
              # edge of the band the path EXITS through can bind; same for
              # the goal, mirrored.
              (def top-binds (> (o :y0) sy))
              (def bottom-binds (< (o :y1) gy))
              (def station-ys
                (array ;(if top-binds [[(- y0c 1) false] [y0c true]] [])
                       ;(if bottom-binds [[y1c true] [(+ y1c 1) false]] [])))
              (each [y on-edge?] station-ys
                (when (and (> y sy) (< y gy) (<= y0c y1c))
                  (def [l r] (clipped y))
                  # Only the obstacle's own edges hold the lane; the
                  # stations just outside exist to say the space is open
                  # again, and pinning those to the lane would delay every
                  # turn a rank.
                  (def carried
                    (when on-edge?
                      (when-let [[cl cr] (funnel/channel corridor y)]
                        (def il (max cl l))
                        (def ir (min cr r))
                        (when (< il ir) [il ir]))))
                  # A STATION THAT CLOSED is dropped alone, not fatal:
                  # two obstacles pinching from opposite sides can leave
                  # nothing at one height, and the first version declared
                  # the whole augmentation impossible and handed back the
                  # BARE corridor -- every obstacle dropped for the whole
                  # edge, which is how `json -> graph` drew through
                  # `src/http` under a crowded layout: all-or-nothing
                  # protection removed itself exactly where it was most
                  # needed. One unsatisfiable height loses one gate; the
                  # rest keep standing guard.
                  (def station (or carried (when (< l r) [l r])))
                  (when station
                    (array/push stations [(station 0) (station 1) y])))))
            # MERGE, coalescing gates that landed on the same line. Same
            # per-station degradation: an intersection that empties keeps
            # what stands and forgets the newcomer -- and corridor gates
            # sort ahead of stations at equal height, so the corridor is
            # what stands. The corridor is ground truth; a station is
            # advice.
            (def merged @[])
            (def tagged (array ;(map (fn [[l r y]] [l r y 0]) corridor)
                               ;(map (fn [[l r y]] [l r y 1]) stations)))
            (each [l r y _] (sorted tagged
                                    (fn [a b] (if (= (a 2) (b 2))
                                                (< (a 3) (b 3))
                                                (< (a 2) (b 2)))))
              (if (and (not (empty? merged)) (= ((last merged) 2) y))
                (let [[pl pr _] (last merged)
                      nl (max pl l)
                      nr (min pr r)]
                  (when (<= nl nr)
                    (put merged (- (length merged) 1) [nl nr y])))
                (array/push merged [l r y])))
            merged)))))
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
                         wants (+ ax (* t (- bx ax)))
                         # THE SLIDE SMOOTHS; IT NO LONGER STEERS. It once
                         # spent a slot's whole spare width pulling each
                         # bend toward its own chord, and the layout's
                         # bundling could not survive it: a bundle's
                         # OUTERMOST member always has open space on its
                         # outside, so its budget was huge and it slid
                         # clean off the band back onto its private
                         # diagonal -- `watchdog -> core` deserted the
                         # flock the placement pass had just packed it
                         # into, drew itself one straight line, and left
                         # `stamp -> core` looking abandoned mid-journey.
                         # Where a lane runs is the LAYOUT's decision now
                         # (aims, flocking, settle); the renderer may nudge
                         # a bend by a few units to iron a wobble, never
                         # relocate it.
                         budget (min 6 (max 0 (/ (- right left 24) 2)))
                         low (max left (- (bend 0) budget))
                         high (min right (+ (bend 0) budget))]
                     [(min high (max low wants)) (bend 1)])))
               (range (length bends)) bends))))

  # THE LANE IS THE SLID BEND, NOT THE WHOLE SLOT. Routing through the
  # full corridor lets every edge straighten independently, and a bundle
  # then reads as a CONVERGING FAN: each member cuts its own corners, the
  # gaps between them breathe in and out, and nothing looks parallel even
  # though the layout laid the lanes evenly. The gates the router gets are
  # therefore the corridor pinched to a few units around each slid bend --
  # the lane's centre line, which `cohere` aligned across ranks and the
  # bundle ordering pitched evenly. Members then hold a CONSTANT offset
  # from each other, which is what a reader calls parallel. A solo edge
  # loses nothing: the slide just put its bend on its own straight line,
  # so its pinched lane IS that line.
  (def lanes
    (seq [i :range [0 (length bends)] :when (get corridor i)]
      (def [l r y] (corridor i))
      (def bx ((bends i) 0))
      [(max l (- bx 10)) (min r (+ bx 10)) y]))

  (defn invaded-by
    ``The nodes the fitted segments actually enter, as obstacle rects.

    Discovery before routing works from a path that does not exist yet;
    this is the check after, on the curve as it will be drawn. Entering
    means inside the outline with margin to spare -- a graze is the fit's
    slack at work, not an invasion.``
    [start segs]
    (def out @[])
    (when (and places sizes)
      (eachp [name p] places
        (unless (or (= name from) (= name to))
          (def s (sizes name))
          (var deepest 99)
          (var sx (start 0)) (var sy (start 1))
          (each [c1 c2 end] segs
            (for k 0 13
              (def t (/ k 12))
              (def u (- 1 t))
              (def px (+ (* u u u sx) (* 3 u u t (c1 0))
                         (* 3 u t t (c2 0)) (* t t t (end 0))))
              (def py (+ (* u u u sy) (* 3 u u t (c1 1))
                         (* 3 u t t (c2 1)) (* t t t (end 1))))
              (def dx (/ (- px (p :x)) (max 0.001 (s :w))))
              (def dy (/ (- py (p :y)) (max 0.001 (s :h))))
              (def d2 (+ (* dx dx) (* dy dy)))
              (when (< d2 deepest) (set deepest d2)))
            (set sx (end 0)) (set sy (end 1)))
          (when (< deepest 0.9)
            (array/push out {:x0 (- (p :x) (s :w)) :x1 (+ (p :x) (s :w))
                             :y0 (- (p :y) (s :h)) :y1 (+ (p :y) (s :h))})))))
    out)

  (defn slab-route
    ``The slab tier: free space as horizontal bands, segments bounded
    everywhere, run only on edges the side model leaves dirty.

    THE Y-GATE FAMILY'S SHARED BLINDNESS was that every variant -- side
    clips, enumerated sides, interval sets -- constrained where a path
    crosses chosen heights and said nothing about the segments BETWEEN
    them; the residual edges crossed nodes exactly there. Slabs are
    dot's model, and they bound segments: the edge's whole y-span is cut
    into bands at every obstacle edge and lane-gate height, each band
    knows its free intervals, and a path that picks an interval per band
    is inside free space at EVERY height, because the bands tile.

    One interval per band is chosen by a dynamic program whose
    transitions demand OVERLAP -- a portal -- between consecutive
    choices, intersected with the lane gate where a band boundary
    carries one. The chosen portals are handed to the ordinary funnel as
    gates, and the fitter's channel check is conservative by
    construction: the lerp between two portals stays inside the band
    both portals border. Funnel and fitter unchanged, blindness gone.

    A FALLBACK TIER, accepted only when clean, run once with the lane
    folded in and once without -- the lane is advice about where the
    bundle would like this edge, and not crossing a node is law. The
    obstacle discovery deliberately mirrors with-overhangs rather than
    sharing code: the tier is a second, independent opinion, and
    independence is the point. (Its predecessor here was the interval-
    set tier, same discipline, dominated by this one and removed: sets
    fixed "between these two" at a height and stayed blind between
    heights; slabs fix both.)``
    [start goal gates extra]
    (def [sx sy] start)
    (def [gx gy] goal)
    (def pts (array [sx sy] ;(map (fn [[x y]] [x y]) bends) [gx gy]))
    (defn path-x [y]
      (var out sx)
      (for i 0 (- (length pts) 1)
        (def [ax ay] (pts i))
        (def [bx by] (pts (+ i 1)))
        (when (and (<= ay y) (<= y by) (< ay by))
          (set out (+ ax (* (- bx ax) (/ (- y ay) (- by ay)))))))
      out)
    (def pad 8)
    (def rects @[])
    (defn take-rect [x0 x1 y0 y1]
      (when (and (< y0 gy) (> y1 sy))
        (array/push rects {:x0 x0 :x1 x1 :y0 y0 :y1 y1})))
    (when box-rects
      (each r box-rects
        (unless (or (get (r :members) from) (get (r :members) to))
          (take-rect (r :x0) (r :x1) (r :y0) (r :y1)))))
    (when (and places sizes)
      (eachp [name p] places
        (unless (or (= name from) (= name to))
          (def s (sizes name))
          (def margin (+ (s :w) 28))
          (when (some (fn [y] (< (math/abs (- (path-x y) (p :x))) margin))
                      [(- (p :y) (s :h)) (p :y) (+ (p :y) (s :h))])
            (take-rect (- (p :x) (s :w)) (+ (p :x) (s :w))
                       (- (p :y) (s :h)) (+ (p :y) (s :h)))))))
    (when extra
      (each r extra
        (take-rect (r :x0) (r :x1) (r :y0) (r :y1))))
    (when (not (empty? rects))
      (defn subtract-span [spans a b]
        (def out @[])
        (each [l r] spans
          (if (or (<= b l) (>= a r))
            (array/push out [l r])
            (do (when (< l a) (array/push out [l a]))
                (when (< b r) (array/push out [b r])))))
        out)
      # Band boundaries: every obstacle edge and every lane-gate height
      # inside the span. Bands between them have constant free space.
      (def evs @[])
      (each o rects
        (each y [(o :y0) (o :y1)]
          (when (and (> y sy) (< y gy)) (array/push evs y))))
      (each [l r y] gates
        (when (and (> y sy) (< y gy)) (array/push evs y)))
      (def cuts (sorted (distinct (array sy ;evs gy))))
      (def bands @[])
      (for i 0 (- (length cuts) 1)
        (def y0 (cuts i))
        (def y1 (cuts (+ i 1)))
        (when (> (- y1 y0) 0.01)
          (def mid (/ (+ y0 y1) 2))
          (var spans @[[-2000 2000]])
          (each o rects
            (when (and (<= (o :y0) mid) (<= mid (o :y1)))
              (set spans (subtract-span spans
                                        (- (o :x0) pad)
                                        (+ (o :x1) pad)))))
          # A sliver is not a passage.
          (array/push bands
                      [y0 y1 (filter (fn [[l r]] (>= (- r l) 14)) spans)])))
      (def gate-at @{})
      (each [l r y] gates (put gate-at y [l r]))
      (when (not (empty? bands))
        # One interval per band, chosen jointly: transitions demand a
        # portal, cost is sideways travel, the trail keeps the portals.
        (var prev @[])
        (def [_ _ fspans] (first bands))
        (each [l r] fspans
          (when (and (<= l sx) (<= sx r))
            (array/push prev [0 sx [l r] @[]])))
        (def tracing (= (os/getenv "VISUALIZE_ROUTE_TRACE")
                        (string from "->" to)))
        (when (and tracing (empty? prev))
          (eprintf "  slab: start x=%d in no first-band interval %j"
                   (math/round sx) (get (first bands) 2)))
        (var ok (not (empty? prev)))
        (for k 1 (length bands)
          (when ok
            (def [by0 _ bspans] (bands k))
            (def gate (gate-at by0))
            (def nxt @[])
            (each [l r] bspans
              (var best nil)
              (each [c px prev-span trail] prev
                (def [pl pr] prev-span)
                (var il (max l pl))
                (var ir (min r pr))
                (when gate
                  (set il (max il (gate 0)))
                  (set ir (min ir (gate 1))))
                (when (>= (- ir il) 6)
                  (def nx (min ir (max il px)))
                  (def nc (+ c (math/abs (- nx px))))
                  (when (or (nil? best) (< nc (best 0)))
                    (set best [nc nx [l r] (array ;trail [il ir by0])]))))
              (when best (array/push nxt best)))
            (if (empty? nxt)
              (do
                (when tracing
                  (eprintf "  slab: dead at band y=%d spans=%j gate=%j"
                           (math/round by0) bspans gate))
                (set ok false))
              (set prev nxt))))
        (when ok
          (var final nil)
          (each [c px last-span trail] prev
            (def [l r] last-span)
            (when (and (<= l gx) (<= gx r))
              (def nc (+ c (math/abs (- gx px))))
              (when (or (nil? final) (< nc (final 0)))
                (set final [nc trail]))))
          (when (and tracing (nil? final))
            (eprintf "  slab: goal x=%d in no last-band interval %j"
                     (math/round gx)
                     (map (fn [[_ _ sp _]] sp) prev)))
          (when final
            (def out-gates (final 1))
            (def p (funnel/path start goal out-gates))
            (when (and tracing (nil? p))
              (eprintf "  slab: funnel refused %d portals" (length out-gates)))
            (def segs (when p (fit/rounded p out-gates bend-radius)))
            (when (and tracing p (nil? segs))
              (eprintf "  slab: fit refused"))
            (when (and tracing segs)
              (eprintf "  slab: routed, %d segments through %d portals: %j"
                       (length segs) (length out-gates)
                       (map (fn [[l r y]] [(math/round l) (math/round r) (math/round y)])
                            out-gates)))
            segs)))))

  (defn route-dodging
    ``Route start to goal through `gates`, iterating obstacle discovery.

    Discovery from the raw path cannot see where a DETOUR will wander:
    `scan -> watch` dodged the one obstacle it knew about straight through
    two nodes it was never warned about. So: route, check the RESULT
    against every node, add the invaded ones as mandatory obstacles,
    route again -- until clean or the retries run out. The last candidate
    is returned even if still dirty; it dodges everything it knew, which
    beats a fallback that dodges nothing.``
    [start goal gates]
    (defn route-once [extras]
      (def aug (with-overhangs start goal gates extras))
      (when (not (empty? aug))
        (when-let [p (funnel/path start goal aug)]
          (fit/rounded p aug bend-radius))))
    (defn run-length [segs]
      (var total 0)
      (var px (start 0)) (var py (start 1))
      (each [_ _ end] segs
        (def dx (- (end 0) px)) (def dy (- (end 1) py))
        (+= total (math/sqrt (+ (* dx dx) (* dy dy))))
        (set px (end 0)) (set py (end 1)))
      total)
    (defn inner-dodge
      ``The route/check/add loop from a given starting set of obstacles.
      Returns [segs extras clean?]: the last candidate, the obstacle set
      as it grew, and whether the candidate invades nothing.``
      [seed]
      (def extra (array ;seed))
      (defn remember [v]
        (unless (some (fn [e] (and (= (e :x0) (v :x0)) (= (e :y0) (v :y0))))
                      extra)
          (array/push extra v)))
      (var candidate nil)
      (var clean false)
      (var tries 0)
      (while (and (not clean) (< tries 3))
        (++ tries)
        (def segs (route-once extra))
        (if (nil? segs)
          (set tries 3)
          (do
            (set candidate segs)
            (def invaders (invaded-by start segs))
            (if (empty? invaders)
              (set clean true)
              (each v invaders (remember v))))))
      [candidate extra clean])
    (def [candidate extra clean] (inner-dodge []))
    (var accepted (when clean candidate))
    (when (and (nil? accepted) candidate
               (os/getenv "VISUALIZE_ROUTE_DEBUG"))
      (eprintf "dodge: %s->%s heuristic sides leave it dirty (%d obstacles)"
               (string from) (string to) (length extra)))
    # PASS-BETWEEN. An obstacle the path goes THROUGH gives the side
    # heuristic a coin to flip, and two bad flips contradict: one says
    # left, the next says right, the channel between them is narrower
    # than both pads, and the merged station empties -- protection
    # cancels itself exactly where two obstacles pinch. With the
    # heuristic exhausted, the sides of the invaded obstacles are
    # ENUMERATED: at most three invaders is eight assignments, each run
    # through the full dodging loop, and the shortest clean one wins.
    #
    # WHAT THIS DOES AND DOES NOT REACH, measured the day it was built:
    # it answers the contradicting-sides class and is inert when the
    # heuristic succeeds. It does NOT rescue `stamp -> core` under
    # VISUALIZE_SIMPLEX, and the trace says why: that edge's lane forces
    # it across a rank of standing nodes, every assignment routes through
    # a region where SOME station has been dropped by the per-station
    # degradation (one obstacle's clip empties against another's, the
    # gate vanishes, the curve walks through where it stood), and no
    # side assignment can express "between these two" when the free
    # space at one height is two disjoint intervals. The honest fix for
    # that residue is gates that hold interval SETS -- a funnel over
    # multi-interval gates -- which changes the model, not the search.
    #
    # THE SET MODEL WAS BUILT, AND REVERTED, 2026-08-17. Free space by
    # subtraction, no sides at all, a shortest-travel resolve choosing
    # one interval per gate, funnel unchanged downstream -- the design
    # was right and the integration was wrong: it REPLACED the side
    # model everywhere, re-deciding routes that were already clean, and
    # the default went from 0 through to 2 while chasing a defect the
    # default did not have. Three patches deep (sliver filters, edge
    # binding, endpoint clamps) each fix exposed the next, because
    # wholesale replacement has to reproduce every behaviour the old
    # model got right before it can fix the one it got wrong. When this
    # resumes: introduce the set model as a FALLBACK TIER -- run the
    # side model first, and only where its result still invades, re-route
    # that one edge under interval sets. The clean edges never notice;
    # the residue gets the stronger model; parity is owed for nothing.
    (when (and (nil? accepted) (not (empty? extra)) (<= (length extra) 3))
      (var best nil)
      (var best-len math/inf)
      (def n (length extra))
      (for mask 0 (blshift 1 n)
        (def forced (seq [i :range [0 n]]
                      (merge (extra i) {:right? (odd? (brshift mask i))})))
        # Each assignment gets the FULL dodging loop, not one route: the
        # detour a flipped side produces can wander into obstacles the
        # seed set never met -- watchdog-left sends `stamp -> core` under
        # its own rank and into territory the right-side attempt never
        # visited -- and a single route judged that assignment on its
        # first draft.
        (def [segs _ clean2] (inner-dodge forced))
        (when (= (os/getenv "VISUALIZE_ROUTE_TRACE")
                 (string from "->" to))
          (eprintf "  mask %d: %s" mask
                   (cond (nil? segs) "no route"
                         clean2 "CLEAN"
                         "dirty")))
        (when (and segs clean2)
          (def len (run-length segs))
          (when (< len best-len)
            (set best-len len)
            (set best segs))))
      (when best
        (when (os/getenv "VISUALIZE_ROUTE_DEBUG")
          (eprintf "dodge: %s->%s pass-between cleaned it (%d assignments tried)"
                   (string from) (string to) (blshift 1 n)))
        (set accepted best)))
    # THE SLAB TIER, last. Everything above works at chosen heights;
    # where all of it leaves the route dirty, the edge is re-run under
    # slabs, which bound the segments between heights too. Once with the
    # lane folded into the portals, once without -- the lane is advice
    # about where the bundle would like this edge, and not crossing a
    # node is law. The tier's answer is taken only if it comes back
    # CLEAN: a dirty answer from the stronger model does not displace a
    # dirty answer from the weaker one, it just costs more.
    # Each slab rung iterates like the main loop: the tier's route can
    # wander far from the raw path the proximity vote was taken along --
    # the laneless rung sent `stamp -> core` down the picture's left edge,
    # where nothing had ever been collected as an obstacle -- so invaders
    # found in its result are added and the rung re-run until clean or
    # out of tries.
    (defn slab-tier [tier-gates label]
      (when (nil? accepted)
        (def slab-extra (array ;extra))
        (defn keep [v]
          (unless (some (fn [e] (and (= (e :x0) (v :x0)) (= (e :y0) (v :y0))))
                        slab-extra)
            (array/push slab-extra v)))
        (var stries 0)
        (while (and (nil? accepted) (< stries 3))
          (++ stries)
          (def segs (slab-route start goal tier-gates slab-extra))
          (if (nil? segs)
            (set stries 3)
            (do
              (def inv (invaded-by start segs))
              (if (empty? inv)
                (do
                  (when (os/getenv "VISUALIZE_ROUTE_DEBUG")
                    (eprintf "dodge: %s->%s %s cleaned it (try %d)"
                             (string from) (string to) label stries))
                  (set accepted segs))
                (each v inv (keep v))))))))
    (slab-tier gates "slab tier")
    (slab-tier [] "laneless slab tier")
    (or accepted candidate))

  (defn emit-run [start segs]
    (string/join
      (array (string/format "M%.1f,%.1f" (start 0) (start 1))
             ;(map (fn [[c1 c2 end]]
                     (string/format "C%.1f,%.1f %.1f,%.1f %.1f,%.1f"
                                    (c1 0) (c1 1) (c2 0) (c2 1)
                                    (end 0) (end 1)))
                   segs))
      " "))

  (def straight-from (on-ellipse a (ra :w) (ra :h) (b :x) (b :y) 0))
  (def straight-to (on-ellipse b (rb :w) (rb :h) (a :x) (a :y) 0 turn))

  # THE LANE BEFORE THE SHORTCUT. A multi-rank edge with a corridor routes
  # through it FIRST, even when its own straight line happens to be clear.
  # This used to be the other way around, and the picture showed it: edges
  # travelling together used different regimes -- `watchdog -> core` drew
  # its lucky straight diagonal while `stamp -> core` beside it hugged the
  # box and turned, one line and one curve telling the same story two
  # different ways. The ordering pass already lays sibling edges' bends in
  # adjacent lanes; routing through the lane is what makes the siblings
  # come out as offset copies of each other -- parallel where they travel
  # together, splitting at the ends. A SOLO edge loses nothing: the slide
  # pass pulls its lane onto its own straight line, so its routed curve is
  # the straight line, give or take nothing a reader can see.
  (def routed
    # One lane is enough: a two-rank edge has a single bend, and skipping
    # the router for it -- an early guard asked for two -- sent every
    # one-bend edge to the obstacle-blind spline, which under a packed
    # ranking is exactly where the through-nodes clustered. The funnel
    # handles one gate; the single-narrow-gate case is in its tests.
    (when (and (not (empty? bends)) (>= (length lanes) 1))
      (def first-target (first bends))
      (def last-source (last bends))
      (def [x1 y1] (on-ellipse a (ra :w) (ra :h)
                               (first-target 0) (first-target 1) 0))
      (def [x2 y2] (on-ellipse b (rb :w) (rb :h)
                               (last-source 0) (last-source 1) 0 turn))
      # The gate model runs downward; a back edge's drawn direction does
      # not, and gets its spline as before.
      (when (< y1 y2)
        # ROUNDED CORNERS from the iterating router: straight runs between
        # the funnel's corners, each turn spread `bend-radius` around its
        # corner, re-routed until the result invades no node it was not
        # warned about. See route-dodging.
        (def out (route-dodging [x1 y1] [x2 y2] lanes))
        # WHICH EDGES FELL BACK, AND AT WHICH STAGE. A fallback is silent
        # by design -- something still draws -- and that silence has now
        # hidden the router being broken TWICE, each time found only by
        # noticing an edge cut a box it should have rounded. The question
        # "why did this edge fall back" recurs; this answers it without an
        # afternoon of replication.
        (when (and (os/getenv "VISUALIZE_ROUTE_DEBUG") (nil? out))
          (eprintf "route: %s->%s router declined (%d lanes)"
                   (string from) (string to) (length lanes)))
        # VISUALIZE_ROUTE_TRACE=from->to dumps one edge's routing inputs:
        # the corridor, the augmented gates, and the funnel's path. The
        # question "what did the router actually see for THIS edge" has
        # now been answered by hand-replicating the pipeline three times,
        # and the replication drifts from the real thing every time the
        # pipeline moves.
        (when (= (os/getenv "VISUALIZE_ROUTE_TRACE")
                 (string from "->" to))
          (def augmented (with-overhangs [x1 y1] [x2 y2] lanes))
          (eprintf "trace %s->%s start=%j goal=%j" (string from) (string to)
                   [(math/round x1) (math/round y1)] [(math/round x2) (math/round y2)])
          (eprintf "  lanes:     %j"
                   (map (fn [[l r y]] [(math/round l) (math/round r) (math/round y)]) lanes))
          (eprintf "  augmented: %j"
                   (map (fn [[l r y]] [(math/round l) (math/round r) (math/round y)]) augmented))
          (eprintf "  funnel:    %j"
                   (when-let [p (funnel/path [x1 y1] [x2 y2] augmented)]
                     (map (fn [[px py]] [(math/round px) (math/round py)]) p))))
        (when out (emit-run [x1 y1] out)))))

  (def verdict (when (nil? routed)
                 (hits-anything? (straight-from 0) (straight-from 1)
                                 (straight-to 0) (straight-to 1))))
  (if routed
    routed
    (if (or (nil? verdict)
            # A LINE CROSSING CANNOT BE DODGED, only moved. When the straight
            # line's one offence is crossing another edge's line -- no node,
            # no box -- and there is no reserved route to change the topology,
            # the crossing is a fact of where the endpoints are. Draw the
            # straight line and let the two cross cleanly; the alternative was
            # a bow with the same crossing plus a kink.
            (and (= verdict :line) (empty? bends)))
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
      (do
      # THE ROUTER GETS FIRST REFUSAL, gates built from obstacles alone. A
      # bendless edge has no reserved corridor, but the things blocking it
      # are still regions with sides, and the funnel dodges regions -- the
      # same machinery the long edges use, minus the rank gates. The bow
      # below survives as the fallback for edges the obstacle gates cannot
      # help (an upward edge, or a blocker the funnel model cannot pass).
      # Under a packed ranking this is most of the difference between a
      # drawing and a pincushion: dot routes EVERYTHING, and its short
      # edges dodge like its long ones.
      # NOT FOR EDGES THAT BARELY DESCEND. The gate model constrains where
      # a path crosses horizontal lines, so a nearly-horizontal edge can
      # slide along BETWEEN its own gates through anything: `scan ->
      # watch`, one rank down and five hundred across under the packed
      # ranking, jogged 130 units sideways at its target's height straight
      # through `src/term/host` -- past every gate, violating none. Below
      # one-in-five slope the funnel abstains and the bow tries; a first
      # draft of this guard demanded one-in-1.6 and took the detour away
      # from a dozen edges it was quietly keeping clean. The truly flat
      # case has no good answer yet in either model, and is on the record
      # as such.
      (def detour
        (let [[x1 y1] straight-from
              [x2 y2] straight-to]
          (when (> (- y2 y1) (* 0.2 (math/abs (- x2 x1))))
            (when-let [segs (route-dodging [x1 y1] [x2 y2] [])]
              (emit-run [x1 y1] segs)))))
      (if detour
        detour
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
                       x1 y1 (c 0) (c 1) x2 y2))))
      # Blocked, the router declined (or the edge runs upward), and the
      # layout reserved a route: follow the bends as a CURVE.
      #
      # The bends are where the edge must pass, not corners it must turn.
      # Drawn as line segments they read as plumbing: every multi-rank edge
      # arrives at its target having visibly changed direction two or three
      # times, and a reader tracks the kinks instead of the connection. A
      # curve through the same points says the same thing about where the
      # edge goes and nothing about corners that are not there.
      (let [first-target (first bends)
            last-source (last bends)
            [x1 y1] (on-ellipse a (ra :w) (ra :h)
                                (first-target 0) (first-target 1) 0)
            [x2 y2] (on-ellipse b (rb :w) (rb :h)
                                (last-source 0) (last-source 1) 0 turn)
            pts (array [x1 y1] ;(map |[($ 0) ($ 1)] bends) [x2 y2])]
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
        (defn angle-of [from]
          (def a (places from))
          (math/atan2 (- (a :y) (b :y)) (- (a :x) (b :x))))
        (def angled (sorted-by angle-of sources))
        (def n (length angled))
        # SEPARATE ONLY WHAT IS CLUSTERED. The first version dealt every
        # edge a slot offset from its own natural angle -- evenly spaced
        # across the arc whether the naturals needed spacing or not. An
        # edge arriving from a direction all its own was still rotated to
        # the end of the fan, and on a SHORT edge the rotation is most of
        # what a reader sees: `fit -> svg`, a 24-unit stub between two big
        # ellipses stacked vertically, was tilted a seventh of a radian
        # for the crime of sharing its target with two edges forty degrees
        # away. So: sweep the sorted natural angles enforcing a minimum
        # gap, and offset each edge only by however far the sweep had to
        # move it. Edges already separated move by zero, exactly.
        (def gap 0.16)
        (def naturals (map angle-of angled))
        (def spaced (array (naturals 0)))
        (for i 1 n
          (array/push spaced (max (naturals i) (+ (spaced (- i 1)) gap))))
        # Re-centre so the fan spreads around the cluster rather than
        # shoving it all one way -- the sweep above only ever pushes
        # counter-clockwise.
        (var drift 0)
        (for i 0 n (+= drift (- (spaced i) (naturals i))))
        (set drift (/ drift n))
        (eachp [i from] angled
          (put fan [from to] (- (spaced i) (naturals i) drift))))))

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
