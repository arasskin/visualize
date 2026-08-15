# Which layout draws the graph.
#
# THE SEAM. A layout is a function from a graph to a picture, and this is
# the table of the ones that exist. `(layout force)` in the config picks
# one; nothing else in the tree knows which is in use, which is what makes
# adding another one -- the hierarchical layout meant to replace graphviz --
# a file and a line here rather than a change to the renderer, the routes
# or the page.
#
# GRAPHVIZ IS STILL THE DEFAULT, and honestly so: its layered layout is
# decades of tuning and a dependency graph is exactly what it is for. What
# the alternatives buy is that the tool draws SOMETHING with nothing
# installed, and that the choice is now visible rather than assumed.

(import ./dot)
(import ./layout/force)
(import ./layout/svg)

(defn- with-graphviz [graph opts]
  (dot/to-svg (dot/render graph opts) (opts :cwd)))

(defn- with-force [graph opts]
  # Layout parameters ride in the same opts table the renderer reads, so a
  # config line can reach them without a second channel.
  [true (svg/draw graph (force/place graph (get opts :tuning {})) opts)])

(def layouts
  "Every layout, by the name a config uses."
  {"graphviz" with-graphviz
   "force" with-force})

(defn draw
  ``Draw `graph` with the layout named in `opts`, falling back to graphviz.
  Returns [ok svg-or-error], the same shape every caller already handles.``
  [graph &opt opts]
  (default opts {})
  (def wanted (string (or (opts :layout) "graphviz")))
  (if-let [chosen (layouts wanted)]
    (chosen graph opts)
    [false (string "unknown layout '" wanted "' -- try one of "
                   (string/join (sorted (keys layouts)) ", "))]))
