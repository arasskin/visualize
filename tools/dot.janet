# The graph as a DOT file, for rendering with graphviz.
#
#     ./bin/janet tools/dot.janet > graph.dot
#     ./bin/janet tools/dot.janet | dot -Tpng -o graphviz.png
#
# THE COMPARISON THIS EXISTS FOR. This tool's layout replaced graphviz, and
# every argument about whether that was wise deserves a picture on each
# side. The export mirrors what the page draws -- same scan, same config,
# same trimming, same groups, line counts in the labels when (show-lines)
# is on -- so the only variable left is the layout algorithm. `vz dot`
# wraps this and runs graphviz on the result.
#
# The audit (docs/dotgen-audit.md) records what the comparison has shown
# each time it was made: dot packs tighter and spends width and scenic
# detours to do it; this layout keeps a vertical funnel and a shelf. Run
# it again whenever that conclusion deserves re-testing -- the graph it
# was last true of is not the graph you have now.
(import ../src/scan) (import ../src/parsers) (import ../src/config)
(import ../src/select)

(def specs (parsers/load "./src/parsers"))
(def graph (scan/scan "." specs))
(def [state _] (config/run (string/split "\n" (string/trimr (slurp "config.janet")))))
(def trimmed (select/drop-nodes (select/keep graph (state :only)) (state :hidden)))
(def ours (or (trimmed :ours) {}))
(def groups (state :groups))

(defn- label [n]
  (def lines (string/replace-all "\n" "\\n" (n :label)))
  (if-let [size (and (state :sized) (get (graph :sizes) (n :name)))]
    (string lines "\\n" size)
    lines))

(def in-group @{})
(each n (trimmed :nodes)
  (when-let [g (select/group-for (n :name) groups ours)]
    (put in-group (n :name) (g :prefix))))
(def by-group @{})
(eachp [name g] in-group
  (put by-group g (array/push (or (by-group g) @[]) name)))

(print "digraph G {")
(print "  rankdir=TB;")
(print "  node [shape=ellipse, fontname=\"Comic Sans MS\", fontsize=11];")
(print "  edge [arrowsize=0.7];")
(eachp [g members] by-group
  (print "  subgraph \"cluster_" g "\" {")
  (print "    label=\"" g "\"; style=dashed; color=\"#ff4d6d\";")
  (each m members
    (def node (find |(= ($ :name) m) (trimmed :nodes)))
    (print "    \"" m "\" [label=\"" (label node) "\"];"))
  (print "  }"))
(each n (trimmed :nodes)
  (unless (in-group (n :name))
    (print "  \"" (n :name) "\" [label=\"" (label n) "\"];")))
(each [from to] (trimmed :edges)
  (print "  \"" from "\" -> \"" to "\";"))
(print "}")
