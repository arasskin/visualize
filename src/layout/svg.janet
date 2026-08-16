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
  [p rx ry tx ty extra]
  (def dx (- tx (p :x)))
  (def dy (- ty (p :y)))
  (def d (max 0.0001 (math/sqrt (+ (* dx dx) (* dy dy)))))
  (def ux (/ dx d))
  (def uy (/ dy d))
  # The scale that puts (ux,uy) on the unit circle in ellipse space.
  (def k (/ 1 (max 0.0001 (math/sqrt (+ (/ (* ux ux) (* rx rx))
                                        (/ (* uy uy) (* ry ry)))))))
  [(+ (p :x) (* ux (+ k extra))) (+ (p :y) (* uy (+ k extra)))])

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
  [a b ra rb bends &opt from to places sizes]

  (defn hits-anything?
    ``Does the segment from (x1,y1) to (x2,y2) cut into a node that is
    neither end of this edge? Sampled: the exact test is a quadratic per
    ellipse, and this runs over every node for every edge.``
    [x1 y1 x2 y2]
    (if (or (nil? places) (nil? sizes))
      false
      (do
        (var hit false)
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
        hit)))

  # THE ARROW LANDS ON THE NODE. The path runs to the boundary itself, and
  # the marker's refX puts the arrow's TIP at that point rather than its
  # tail -- so the head touches the ellipse the way it does in dot's output.
  # Stopping short by the marker's length, which is what the 9 here used to
  # do, subtracted the arrowhead twice and left every edge floating a
  # visible gap away from the node it points at.
  (def straight-from (on-ellipse a (ra :w) (ra :h) (b :x) (b :y) 0))
  (def straight-to (on-ellipse b (rb :w) (rb :h) (a :x) (a :y) 0))

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
            c (if (<= (hit one) (hit other)) one other)]
        (string/format "M%.1f,%.1f Q%.1f,%.1f %.1f,%.1f"
                       x1 y1 (c 0) (c 1) x2 y2))
      # Blocked, and the layout reserved a route: use all of it, straight.
      (let [first-target (first bends)
            last-source (last bends)
            [x1 y1] (on-ellipse a (ra :w) (ra :h)
                                (first-target 0) (first-target 1) 0)
            [x2 y2] (on-ellipse b (rb :w) (rb :h)
                                (last-source 0) (last-source 1) 0)
            out @[(string/format "M%.1f,%.1f" x1 y1)]]
        (each [bx by] bends
          (array/push out (string/format "L%.1f,%.1f" bx by)))
        (array/push out (string/format "L%.1f,%.1f" x2 y2))
        (string/join out " ")))))

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
                        from to places sizes))
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
