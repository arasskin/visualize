# The graph, drawn by graphviz.
#
# WHAT THIS IS. `graph.janet` hands over a parsed graph and the config's
# decisions -- boxes, colours -- and gets
# back [ok svg]. Everything between is DOT: this file writes the graph as a
# DOT document, runs `dot -Tsvg`, and returns what comes out.
#
# WHY DOT AND NOT THE LAYOUT THAT WAS HERE. This project spent a long time
# on its own Sugiyama implementation -- ranking by relaxation and by network
# simplex, an aux-graph coordinate pass, mincross with transpose and sift,
# a funnel-and-slab spline router -- and got it to zero edges through nodes
# and zero clipped outlines on this tool's own graph. It never got to dot's
# crossing count: measured with the same scorer on the same tree, dot drew 2
# edge crossings where the custom layout drew 12, and the last measurable
# step toward closing that gap made the picture visibly worse. Six thousand
# lines of layout for a number that stayed behind the thing already
# installed on the machine. That is the whole argument; the history is in
# git if the trade ever needs re-examining.
#
# THE COST, STATED PLAINLY. `dot` is now a hard runtime dependency -- no
# graph renders without it. That reverses a deliberate property of this
# program (a vendored Janet and nothing else), and it is the price of
# deleting the layout.
#
# THE PAGE CONTRACT SURVIVES. web/app.js reads `g.node` with a `<title>`
# naming the node and `g.edge` with a `<title>` of "from->to" for its
# panning, highlighting and labelling. graphviz emits exactly that shape --
# it is where the convention came from -- except that it encodes the arrow
# as `-&#45;&gt;`, which `graph.janet` normalises on the way out.


# THE FONT, in one place because it has to be true in two.
#
# graphviz SIZES every ellipse from this font's metrics, but an SVG only
# names a font -- it cannot carry one -- so whether the label is DRAWN in it
# is the page's call. src/web/style.css names the same face in
# `--font-config` and applies it to `#graph svg`. The two have to agree: name
# one font here and draw another there, and every box is sized for lettering
# it does not contain.
#
# This USED TO BE A CONFIG VERB, `(font name)`, which could only ever change
# half of that pair -- the sizing moved and the lettering did not. A config
# says what is IN the graph; how the drawing looks on your screen is not a
# fact about your codebase. Changing the face means changing this line and
# the CSS together, which is the honest amount of work for the change.
# NAMED HERE, DRAWN BY THE BROWSER. dot writes this onto every label and the
# @font-face in style.css is what resolves it, so the page draws in the real
# face wherever it is opened -- the TTFs ship in src/web/ beside it.
#
# DOT DOES NOT NEED TO HAVE THE FONT, because it is not asked to measure it:
# every ellipse is given an explicit width below. Left to its own devices it
# would size each one from the metrics it can find, and it looks only where
# fontconfig looks -- not at the repo, and not at FONTCONFIG_FILE either;
# both were tried. A machine without the font installed measured 111pt for a
# label the real face needs 137pt for, which is labels crowding outlines cut
# for other glyphs.
#
# ASKING PEOPLE TO INSTALL A FONT IS NOT A DEPENDENCY THIS EARNS. The sizing
# is arithmetic here instead, and the same on every machine.
(def- font "Parkinsans")

# HOW WIDE AN ELLIPSE HAS TO BE for a label of N characters, in points, at
# fontsize 11.
#
# MEASURED ON THE RENDERED PAGE, not taken from dot. Parkinsans at this size
# draws 5.95px per character, and an ellipse only has its full width across
# the middle -- text fits within about 72% of it -- so a label of n
# characters needs a radius of about 4.1n. The slope here is a little over
# that, which is the air around the word.
#
# TIGHTER THAN DOT WOULD BE. Its own sizing left every node 24 to 43 points
# wider than its longest line; this is the same drawing, more compact.
#
# THE LONGEST LINE, not the whole label. Labels are wrapped a path segment
# per line, so `src.web.panes` is three short rows rather than one long one,
# and sizing by the total would make every node a lozenge.
(def- label-slope 4.4)
(def- label-intercept 8.0)
# THE FLOOR, in inches. A short label still wants to look like the others
# rather than like a full stop -- and a node's label is up to four rows deep
# (the path a segment at a time, then the line count), so the narrow ones are
# the tall ones. Below this dot warns that the shape is too small for what is
# in it.
(def- min-width 0.86)
(def- points-per-inch 72)

