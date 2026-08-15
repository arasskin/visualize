# The v language: what it parses, what it writes, and that the two agree.
#
# TWO LEVELS, because the language has two. `triples` turns text into rows,
# and `parse` builds a graph out of rows -- so the tests that matter most are
# the ones on the rows, since that is the model and the graph is a consumer.

(import ../src/v)
(import ./harness :as t)

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

#
# The triples: the language itself.
#

(t/test "a form desugars to one row per attribute"
  (def [ok rows] (v/triples `(node A :label "A" :ours :size 12)`))
  (t/ok ok "it parsed")
  (t/is= [["A" :node true]
          ["A" :label "A"]
          ["A" :ours true]
          ["A" :size 12]]
         (map |[($ 0) ($ 1) ($ 2)] rows)
         "the entity repeats and each attribute is its own fact"))

(t/test "an edge is the row whose value is another entity"
  (def [_ rows] (v/triples "(edge A B)"))
  (t/is= [["A" :edge-to "B"]] (map |[($ 0) ($ 1) ($ 2)] rows)))

(t/test "a bare node is still a fact"
  # Otherwise `(node Solo)` would parse to nothing at all and a node with
  # nothing to say about it would vanish.
  (def [_ rows] (v/triples "(node Solo)"))
  (t/is= [["Solo" :node true]] (map |[($ 0) ($ 1) ($ 2)] rows)))

(t/test "a group declares itself and carries its colour"
  (def [_ rows] (v/triples `(group ~.Otto :color "#ff4d6d")`))
  (t/is= [["~.Otto" :group-decl true]
          ["~.Otto" :color "#ff4d6d"]]
         (map |[($ 0) ($ 1) ($ 2)] rows)))

(t/test "membership is an attribute on the member"
  # THE WHOLE REASON FOR TRIPLES. Under nesting this fact lived in the node's
  # POSITION, which meant a group could only ever own a contiguous run.
  (def [_ rows] (v/triples "(node A :group ~.Otto)"))
  (t/ok (find |(= $ ["A" :group "~.Otto"]) (map |[($ 0) ($ 1) ($ 2)] rows))))

(t/test "a node can belong to two groups"
  # Unsayable under nesting: a node sat inside exactly one set of parens.
  (def [_ rows] (v/triples "(node A :group One) (node A :group Two)"))
  (def memberships (filter |(= (get $ 1) :group) rows))
  (t/is= 2 (length memberships) "both facts survive as rows"))

#
# The graph built from them.
#

(t/test "a hand-written graph parses"
  (def [ok graph] (v/parse `
    (node A :label "A" :ours :size 12)
    (node B :label "B")
    (edge A B)`))
  (t/ok ok "it parsed")
  (t/is= ["A" "B"] (map |($ :name) (graph :nodes)))
  (t/is= [["A" "B"]] (graph :edges))
  (t/is= 12 ((graph :sizes) "A"))
  (t/ok ((graph :ours) "A"))
  (t/ok (not ((graph :ours) "B")) ":ours is a flag, and B does not carry it"))

(t/test "a node with no label uses its own name"
  (def [_ graph] (v/parse "(node Solo)"))
  (t/is= "Solo" ((first (graph :nodes)) :label)))

(t/test "comments and whitespace are skipped"
  (def [ok graph] (v/parse `
    ; the whole graph
    (node A :label "A")   ; trailing
    (edge A A)`))
  (t/ok ok)
  (t/is= 1 (length (graph :nodes))))

(t/test "a bare word takes characters DOT would have rejected"
  # The reason `safe-name` existed: graphviz rejected a hyphen in a bare
  # identifier. v has no such rule, so this parses as one token.
  (def [ok graph] (v/parse `(node demo-api.worker :label "demo-api")`))
  (t/ok ok)
  (t/is= "demo-api.worker" ((first (graph :nodes)) :name)))

(t/test "a group's members are found by attribute, not by position"
  (def [ok graph] (v/parse `
    (group ~.Otto :color "#ff4d6d")
    (node Loose :label "Loose")
    (node Otto_App :label "Otto/App" :group ~.Otto)
    (node Otto_View :label "Otto/View" :group ~.Otto)`))
  (t/ok ok)
  (t/is= ["Loose" "Otto_App" "Otto_View"] (map |($ :name) (graph :nodes)))
  (t/is= [{:prefix "~.Otto" :color "#ff4d6d"}] (graph :groups))
  (t/is= @{"Otto_App" "~.Otto" "Otto_View" "~.Otto"} (graph :claimed)
         "and membership came off the members"))

(t/test "a group's members need not be adjacent"
  # The case the nested language could not express and svg/draw had to work
  # around by drawing one box per layer.
  (def [_ graph] (v/parse `
    (node A :group G)
    (node B)
    (node C :group G)`))
  (t/is= @{"A" "G" "C" "G"} (graph :claimed)))

(t/test "a group used but never declared still exists"
  (def [_ graph] (v/parse "(node A :group G)"))
  (t/is= ["G"] (map |($ :prefix) (graph :groups))
         "the row that names it is enough to create it"))

