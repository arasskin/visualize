# The v language: what it parses, what it writes, and that the two agree.
#
# TWO LEVELS, because the language has two. `facts` turns text into rows of
# [entity attribute value], and `parse` builds a graph out of rows -- so the
# tests that matter most are the ones on the rows, since that is the model
# and the graph is a consumer of it.

(import ../src/v)
(import ./harness :as t)

(defn- rows-of [text]
  (def [ok rows] (v/facts text))
  (t/ok ok (string "it parsed: " (if ok "" rows)))
  (map |[($ 0) ($ 1) ($ 2)] rows))

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
# The facts: the language itself.
#

(t/test "a form is an entity and what is true of it"
  (t/is= [["A" :is true]
          ["A" :label "A"]
          ["A" :ours true]
          ["A" :size 12]]
         (rows-of `(A label "A" ours size 12)`)
         "one row per attribute, all sharing the entity"))

(t/test "the schema decides which attributes take a value"
  # THE WHOLE REASON FOR A SCHEMA. Without it `(A ours size 12)` is
  # ambiguous: `size` could be the value of `ours` as easily as an
  # attribute of its own. `ours` is declared a flag, so it is not.
  (t/is= [["A" :is true] ["A" :ours true] ["A" :size 12]]
         (rows-of "(A ours size 12)")))

(t/test "a colon on an attribute is spelling, not meaning"
  (t/is= (rows-of `(A label "A" ours size 12)`)
         (rows-of `(A :label "A" :ours :size 12)`)
         "label and :label are the same word"))

(t/test "an entity that says nothing still exists"
  (t/is= [["Solo" :is true]] (rows-of "(Solo)")))

(t/test "a bare word that is not an attribute names another entity"
  # How a node joins a group: it says the group's name. Decidable only
  # because the schema is closed -- a known word is an attribute, an
  # unknown one is a reference.
  (t/is= [["A" :is true] ["A" :in "~.Otto"]]
         (rows-of "(A ~.Otto)")))

(t/test "an edge is an entity with from and to"
  (t/is= [["A->B" :is true] ["A->B" :from "A"] ["A->B" :to "B"]]
         (rows-of "(A->B from A to B)")))

(t/test "a group is an entity with a colour"
  (t/is= [["~.term" :is true] ["~.term" :color "#ff4d6d"]]
         (rows-of `(~.term color "#ff4d6d")`)))

(t/test "a node may name several groups"
  # Unsayable under nesting: a node sat inside exactly one set of parens.
  (t/is= [["A" :is true] ["A" :in "One"] ["A" :in "Two"]]
         (rows-of "(A One Two)")))

#
# What the schema refuses.
#

(t/test "an attribute with no value left is a message"
  (def [ok why] (v/facts "(A size)"))
  (t/ok (not ok))
  (t/ok (string/find "needs a value" why)))

(t/test "a value with no attribute to belong to is a message"
  # A bare word would be an entity reference, but a NUMBER cannot name one.
  (def [ok why] (v/facts "(A 187)"))
  (t/ok (not ok))
  (t/ok (string/find "no attribute" why)))

(t/test "an empty form is a message"
  (def [ok why] (v/facts "()"))
  (t/ok (not ok))
  (t/ok (string? why)))

#
# The graph built from the facts.
#

(t/test "a hand-written graph parses"
  (def [ok graph] (v/parse `
    (A label "A" ours size 12)
    (B label "B")
    (A->B from A to B)`))
  (t/ok ok "it parsed")
  (t/is= ["A" "B"] (map |($ :name) (graph :nodes)))
  (t/is= [["A" "B"]] (graph :edges))
  (t/is= 12 ((graph :sizes) "A"))
  (t/ok ((graph :ours) "A"))
  (t/ok (not ((graph :ours) "B")) "`ours` is a flag, and B does not carry it"))

(t/test "a node with no label uses its own name"
  (def [_ graph] (v/parse "(Solo)"))
  (t/is= "Solo" ((first (graph :nodes)) :label)))

(t/test "comments and whitespace are skipped"
  (def [ok graph] (v/parse `
    ; the whole graph
    (A label "A")   ; trailing
    (A->A from A to A)`))
  (t/ok ok)
  (t/is= 1 (length (graph :nodes))))

(t/test "a bare word takes characters DOT would have rejected"
  # The reason `safe-name` existed: graphviz rejected a hyphen in a bare
  # identifier. v has no such rule, so this parses as one token.
  (def [ok graph] (v/parse `(demo-api.worker label "demo-api")`))
  (t/ok ok)
  (t/is= "demo-api.worker" ((first (graph :nodes)) :name)))

