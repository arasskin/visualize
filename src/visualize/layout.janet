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
# NAMED HERE, MEASURED BY DOT, DRAWN BY THE BROWSER -- and those are three
# different lookups of the same name.
#
# The browser's is answered by the @font-face in style.css, which points at
# the TTFs vendored beside it, so the page always draws in the real face.
#
# DOT'S IS ANSWERED BY THE SYSTEM, and only by the system. It sizes every
# ellipse from the metrics it finds, and it looks where fontconfig looks --
# not at the repo, and not at FONTCONFIG_FILE either, both measured. Without
# the font installed it measures a fallback: 111pt for a label the real face
# needs 137pt for, which is labels crowding outlines cut for other glyphs.
#
# So the fonts ship in src/web/ AND want installing on the machine that runs
# the server. The first is what makes the page look right anywhere; the
# second is what makes the ellipses fit. A machine without them gets a
# correctly drawn graph in slightly tight ellipses, which is a bad haircut
# rather than a broken page.
(def- font "Parkinsans")

(defn- quoted
  "A DOT string literal: quotes and backslashes escaped, newlines as \\n."
  [text]
  (->> (string text)
       (string/replace-all "\\" "\\\\")
       (string/replace-all "\"" "\\\"")
       (string/replace-all "\n" "\\n")))

(defn- attrs
  "An attribute list from pairs, or the empty string when there are none."
  [pairs]
  (if (empty? pairs)
    ""
    (string " [" (string/join (map (fn [[k v]] (string k "=\"" v "\"")) pairs) ", ") "]")))

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
  (array/push out
              (string "  node [shape=ellipse, fontname=\"" (quoted font)
                      "\", fontsize=11, penwidth=1.2];"))
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
                          [["label" (quoted (node :label))]
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
    (array/push out (string pad "  label=\"" (quoted key) "\"; style=dashed;"
                            " color=\"" hue "\";"
                            " fontcolor=\"" hue "\";"
                            " fontsize=10;"))
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