# HOW TALL, in inches, for a label of N rows at fontsize 11. A row is about
# thirteen points with its leading -- tighter than the face's natural
# spacing, because a node's rows are one word each and read as a stack rather
# than as prose; the rest is the air above the first row and below the last. Fixed sizing means dot will not grow a node that does not fit, so
# this has to be right rather than close -- it warns when it is not, which is
# how the numbers here were checked.
(def- row-height 13.2)
(def- rows-padding 18.0)

(defn- label-height
  "How tall the ellipse for this label should be, in INCHES."
  [label]
  (def rows (length (string/split "\n" (string label))))
  (max 0.62 (/ (+ (* row-height rows) rows-padding) points-per-inch)))

(defn- label-width
  ``How wide the ellipse for this label should be, in INCHES -- the unit dot's
  `width` attribute takes.

  THE FIT IS FOR THE RADIUS, and `width` is the DIAMETER, so the points are
  doubled on the way to inches. Getting that wrong halves every node and the
  labels spill out of their outlines, which is what it looks like.``
  [label]
  (def lines (string/split "\n" (string label)))
  (def longest (max ;(map length lines)))
  (def radius (+ (* label-slope longest) label-intercept))
  (max min-width (/ (* 2 radius) points-per-inch)))

(defn- quoted
  "A DOT string literal: quotes and backslashes escaped, newlines as \\n."
  [text]
  (->> (string text)
       (string/replace-all "\\" "\\\\")
       (string/replace-all "\"" "\\\"")
       (string/replace-all "\n" "\\n")))

# A VALUE THAT IS ALREADY MARKUP, not a string to be quoted. dot reads
# `label=<...>` as an HTML-like label and `label="..."` as text, and the
# difference is the angle brackets rather than anything inside them -- so a
# value wrapped in this is printed as it stands.
(defn- raw [text] {:raw (string text)})

(defn- attrs
  "An attribute list from pairs, or the empty string when there are none."
  [pairs]
  (if (empty? pairs)
    ""
    (string " ["
            (string/join (map (fn [[k v]]
                                (if (and (dictionary? v) (v :raw))
                                  (string k "=<" (v :raw) ">")
                                  (string k "=\"" v "\"")))
                              pairs)
                         ", ")
            "]")))

(defn- escaped-html
  "Text safe inside an HTML-like label."
  [text]
  (->> (string text)
       (string/replace-all "&" "&amp;")
       (string/replace-all "<" "&lt;")
       (string/replace-all ">" "&gt;")))

# THE LINE COUNT IS SMALLER THAN THE NAME. It is a fact about the file rather
# than what the file is called, and at the same size the two read as one
# four-word phrase; smaller, the eye takes the name first and the number when
# it wants it.
#
# WHICH NEEDS AN HTML-LIKE LABEL, because a plain `\n` label carries one size
# for every row. That is the whole reason for the markup: the rows are the
# same rows, and the last one is printed a few points down.
(def- count-size 8)
# The blank row that separates the two. Small, because it is air rather than
# a line -- see `label-markup`.
(def- gap-size 4)

(defn- label-markup
  ``A node's label as HTML-like markup, so its last row can be smaller.

  Returns nil when the label has no count on it -- one row, or a name that is
  not a number -- and the caller prints the ordinary quoted label instead.``
  [label]
  (def rows (string/split "\n" (string label)))
  (when (and (> (length rows) 1)
             (peg/match ~(* (some (range "09")) -1) (last rows)))
    (def name (slice rows 0 -2))
    # A THIN ROW BETWEEN THE NAME AND THE COUNT. They are two different kinds
    # of thing -- what the file is called, and a fact about it -- and pressed
    # together they read as one more row of the name. An empty line break at a
    # few points is the whole gap: it costs that many points of height and
    # says the two are not the same thing.
    (string (string/join (map escaped-html name) "<BR/>")
            "<BR/><FONT POINT-SIZE=\"" gap-size "\"> </FONT>"
            "<BR/><FONT POINT-SIZE=\"" count-size "\">"
            (escaped-html (last rows)) "</FONT>")))

