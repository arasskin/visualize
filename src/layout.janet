# The graph, drawn by graphviz.
#
# WHAT THIS IS. `graph.janet` hands over a parsed graph and the config's
# decisions -- groups, colours, font, whether nodes are filled -- and gets
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

(import ./color)
(import ./select)
(import ./v)

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
  [graph opts]
  (def groups (or (opts :groups) []))
  (def ours (or (graph :ours) {}))
  (def weights (or (opts :weights) {}))
  (def filled (opts :filled))
  (def font (or (opts :font) "Comic Sans MS"))
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

  # A node's colour is the group's hue tinted by its weight, which is what
  # the custom renderer did and what the config's ramp expects. `filled`
  # decides whether that colour goes inside the ellipse or only on its line.
  (defn node-line [node indent]
    (def name (node :name))
    (def claimed (select/group-for name groups ours))
    (def hue (if claimed (claimed :color) color/ungrouped))
    (def weight (get weights name 0))
    (def fill (color/tint hue weight))
    (array/push out
                (string indent "\"" (quoted name) "\""
                        (attrs [["label" (quoted (node :label))]
                                ["fillcolor" (if filled fill "none")]
                                ["style" (if filled "filled" "solid")]
                                ["color" (color/ink-on-page hue)]
                                ["fontcolor" (if filled
                                               (color/ink fill)
                                               (color/ink-on-page hue))]])
                        ";")))

  # GROUPS BECOME CLUSTERS, which is what a group has always meant here: a
  # dashed box around members that belong together, labelled with the
  # prefix. graphviz keeps a cluster's members contiguous by construction,
  # which is the guarantee the custom layout had to work for.
  (def in-group @{})
  (each node (get graph :nodes [])
    (when-let [claimed (select/group-for (node :name) groups ours)]
      (put in-group (node :name) (claimed :prefix))))
  (def by-group @{})
  (each node (get graph :nodes [])
    (when-let [key (in-group (node :name))]
      (put by-group key (array/push (or (by-group key) @[]) node))))

  (eachp [key members] by-group
    (def claimed (select/group-for ((first members) :name) groups ours))
    (array/push out (string "  subgraph \"cluster_" (quoted key) "\" {"))
    (array/push out (string "    label=\"" (quoted key) "\"; style=dashed;"
                            " color=\"" (if claimed (claimed :color) color/ungrouped) "\";"
                            " fontcolor=\"" (if claimed (claimed :color) color/ungrouped) "\";"
                            " fontsize=10;"))
    (each node members (node-line node "    "))
    (array/push out "  }"))

  (each node (get graph :nodes [])
    (unless (in-group (node :name))
      (node-line node "  ")))

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

  The graph makes the round trip through v on the way: `render` writes it,
  `parse` reads it back, and the DOT is written from what came out -- so
  what is drawn is what the text says, and a bug in either direction shows
  up as a picture rather than as a silent disagreement.``
  [graph &opt opts]
  (default opts {})
  (def text (v/render graph opts))
  (def [ok parsed] (v/parse text))
  (if-not ok
    [false parsed]
    (let [dot (to-dot parsed opts)]
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
                         ". Install it with `brew install graphviz`.")])))))
