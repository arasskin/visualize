# Positions to a picture.
#
# THE OTHER HALF OF A LAYOUT. A layout module answers where things go; this
# turns that answer into the same shape of SVG the page already knows how to
# read -- `g.node` with a `<title>` naming it and `<text>` for the label,
# `g.edge` with a `<title>` of "from->to". Matching graphviz's output
# structure is deliberate: the page's panning, edge highlighting and node
# labelling all work unchanged, so a new layout is a layout and not a
# rewrite of the front end.

(import ../color)

(def- pad 40)          # margin around the drawing
(def- rx 54)           # node radius, x
(def- ry 22)           # node radius, y

(defn- escape [text]
  (->> (string text)
       (string/replace-all "&" "&amp;")
       (string/replace-all "<" "&lt;")
       (string/replace-all ">" "&gt;")))

(defn- bounds [places]
  (var minx math/inf) (var miny math/inf)
  (var maxx (- math/inf)) (var maxy (- math/inf))
  (eachp [_ p] places
    (set minx (min minx (p :x))) (set maxx (max maxx (p :x)))
    (set miny (min miny (p :y))) (set maxy (max maxy (p :y))))
  (if (= minx math/inf)
    [0 0 100 100]
    [(- minx rx pad) (- miny ry pad)
     (+ (- maxx minx) (* 2 (+ rx pad))) (+ (- maxy miny) (* 2 (+ ry pad)))]))

(defn- edge-path
  ``A line from the edge of one node to the edge of the next, stopped short
  of the arrowhead. Straight rather than splined: a curve through a
  force-directed layout has nothing to curve around, and the honest
  straight line is easier to follow.``
  [a b]
  (def dx (- (b :x) (a :x)))
  (def dy (- (b :y) (a :y)))
  (def d (max 1 (math/sqrt (+ (* dx dx) (* dy dy)))))
  (def ux (/ dx d))
  (def uy (/ dy d))
  # Leave each ellipse at its own boundary, roughly -- exact would need the
  # ellipse intersection, and at these proportions nobody can tell.
  (def start-gap (+ (* rx (math/abs ux)) (* ry (math/abs uy))))
  (def end-gap (+ start-gap 9))
  [(+ (a :x) (* ux start-gap)) (+ (a :y) (* uy start-gap))
   (- (b :x) (* ux end-gap)) (- (b :y) (* uy end-gap))])

(defn draw
  ``The graph as SVG, laid out by `places`.

  `opts` carries what the config decided, the same keys the DOT renderer
  reads: :groups, :filled, :font, :weights. Group membership colours a
  node; there are no cluster boxes, because a force layout has no reason
  to keep a group contiguous and a box drawn around scattered members
  would claim a structure the picture does not have.``
  [graph places &opt opts]
  (default opts {})
  (def nodes (get graph :nodes []))
  (def edges (get graph :edges []))
  (def font (or (opts :font) "Helvetica"))
  (def [vx vy vw vh] (bounds places))
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
    `<defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5"`
    ` markerUnits="userSpaceOnUse" markerWidth="10" markerHeight="10"`
    ` orient="auto">`
    `<path d="M0,0 L10,5 L0,10 z" fill="var(--edge, #888)"/></marker></defs>`)

  # Edges first, so nodes sit on top of them.
  (each [from to] edges
    (def a (places from))
    (def b (places to))
    (when (and a b)
      (def [x1 y1 x2 y2] (edge-path a b))
      (buffer/push-string out
        (string/format
          `<g class="edge"><title>%s-&gt;%s</title>`
          (escape from) (escape to))
        (string/format
          `<path d="M%.1f,%.1f L%.1f,%.1f" stroke="var(--edge, #888)"`
          x1 y1 x2 y2)
        ` stroke-width="1.2" fill="none" marker-end="url(#arrow)"/></g>`)))

  (each node nodes
    (def name (node :name))
    (def p (places name))
    (when p
      (def label (or (node :label) name))
      (buffer/push-string out
        (string/format `<g class="node"><title>%s</title>` (escape name))
        (string/format
          `<ellipse cx="%.1f" cy="%.1f" rx="%d" ry="%d" fill="%s" stroke="var(--node-line, #667)"/>`
          (p :x) (p :y) rx ry
          (if (opts :filled) "var(--node-fill, #eef)" "none"))
        (string/format
          `<text x="%.1f" y="%.1f" text-anchor="middle" font-family="%s" font-size="12">%s</text>`
          (p :x) (+ (p :y) 4) (escape font) (escape label))
        `</g>`)))

  (buffer/push-string out "</svg>")
  (string out))