(t/test "an entity somebody names is a group, not a node"
  (def [ok graph] (v/parse `
    (~.Otto color "#ff4d6d")
    (Loose label "Loose")
    (Otto_App label "Otto/App" ~.Otto)
    (Otto_View label "Otto/View" ~.Otto)`))
  (t/ok ok)
  (t/is= ["Loose" "Otto_App" "Otto_View"] (map |($ :name) (graph :nodes))
         "the group is not among the nodes")
  (t/is= [{:prefix "~.Otto" :color "#ff4d6d"}] (graph :groups))
  (t/is= @{"Otto_App" "~.Otto" "Otto_View" "~.Otto"} (graph :claimed)
         "and membership came off the members"))

(t/test "a group's members need not be adjacent"
  # The case the nested language could not express and svg/draw had to work
  # around by drawing one box per layer.
  (def [_ graph] (v/parse "(A G) (B) (C G)"))
  (t/is= @{"A" "G" "C" "G"} (graph :claimed))
  (t/is= ["A" "B" "C"] (map |($ :name) (graph :nodes))))

(t/test "a group named but never described still exists"
  (def [_ graph] (v/parse "(A G)"))
  (t/is= ["G"] (map |($ :prefix) (graph :groups))
         "the row that names it is enough to create it"))

(t/test "a group described but never joined still exists"
  (def [_ graph] (v/parse `(G color "#abc")`))
  (t/is= [{:prefix "G" :color "#abc"}] (graph :groups))
  (t/is= 0 (length (graph :nodes)) "and it is not mistaken for a node"))

(t/test "an edge may reference a node no form declared"
  # The row that names it is enough to create it, so order never matters.
  (def [ok graph] (v/parse "(A->B from A to B)"))
  (t/ok ok)
  (t/is= [["A" "B"]] (graph :edges))
  (t/is= ["A" "B"] (map |($ :name) (graph :nodes))))

(t/test "an edge may be declared before its ends"
  (def [ok graph] (v/parse `
    (A->B from A to B)
    (A label "A")
    (B label "B")`))
  (t/ok ok)
  (t/is= [["A" "B"]] (graph :edges))
  (t/is= 2 (length (graph :nodes)))
  (t/is= "A" ((first (graph :nodes)) :label) "and the later label still lands"))

(t/test "an edge missing an end is a message"
  (def [ok why] (v/parse "(A->B from A)"))
  (t/ok (not ok))
  (t/ok (string/find "both from and to" why)))

(t/test "a string label decodes its escapes"
  # DOT carried the two characters `\` and `n` and let graphviz split them;
  # here the label reaches the renderer with a real newline in it.
  (def [_ graph] (v/parse `(A label "Otto/\nApp")`))
  (t/is= "Otto/\nApp" ((first (graph :nodes)) :label))
  (t/is= 2 (length (string/split "\n" ((first (graph :nodes)) :label)))))

(t/test "a quote in a label cannot break out of the string"
  (def text (v/render {:nodes [{:name "N" :label `He said "hi"` :ours true}]
                       :edges [] :sizes {} :ours {"N" true}}))
  (def [ok graph] (v/parse text))
  (t/ok ok "the rendered text still parses")
  (t/is= `He said "hi"` ((first (graph :nodes)) :label) "and the label survives"))

(t/test "an empty graph is a graph"
  (def [ok graph] (v/parse ""))
  (t/ok ok)
  (t/is= 0 (length (graph :nodes)))
  (t/is= 0 (length (graph :edges))))

#
# Writing.
#

(t/test "rendering writes a form per entity"
  (def text (v/render (sample)))
  (t/ok (string/find `(Otto_App label "Otto/\nApp" ours size 120)` text))
  (t/ok (string/find "(Otto_View->Otto_App from Otto_View to Otto_App)" text))
  (t/ok (not (string/find "(node " text)) "there is no head, only the entity")
  (t/ok (not (string/find "(graph" text)) "and no wrapper to nest under"))

(t/test "a group is described once and named by each member"
  (def text (v/render (sample) {:groups [{:prefix "Otto_" :color "#ff4d6d"}]}))
  (t/ok (string/find `(Otto_ color "#ff4d6d")` text) "described once")
  (t/ok (string/find "size 120 Otto_)" text) "and named by a member")
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
  # prefix, so `select/group-for` never claimed it.
  (t/is= @{"Otto_App" "Otto_" "Otto_View" "Otto_"} (back :claimed))
  (t/is= [{:prefix "Otto_" :color "#ff4d6d"}] (back :groups)
         "and the colour came back with it"))

(t/test "what the text said outranks what a prefix would derive"
  # A graph read from v carries its memberships; re-deriving them from the
  # config's prefixes would silently rewrite the file.
  (def [_ graph] (v/parse `
    (Weird color "#abc")
    (unrelated_name label "n" Weird)`))
  (def text (v/render graph {:groups (graph :groups)}))
  (t/ok (string/find "Weird)" text)
        "the membership is written back even though no prefix implies it"))

(t/test "a second round trip changes nothing"
  # If the first pass were lossy, the second would differ from it.
  (def once (v/render (sample)))
  (def [_ back] (v/parse once))
  (t/is= once (v/render back)))
