# The graph as a DOT file.
#
#     ./bin/janet tools/dot.janet > graph.dot
#     ./bin/janet tools/dot.janet | dot -Tpng -o graph.png
#
# THE SAME DOT THE PAGE DRAWS FROM. `src/layout.janet` writes this document
# and pipes it to `dot -Tsvg`; this prints it instead, so the exact input
# graphviz receives can be read, diffed, or fed to another engine (`neato`,
# `fdp`, `sfdp`) without touching the program.
#
# It was once the other half of a comparison -- this program had its own
# layout, and `vz dot` existed to put the two pictures side by side. The
# custom layout is gone and graphviz draws everything now, so what remains
# is the ability to see the DOT.
(import ../src/graph)
(import ../src/parsers)
(import ../src/scan)
(import ../src/config)
(import ../src/select)
(import ../src/layout)
(import ../src/v)

(def specs (parsers/load "./src/parsers"))
(def graph (scan/scan "." specs))
(def [state _] (config/run (string/split "\n" (string/trimr (slurp "config.janet")))))
(def trimmed (select/drop-nodes (select/keep graph (state :only)) (state :hidden)))

# The label carries the line count when (show-lines) asked for it, and the
# weights decide the shading -- both are graph.janet's work on the way to a
# render, repeated here so the DOT matches what the page draws.
(def weights
  (if (state :sized-coloring)
    (let [here @{}]
      (each node (trimmed :nodes)
        (when-let [size (get (graph :sizes) (node :name))]
          (put here (node :name) size)))
      (select/ramp-of here))
    (select/weights-for trimmed)))

(def labelled
  (if (state :sized)
    (merge trimmed
           {:nodes (map (fn [node]
                          (if-let [size (get (graph :sizes) (node :name))]
                            (merge node {:label (string (node :label) "\n"
                                                        (select/thousands size))})
                            node))
                        (trimmed :nodes))})
    trimmed))

(def opts {:groups (state :groups)
           :sized (state :sized)
           :filled (state :filled)
           :font (state :font)
           :weights weights})

# Through v and back, exactly as `layout/draw` does it: the DOT is written
# from what the text says, not from the scan directly.
(def [ok parsed] (v/parse (v/render labelled opts)))
(if ok
  (print (layout/to-dot parsed opts))
  (do (eprint "could not render the graph: " parsed) (os/exit 1)))
