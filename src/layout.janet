# Which layout draws the graph.
#
# THE SEAM. A layout is a function from a graph to a picture, and this is
# the table of the ones that exist. `(layout force)` in the config picks
# one; nothing else in the tree knows which is in use, which is what makes
# adding another one a file and a line here rather than a change to the
# renderer, the routes or the page.
#
# LAYERED IS THE DEFAULT, and it is ours: nodes sit on ranks so every arrow
# points the same way down the page, which is what a dependency graph is
# for. It replaced graphviz, and with it went the last thing this tool
# needed installed -- see src/layout/layered.janet for the algorithm and
# src/v.janet for the language the graph is written in on the way here.
#
# EVERY LAYOUT GOES THROUGH V. `draw` renders the graph to v text and parses
# it back before laying anything out. That looks like a detour and is not:
# it means the language is on the ONLY path to a picture, so it cannot rot
# the way a debug-only serialisation does, and it means `vz graph` showing
# you v text is showing you exactly what the renderer saw.
#
# WHAT COMES BACK IS THE SAME TABLE it always was -- {:nodes :edges :sizes
# :ours :groups} -- even though the text behind it is now triples rather than
# nested forms. That was the point of keeping the shape: nothing below this
# line knows the language changed.

(import ./v)
(import ./select)
(import ./layout/force)
(import ./layout/layered)
(import ./layout/svg)

(defn- with-layered [graph opts]
  (def groups (or (opts :groups) []))
  (def ours (or (graph :ours) {}))
  (def places
    (layered/place
      graph
      {:measure (fn [name]
                  (svg/width-of (or (get (get opts :labels {}) name) name)))
       # The renderer draws a group's box outside its members, so the layout
       # has to keep strangers out of THAT rectangle rather than out of the
       # members' extent -- see svg/group-inset. This is the seam: `layered`
       # knows nothing about SVG and `svg` decides nothing about placement,
       # so the number crosses here rather than being written down twice.
       :group-inset svg/group-inset
       # Which group claims a node, so the layout can keep a group's members
       # side by side -- see `cohere`. Nil when nothing is grouped, which
       # skips the pass entirely.
       :group-of (when (not (empty? groups))
                   (fn [name]
                     (when-let [g (select/group-for name groups ours)]
                       (g :prefix))))}))
  [true (svg/draw graph (places :points)
                  (merge (table ;(kvs opts))
                         {:routes (places :routes)
                          # A layered layout keeps a group's members near each
                          # other, so a box around them means something.
                          :boxes true}))])

(defn- with-force [graph opts]
  # Layout parameters ride in the same opts table the renderer reads, so a
  # config line can reach them without a second channel.
  [true (svg/draw graph (force/place graph (get opts :tuning {}))
                  (merge (table ;(kvs opts))
                         # No boxes: a force layout has no reason to keep a
                         # group contiguous, and a box drawn around scattered
                         # members would claim a structure the picture does
                         # not have.
                         {:boxes false}))])

(def layouts
  "Every layout, by the name a config uses."
  {"layered" with-layered
   "force" with-force})

(defn draw
  ``Draw `graph` with the layout named in `opts`, defaulting to layered.
  Returns [ok svg-or-error], the same shape every caller already handles.

  The graph makes the round trip through v on the way: `render` writes it,
  `parse` reads it back, and the layout sees what came out. See the note at
  the top of this file for why that is not a detour.``
  [graph &opt opts]
  (default opts {})
  (def wanted (string (or (opts :layout) "layered")))
  (if-let [chosen (layouts wanted)]
    (let [text (v/render graph opts)
          [ok parsed] (v/parse text)]
      (if-not ok
        [false parsed]
        # The parsed graph carries nodes, edges, sizes and ours; the groups
        # come from the config, which knows the colours it assigned.
        (chosen parsed (merge (table ;(kvs opts))
                              {:labels (let [out @{}]
                                         (each node (parsed :nodes)
                                           (put out (node :name) (node :label)))
                                         out)}))))
    [false (string "unknown layout '" wanted "' -- try one of "
                   (string/join (sorted (keys layouts)) ", "))]))