(t/test "a string label decodes its escapes"
  # DOT carried the two characters `\` and `n` and let graphviz split them;
  # here the label reaches the renderer with a real newline in it.
  (def [_ graph] (v/parse `(node A :label "Otto/\nApp")`))
  (t/is= "Otto/\nApp" ((first (graph :nodes)) :label))
  (t/is= 2 (length (string/split "\n" ((first (graph :nodes)) :label)))))

(t/test "a quote in a label cannot break out of the string"
  (def text (v/render {:nodes [{:name "N" :label `He said "hi"` :ours true}]
                       :edges [] :sizes {} :ours {"N" true}}))
  (def [ok graph] (v/parse text))
  (t/ok ok "the rendered text still parses")
  (t/is= `He said "hi"` ((first (graph :nodes)) :label) "and the label survives"))

#
# Writing.
#

(t/test "rendering writes a form per entity"
  (def text (v/render (sample)))
  (t/ok (string/find `(node Otto_App :label "Otto/\nApp" :ours :size 120)` text))
  (t/ok (string/find "(edge Otto_View Otto_App)" text))
  (t/ok (not (string/find "(graph" text)) "and there is no wrapper to nest under"))

(t/test "a group is declared once and named on each member"
  (def text (v/render (sample) {:groups [{:prefix "Otto_" :color "#ff4d6d"}]}))
  (t/ok (string/find `(group Otto_ :color "#ff4d6d")` text) "declared once")
  (t/ok (string/find ":group Otto_)" text) "and claimed by a member")
  (t/ok (string/find "OttoClip_Cart" text) "and the unclaimed node is still there"))

(t/test "render and parse are inverses"
  # THE POINT OF HAVING A LANGUAGE rather than a serialiser: the text is an
  # interchange format, not a write-only string on its way to a subprocess.
  (def original (sample))
  (def [ok back] (v/parse (v/render original)))
  (t/ok ok)
  (t/is= (map |[($ :name) ($ :label) ($ :ours)] (original :nodes))
         (map |[($ :name) ($ :label) ($ :ours)] (back :nodes)))
  (t/is= (original :edges) (back :edges))
  (t/is= (original :sizes) (back :sizes))
  (t/is= (original :ours) (back :ours)))

(t/test "group membership survives the round trip"
  # It did NOT under nesting: `parse` flattened members into one node list
  # and the groups came back only because `render` read them from opts.
  (def groups [{:prefix "Otto_" :color "#ff4d6d"}])
  (def [_ back] (v/parse (v/render (sample) {:groups groups})))
  # `OttoClip_Cart` is deliberately absent: it does not carry the `Otto_`
  # prefix, so `select/group-for` never claimed it and no `:group` was
  # written on it.
  (t/is= @{"Otto_App" "Otto_" "Otto_View" "Otto_"} (back :claimed))
  (t/is= [{:prefix "Otto_" :color "#ff4d6d"}] (back :groups)
         "and the colour came back with it"))

(t/test "a second round trip changes nothing"
  # If the first pass were lossy, the second would differ from it.
  (def once (v/render (sample)))
  (def [_ back] (v/parse once))
  (t/is= once (v/render back)))

#
# What it tolerates.
#

(t/test "an edge may reference a node declared later"
  # A row naming an unknown entity simply creates it, so order never matters.
  (def [ok graph] (v/parse `(edge A B) (node A :label "A") (node B :label "B")`))
  (t/ok ok)
  (t/is= [["A" "B"]] (graph :edges))
  (t/is= 2 (length (graph :nodes))))

(t/test "an unknown form is skipped rather than fatal"
  # Forward compatibility costs nothing and a hard error costs the picture.
  (def [ok graph] (v/parse `(node A :label "A") (sparkle A :loudly)`))
  (t/ok ok)
  (t/is= 1 (length (graph :nodes))))

(t/test "an unknown attribute is carried, not dropped"
  # A row is a row. Under nesting an unrecognised form took everything
  # inside it down too; here the fact just rides along.
  (def [ok graph] (v/parse `(node A :label "A" :sparkle "loudly")`))
  (t/ok ok)
  (t/is= "loudly" ((first (graph :nodes)) :sparkle)))

(t/test "malformed text is a message, not an exception"
  (def [ok why] (v/parse "(node A"))
  (t/ok (not ok))
  (t/ok (string? why) "and the caller gets something to show"))

(t/test "an edge needs two ends"
  (def [ok why] (v/parse "(edge A)"))
  (t/ok (not ok))
  (t/ok (string/find "two node names" why)))

(t/test "a node needs a name"
  (def [ok why] (v/parse `(node :label "nameless")`))
  (t/ok (not ok))
  (t/ok (string/find "no name" why)))

(t/test "an empty graph is a graph"
  (def [ok graph] (v/parse ""))
  (t/ok ok)
  (t/is= 0 (length (graph :nodes)))
  (t/is= 0 (length (graph :edges))))

(t/test "a bare (graph) wrapper is tolerated"
  # Older v files wrapped their forms in one. The nested body inside such a
  # file no longer parses, but an empty wrapper is fact-free rather than fatal.
  (def [ok graph] (v/parse "(graph)"))
  (t/ok ok)
  (t/is= 0 (length (graph :nodes))))