(defn to-dot
  ``The graph as a DOT document.

  Exported because it is worth reading on its own -- `vz dot` writes it to
  a file, and a DOT file is the one artefact both this program and every
  other graphviz tool understand.``
  [graph]
  (def out @[])
  (array/push out "digraph G {")
  (array/push out "  rankdir=TB;")
  # TRANSPARENT, so the PAGE decides the background. dot paints an opaque
  # white rectangle over the whole drawing by default, which lands as a
  # white slab on a canvas that is #fbfbfa in light mode and #171715 in
  # dark -- visible as a seam in the first, and as a glaring panel in the
  # second. With no background of its own the SVG floats on `--canvas` and
  # follows the theme for free.
  (array/push out (string "  graph [bgcolor=\"transparent\", fontname=\""
                          (quoted font) "\", fontsize=10];"))
  # FIXEDSIZE, so the width below is the width and not a floor. Without it
  # dot treats `width` as a minimum and grows any node whose label it
  # measures as wider -- which puts the font's metrics back in charge of the
  # layout, and those are exactly what a machine without the font gets wrong.
  # Measured: the same node came out 64.66pt with the font installed and
  # 51.56 without; fixed, it is 32.4 either way.
  #
  # THE HEIGHT IS FIXED TOO, because `fixedsize` takes both or neither. Three
  # short rows -- a path segment per line, plus the line count -- is what
  # every label is, so one height fits them all -- and the tallest is what it
  # has to fit: a prefixed name under a line count is four rows, sometimes
  # five. Too short and dot warns that the shape is too small for the label,
  # which is its way of saying the text will not fit inside the curve.
  #
  # Tall enough, too, that an ellipse sized for its widest line still reads
  # as a circle rather than a lens: at 0.62 the nodes came out wide and flat,
  # which is what a short fixed height does to a shape wider than it.
  (array/push out
              (string "  node [shape=ellipse, fontname=\"" (quoted font)
                      "\", fontsize=11, penwidth=1.2, fixedsize=true];"))
  (array/push out "  edge [arrowsize=0.7, color=\"#8a8a8a\"];")

  # A node's colour goes on the OUTLINE rather than inside the ellipse: a
  # wall of saturated boxes is harder to read the edges over, which is why
  # the fill was never the default and is now not an option.
  #
  # READ OFF THE NODE, exact colours and all. Which box claims a node, what
  # colour that makes it, and what ink reads against the page are questions
  # answered by select/resolve before any of this runs -- so this file has no
  # opinion about prefixes, does no contrast arithmetic, and prints the
  # strings it is handed.
  (defn node-line [node indent]
    (def name (node :name))
    (def ink (node :ink))
    (def fresh (node :fresh))
    (array/push out
                (string indent "\"" (quoted name) "\""
                        (attrs
                          [["label" (if-let [markup (label-markup (node :label))]
                                       (raw markup)
                                       (quoted (node :label)))]
                           # SIZED HERE RATHER THAN BY DOT, so the drawing is
                           # the same whether or not the machine running the
                           # server has the font. See `label-width`.
                           ["width" (string/format "%.3f" (label-width (node :label)))]
                           ["height" (string/format "%.3f" (label-height (node :label)))]
                           ["color" ink]
                           ["fontcolor" ink]
                           # The group's own hue, tinted well down: the flash
                           # is a node breathing in its own colour, not one
                           # lit up, and the page fades this in and out again.
                           ;(if fresh
                              [["style" "filled"]
                               ["fillcolor" (node :fill)]
                               ["class" "fresh"]]
                              [])])
                        ";")))

  # A BOX BECOMES A CLUSTER: a dashed rectangle around members that belong
  # together, labelled with the prefix. graphviz keeps a cluster's members
  # contiguous by construction, which is the guarantee the custom layout had
  # to work for.
  #
  # AND CLUSTERS NEST, because boxes do. A node carries every box it is
  # inside, widest first, so this walks that chain and writes a subgraph per
  # level -- `(box api)` around `(box api.v1)` around the nodes. graphviz
  # draws nested clusters natively; the work is emitting the nesting rather
  # than a flat partition that had to pick one box per node.
  #
  # THE COLOUR OF A CLUSTER is the box's own, carried on the chain. An outer
  # box may hold nothing but inner boxes, whose nodes wear the inner colour
  # -- so reading a hue off a member would paint the outer rectangle in the
  # wrong ink.
  (def hue-of @{})
  (each node (get graph :nodes [])
    (each box (get node :boxes [])
      (put hue-of (box :prefix) (box :colour))))

  # The tree of boxes, built from the chains. A box with no node directly in
  # it still appears, because a node deeper down named it on the way past.
  (def kids @{})
  (def top @{})
  (def held @{})
  (each node (get graph :nodes [])
    (def chain (map |($ :prefix) (get node :boxes [])))
    (if (empty? chain)
      (put held :loose (array/push (or (held :loose) @[]) node))
      (do
        (put held (last chain) (array/push (or (held (last chain)) @[]) node))
        (put top (first chain) true)
        (for i 0 (- (length chain) 1)
          (def parent (chain i))
          (def child (chain (+ i 1)))
          (def seen (or (kids parent) @{}))
          (put seen child true)
          (put kids parent seen)))))

  (defn emit-box [key depth]
    (def pad (string/repeat "  " (+ depth 1)))
    (def hue (hue-of key))
    (array/push out (string pad "subgraph \"cluster_" (quoted key) "\" {"))
    # THE SAME SIZE AS A NODE'S LABEL. A box names a group of files and a node
    # names a file; one is not a note about the other, and printing it smaller
    # said it was.
    (array/push out (string pad "  label=\"" (quoted key) "\"; style=dashed;"
                            " color=\"" hue "\";"
                            " fontcolor=\"" hue "\";"
                            " fontsize=11;"))
    # Children first, then this box's own nodes, so a nested rectangle is not
    # separated from its siblings by the loose members around it.
    (each child (sorted (keys (or (kids key) @{})))
      (emit-box child (+ depth 1)))
    (each node (or (held key) [])
      (node-line node (string pad "  ")))
    (array/push out (string pad "}")))

  (each key (sorted (keys top)) (emit-box key 0))

  (each node (or (held :loose) [])
    (node-line node "  "))

  (each [from to] (get graph :edges [])
    (array/push out (string "  \"" (quoted from) "\" -> \"" (quoted to) "\";")))

  (array/push out "}")
  (string/join out "\n"))

