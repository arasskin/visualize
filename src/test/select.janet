# Prefix matching and the filtering the config can apply to a graph.
#
# Was test/dot.janet. The tests for generating DOT text and for running the
# graphviz subprocess went with the code they covered; what is left is the
# config language's actual behaviour, which never depended on either.

(import ../visualize/select)
(import ../visualize/color)
(import ./harness :as t)

# A small graph with the shape that matters: our own files in two directories,
# plus an external, plus an edge between each pair.
(defn- sample []
  {:nodes [{:name "Otto_App" :label "Otto/\nApp" :ours true}
           {:name "Otto_View" :label "Otto/\nView" :ours true}
           {:name "OttoClip_Cart" :label "OttoClip/\nCart" :ours true}
           {:name "SwiftUI" :label "SwiftUI" :ours false}]
   :edges [["Otto_View" "Otto_App"]
           ["SwiftUI" "Otto_View"]
           ["OttoClip_Cart" "Otto_App"]]
   :sizes {"Otto_App" 120 "Otto_View" 1300 "OttoClip_Cart" 40}
   :ours {"Otto_App" true "Otto_View" true "OttoClip_Cart" true}})

(t/test "~ expands to the project, other names are literal"
  (t/is= "" (select/expand "~") "~ alone is the empty prefix -- everything of ours")
  (t/is= "Otto" (select/expand "~.Otto"))
  (t/is= "Otto_Shared" (select/expand "~.Otto.Shared"))
  (t/is= "SwiftUI" (select/expand "SwiftUI") "a plain name means the external"))

(t/test "a config name may be written the way the label reads"
  # A node LABELS itself with the path -- `src/test` -- while its identity is
  # the flattened `src_test`, and the config used to accept only the dotted
  # `src.test`, which came from pydeps where a module path really is dotted.
  # Someone typing what the picture shows deserves a match rather than
  # silence, so both separators arrive at the same prefix.
  (t/is= "src_test" (select/expand "src/test") "slashes, as the label shows them")
  (t/is= "src_test" (select/expand "src.test") "dots, as pydeps wrote them")
  (t/is= "src_test" (select/expand "src_test") "or the flat name itself")
  (t/is= "src_test" (select/expand "~.src/test") "and the same under ~.")
  (t/is= "" (select/expand "~") "~ alone is still everything of ours"))

(t/test "the empty prefix means OURS, not everything"
  # Without this, (show-only ~) would keep the externals too and mean nothing.
  (def ours {"Otto_App" true})
  (t/ok (select/matches? "Otto_App" "" ours))
  (t/ok (not (select/matches? "SwiftUI" "" ours))))

(t/test "show-only narrows to a prefix and keeps only interior edges"
  (def got (select/keep (sample) ["~"]))
  (t/is= ["OttoClip_Cart" "Otto_App" "Otto_View"]
         (sorted (map |($ :name) (got :nodes)))
         "the external is gone")
  # The SwiftUI edge must go with it: an edge to a node that is not drawn
  # would rank against something that is not on the page.
  (t/is= [["OttoClip_Cart" "Otto_App"] ["Otto_View" "Otto_App"]]
         (sorted (got :edges))))

(t/test "nothing declared means no filter at all"
  (t/is= 4 (length ((select/keep (sample) []) :nodes))))

(t/test "hide removes nodes and every edge touching them"
  (def got (select/drop-nodes (sample) ["~.OttoClip"]))
  (t/ok (not (index-of "OttoClip_Cart" (map |($ :name) (got :nodes)))))
  (t/is= 2 (length (got :edges))))

(t/test "a trailing dot hides the contents, not the thing itself"
  # (hide ~.Otto.) hides Otto/'s files while leaving OttoClip's alone --
  # which the plain prefix `Otto` cannot express, since it matches both.
  (def both (select/drop-nodes (sample) ["~.Otto"]))
  (t/is= ["SwiftUI"] (map |($ :name) (both :nodes))
         "the plain prefix takes OttoClip with it, because a prefix is a prefix")
  (def just-otto (select/drop-nodes (sample) ["~.Otto."]))
  (t/is= ["OttoClip_Cart" "SwiftUI"] (sorted (map |($ :name) (just-otto :nodes)))
         "the trailing dot leaves OttoClip alone"))

(t/test "an orphaned node stays on the graph"
  # Hiding the only thing that referenced it takes the edges, not the node.
  # "This is here and nothing you are looking at uses it" is a fact about the
  # picture you asked for, not a defect in it.
  (def got (select/drop-nodes (sample) ["~.Otto."]))
  (t/ok (index-of "SwiftUI" (map |($ :name) (got :nodes)))))

(t/test "degrees counts both directions"
  (def counts (select/degrees (sample)))
  (t/is= 2 (counts "Otto_View") "one in, one out")
  (t/is= 2 (counts "Otto_App"))
  (t/is= 1 (counts "SwiftUI")))

(t/test "line counts are written out in full"
  (t/is= "240" (select/thousands 240))
  (t/is= "1000" (select/thousands 1000) "no k abbreviation")
  (t/is= "1300" (select/thousands 1300) "and no rounding to a tenth")
  (t/is= "999" (select/thousands 999)))
