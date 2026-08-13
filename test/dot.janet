# Prefix matching, filtering, and the DOT that comes out the far side.

(import ../src/dot)
(import ../src/color)
(import ./harness :as t)

# A small graph with the shape that matters: our own files in two directories,
# plus an external, plus an edge between each pair.
(defn- sample []
  {:nodes [{:name "Otto_App" :label "Otto/\\nApp" :ours true}
           {:name "Otto_View" :label "Otto/\\nView" :ours true}
           {:name "OttoClip_Cart" :label "OttoClip/\\nCart" :ours true}
           {:name "SwiftUI" :label "SwiftUI" :ours false}]
   :edges [["Otto_View" "Otto_App"]
           ["SwiftUI" "Otto_View"]
           ["OttoClip_Cart" "Otto_App"]]
   :sizes {"Otto_App" 120 "Otto_View" 1300 "OttoClip_Cart" 40}
   :ours {"Otto_App" true "Otto_View" true "OttoClip_Cart" true}})

(t/test "~ expands to the project, other names are literal"
  (t/is= "" (dot/expand "~") "~ alone is the empty prefix -- everything of ours")
  (t/is= "Otto" (dot/expand "~.Otto"))
  (t/is= "Otto_Shared" (dot/expand "~.Otto.Shared"))
  (t/is= "SwiftUI" (dot/expand "SwiftUI") "a plain name means the external"))

(t/test "the empty prefix means OURS, not everything"
  # Without this, (show-only ~) would keep the externals too and mean nothing.
  (def ours {"Otto_App" true})
  (t/ok (dot/matches? "Otto_App" "" ours))
  (t/ok (not (dot/matches? "SwiftUI" "" ours))))

(t/test "show-only narrows to a prefix and keeps only interior edges"
  (def got (dot/keep (sample) ["~"]))
  (t/is= ["OttoClip_Cart" "Otto_App" "Otto_View"]
         (sorted (map |($ :name) (got :nodes)))
         "the external is gone")
  # The SwiftUI edge must go with it: an edge to a node that is not drawn
  # leaves graphviz inventing a blank box for it.
  (t/is= [["OttoClip_Cart" "Otto_App"] ["Otto_View" "Otto_App"]]
         (sorted (got :edges))))

(t/test "nothing declared means no filter at all"
  (t/is= 4 (length ((dot/keep (sample) []) :nodes))))

(t/test "hide removes nodes and every edge touching them"
  (def got (dot/drop-nodes (sample) ["~.OttoClip"]))
  (t/ok (not (index-of "OttoClip_Cart" (map |($ :name) (got :nodes)))))
  (t/is= 2 (length (got :edges))))

(t/test "a trailing dot hides the contents, not the thing itself"
  # (hide ~.Otto.) hides Otto/'s files while leaving OttoClip's alone --
  # which the plain prefix `Otto` cannot express, since it matches both.
  (def both (dot/drop-nodes (sample) ["~.Otto"]))
  (t/is= ["SwiftUI"] (map |($ :name) (both :nodes))
         "the plain prefix takes OttoClip with it, because a prefix is a prefix")
  (def just-otto (dot/drop-nodes (sample) ["~.Otto."]))
  (t/is= ["OttoClip_Cart" "SwiftUI"] (sorted (map |($ :name) (just-otto :nodes)))
         "the trailing dot leaves OttoClip alone"))

(t/test "an orphaned node stays on the graph"
  # Hiding the only thing that referenced it takes the edges, not the node.
  # "This is here and nothing you are looking at uses it" is a fact about the
  # picture you asked for, not a defect in it.
  (def got (dot/drop-nodes (sample) ["~.Otto."]))
  (t/ok (index-of "SwiftUI" (map |($ :name) (got :nodes)))))

(t/test "degrees counts both directions"
  (def counts (dot/degrees (sample)))
  (t/is= 2 (counts "Otto_View") "one in, one out")
  (t/is= 2 (counts "Otto_App"))
  (t/is= 1 (counts "SwiftUI")))

(t/test "line counts shorten the way the Python tool wrote them"
  (t/is= "240" (dot/thousands 240))
  (t/is= "1k" (dot/thousands 1000) "a bare 1k, not 1.0k")
  (t/is= "1.3k" (dot/thousands 1300))
  (t/is= "999" (dot/thousands 999)))

(t/test "rendering produces DOT with the nodes, edges and a font"
  (def text (dot/render (sample)))
  (t/ok (string/find "digraph G {" text))
  (t/ok (string/find "Otto_View -> Otto_App;" text))
  (t/ok (string/find "Comic Sans MS" text))
  (t/ok (string/find "shape=box" text)))

(t/test "unfilled is the default and fills nothing"
  # A wall of saturated boxes is harder to read the EDGES over, and the edges
  # are what a dependency graph is for.
  (def text (dot/render (sample)))
  (t/ok (string/find "fillcolor=\"none\"" text))
  (t/ok (not (string/find "style=filled,fillcolor=\"#" text))))

(t/test "fill-color fills every node with its group's hue"
  (def text (dot/render (sample) {:filled true}))
  (t/ok (string/find "style=filled,fillcolor=\"#" text)))

(t/test "a group becomes a cluster carrying its colour"
  (def text (dot/render (sample) {:groups [{:prefix "~.Otto" :color "#ff4d6d"}]}))
  (t/ok (string/find "subgraph cluster_Otto {" text))
  (t/ok (string/find "label=\"~.Otto\"" text))
  (t/ok (string/find "#ff4d6d" text)))

(t/test "the first matching group wins when two overlap"
  # A narrow group declared before a broad one keeps its own box rather than
  # being swallowed by the broad one.
  (def text (dot/render (sample)
                        {:groups [{:prefix "~.OttoClip" :color "#3bceac"}
                                  {:prefix "~.Otto" :color "#ff4d6d"}]}))
  (t/ok (string/find "cluster_OttoClip" text))
  (t/ok (string/find "cluster_Otto " text)))

(t/test "show-lines writes the count onto the label"
  (def text (dot/render (sample) {:sized true}))
  (t/ok (string/find `Otto/\nView\n1.3k` text))
  (t/ok (not (string/find "SwiftUI\\n" text))
        "an external has no file behind it and is left alone"))

(t/test "labels with quotes cannot break out of the DOT string"
  (def odd {:nodes [{:name "N" :label `He said "hi"` :ours true}]
            :edges [] :sizes {} :ours {"N" true}})
  (t/ok (string/find `\"hi\"` (dot/render odd))))