(defn- trimmed-svg
  ``graphviz's output, ready to inline into the page.

  dot writes a standalone document -- XML prolog, DOCTYPE, a comment naming
  its version -- and the page drops the SVG straight into HTML, where a
  prolog partway down the body is invalid and a DOCTYPE is worse. Everything
  before the opening <svg is dropped.

  The `-&#45;&gt;` in edge titles becomes `-&gt;`: dot escapes the hyphen
  because a `--` inside an XML comment is illegal, and web/app.js matches
  edge titles as "from->to" when it highlights an edge's endpoints.``
  [text]
  (def at (string/find "<svg" text))
  (def body (if at (string/slice text at) text))
  (string/replace-all "&#45;&gt;" "-&gt;" body))

(defn draw
  ``Draw `graph` with graphviz. Returns [ok svg-or-error], the shape every
  caller already handles.

  STRAIGHT TO DOT. The graph used to make a round trip through `v` on the
  way here -- rendered to text, parsed back, drawn from what came out --
  so that a disagreement between the writer and the reader showed up as a
  picture. That was worth its weight when the layout was ours and the text
  format was how a graph was described; with graphviz drawing and the
  format gone, it was four hundred lines of detour between a table and a
  DOT document.``
  [graph]
  (def dot (to-dot graph))
  (try
    (let [proc (os/spawn ["dot" "-Tsvg"] :px {:in :pipe :out :pipe})]
      (:write (proc :in) dot)
      (:close (proc :in))
      (def svg (:read (proc :out) :all))
      (def status (os/proc-wait proc))
      (if (zero? status)
        [true (trimmed-svg (string svg))]
        [false "graphviz failed to draw this graph"]))
    ([err]
      [false (string "graphviz is required to draw the graph, and running "
                     "`dot` failed: " err
                     ". Install it with `brew install graphviz`.")])))
