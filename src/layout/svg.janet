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
  ``The `d` of an edge: from the source's boundary, through any bend points
  the layout gave us, to just short of the target's boundary.``
  [a b ra rb bends]
  (def first-target (if (empty? bends) [(b :x) (b :y)] (first bends)))
  (def last-source (if (empty? bends) [(a :x) (a :y)] (last bends)))
  # THE ARROW LANDS ON THE NODE. The path runs to the boundary itself, and
  # the marker's refX puts the arrow's TIP at that point rather than its
  # tail -- so the head touches the ellipse the way it does in dot's output.
  # Stopping short by the marker's length, which is what the 9 here used to
  # do, subtracted the arrowhead twice and left every edge floating a
  # visible gap away from the node it points at.
  (def [x1 y1] (on-ellipse a (ra :w) (ra :h) (first-target 0) (first-target 1) 0))
  (def [x2 y2] (on-ellipse b (rb :w) (rb :h) (last-source 0) (last-source 1) 0))
  (def out @[(string/format "M%.1f,%.1f" x1 y1)])
  (each [bx by] bends
    (array/push out (string/format "L%.1f,%.1f" bx by)))
  (array/push out (string/format "L%.1f,%.1f" x2 y2))
  (string/join out " "))

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
        (def inset 13)
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
          (path-through a b (sizes from) (sizes to) bends))
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
