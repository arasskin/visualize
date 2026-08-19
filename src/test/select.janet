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
  {:nodes [{:name "Otto.App" :label "Otto.\nApp" :ours true}
           {:name "Otto.View" :label "Otto.\nView" :ours true}
           {:name "OttoClip.Cart" :label "OttoClip.\nCart" :ours true}
           {:name "SwiftUI" :label "SwiftUI" :ours false}]
   :edges [["Otto.View" "Otto.App"]
           ["SwiftUI" "Otto.View"]
           ["OttoClip.Cart" "Otto.App"]]
   :sizes {"Otto.App" 120 "Otto.View" 1300 "OttoClip.Cart" 40}
   :ours {"Otto.App" true "Otto.View" true "OttoClip.Cart" true}})

(t/test "every name is literal, and the empty prefix means ours"
  # `~` used to mean "inside the project" -- `~.Otto` -- and said nothing
  # once node names became dotted paths, since it stripped to `Otto`. What it
  # also carried was `~` alone for "everything of ours", and that is the
  # EMPTY prefix now: matches? reads it by membership rather than as a string
  # test, so it keeps your files and drops the externals.
  (t/is= "" (select/expand "") "the empty prefix -- everything of ours")
  (t/is= "Otto" (select/expand "Otto"))
  (t/is= "Otto.Shared" (select/expand "Otto.Shared"))
  (t/is= "SwiftUI" (select/expand "SwiftUI") "a plain name means the external"))

(t/test "a config name is the dotted path, which is what the node shows"
  # ONE SPELLING. The node reads `src.test`, answers to `src.test`, and is
  # selected by typing `src.test` -- there is no translation step left to get
  # wrong. A slash is still accepted, because a path is a natural thing to
  # type and refusing it would buy nothing.
  (t/is= "src.test" (select/expand "src.test") "as the label shows it")
  (t/is= "src.test" (select/expand "src/test") "a slash is taken too")
  (t/is= "src.test" (select/expand "src.test") "no prefix to strip any more")
  (t/is= "demo-api.worker" (select/expand "demo-api.worker")
         "a hyphen inside a name survives")
  (t/is= "" (select/expand "") "and the empty prefix is everything of ours"))

(t/test "the empty prefix means OURS, not everything"
  # Without this, (only ~) would keep the externals too and mean nothing.
  (def ours {"Otto.App" true})
  (t/ok (select/matches? "Otto.App" "" ours))
  (t/ok (not (select/matches? "SwiftUI" "" ours))))

(t/test "only narrows to a prefix and keeps only interior edges"
  # The empty prefix is what `~` alone used to spell: ours, by membership.
  (def got (select/keep (sample) [""]))
  (t/is= ["Otto.App" "Otto.View" "OttoClip.Cart"]
         (sorted (map |($ :name) (got :nodes)))
         "the external is gone")
  # The SwiftUI edge must go with it: an edge to a node that is not drawn
  # would rank against something that is not on the page.
  (t/is= [["Otto.View" "Otto.App"] ["OttoClip.Cart" "Otto.App"]]
         (sorted (got :edges))))

(t/test "nothing declared means no filter at all"
  (t/is= 4 (length ((select/keep (sample) []) :nodes))))

(t/test "hide removes nodes and every edge touching them"
  (def got (select/drop-nodes (sample) ["OttoClip"]))
  (t/ok (not (index-of "OttoClip.Cart" (map |($ :name) (got :nodes)))))
  (t/is= 2 (length (got :edges))))

(t/test "a trailing dot hides the contents, not the thing itself"
  # (hide ~.Otto.) hides Otto/'s files while leaving OttoClip's alone --
  # which the plain prefix `Otto` cannot express, since it matches both.
  (def both (select/drop-nodes (sample) ["Otto"]))
  (t/is= ["SwiftUI"] (map |($ :name) (both :nodes))
         "the plain prefix takes OttoClip with it, because a prefix is a prefix")
  (def just-otto (select/drop-nodes (sample) ["Otto."]))
  (t/is= ["OttoClip.Cart" "SwiftUI"] (sorted (map |($ :name) (just-otto :nodes)))
         "the trailing dot leaves OttoClip alone"))

(t/test "an orphaned node stays on the graph"
  # Hiding the only thing that referenced it takes the edges, not the node.
  # "This is here and nothing you are looking at uses it" is a fact about the
  # picture you asked for, not a defect in it.
  (def got (select/drop-nodes (sample) ["Otto."]))
  (t/ok (index-of "SwiftUI" (map |($ :name) (got :nodes)))))

(t/test "degrees counts both directions"
  (def counts (select/degrees (sample)))
  (t/is= 2 (counts "Otto.View") "one in, one out")
  (t/is= 2 (counts "Otto.App"))
  (t/is= 1 (counts "SwiftUI")))

(t/test "boxes nest rather than compete"
  # `(box api)` and `(box api.v1)` are not rivals for the same node: the
  # second is INSIDE the first, and a node under both is drawn in both. This
  # used to be first-match-wins, so whichever was declared first swallowed
  # the other and the order of two lines decided which box you got.
  (def ours {"api.v1.users" true "web.page" true})
  (def boxes [{:prefix "api" :color "#b"} {:prefix "api.v1" :color "#r"}])

  (def chain (select/boxes-for "api.v1.users" boxes ours))
  (t/is= ["api" "api.v1"] (map |($ :prefix) chain) "widest first")

  # Declared the other way round, the chain is the same: nesting is about
  # the prefixes, not about which line came first.
  (def flipped (select/boxes-for "api.v1.users" (reverse boxes) ours))
  (t/is= ["api" "api.v1"] (map |($ :prefix) flipped))

  (t/is= [] (select/boxes-for "web.page" boxes ours) "a node in neither")

  # A node's own colour comes from the INNERMOST box: the outer ones say
  # something about a region, the inner one about the node.
  (t/is= "api.v1" ((select/group-for "api.v1.users" boxes ours) :prefix))

  # THE EMPTY PREFIX IS WIDEST OF ALL. It means "ours", so a box over it
  # holds every one of your files and every box inside them.
  (def with-all [{:prefix "" :color "#g"} ;boxes])
  (t/is= ["" "api" "api.v1"]
         (map |($ :prefix) (select/boxes-for "api.v1.users" with-all ours))))

(t/test "resolve answers the config's questions on the node"
  # THE RENDERER READS FIELDS, NOT CONFIG. Every question a drawing asks
  # about a node -- which box, what colour, is it flashing -- is answered
  # here, so layout needs no opinion about prefixes and does not import this
  # module.
  (def graph {:nodes [{:name "a.b" :label "b"}
                      {:name "a.c" :label "c"}
                      {:name "x" :label "x"}]
              :ours {"a.b" true "a.c" true "x" true}})
  # A STUB PALETTE, which is the point of passing one: this file tests what
  # resolve puts on a node, not what the real palette computes.
  (def palette {:ungrouped "#999999"
                :ink |(string $ "-ink")
                :tint |(string $ "-fill")})
  (def out (select/resolve graph [{:prefix "a" :color "#111111"}] {"x" true} palette))
  (def by-name (tabseq [n :in (out :nodes)] (n :name) n))

  (t/is= "a" (get-in by-name ["a.b" :box]) "a node under the prefix is boxed")
  (t/is= [{:prefix "a" :colour "#111111"}] (get-in by-name ["a.b" :boxes])
         "and carries the chain it is nested in, each box with its own colour")
  (t/is= "#111111" (get-in by-name ["a.b" :colour]) "and wears the box's colour")
  (t/is= nil (get-in by-name ["x" :box]) "one outside it is not")
  (t/is= "#999999" (get-in by-name ["x" :colour])
         "and wears the ungrouped colour the palette named")

  # EXACT COLOURS, so the renderer prints rather than computes.
  (t/is= "#111111-ink" (get-in by-name ["a.b" :ink]) "the ink is resolved")
  (t/is= "#111111-fill" (get-in by-name ["a.b" :fill]) "and so is the flash fill")

  (t/ok (get-in by-name ["x" :fresh]) "a moved file is flagged")
  (t/ok (not (get-in by-name ["a.b" :fresh])) "an unmoved one is not")

  # Identity and text are already right by the time this runs.
  (t/is= "b" (get-in by-name ["a.b" :label]) "the label is left alone")
  (t/is= "a.b" (get-in by-name ["a.b" :name]) "and so is the name"))

(t/test "a prefix shortens the labels it covers"
  (def aliases [{:alias "~" :prefix "src.visualize"}])
  (t/is= "~.color" (select/alias-label aliases "src.visualize.color"))
  (t/is= "~" (select/alias-label aliases "src.visualize") "the path itself")
  (t/is= nil (select/alias-label aliases "src.test") "an unrelated node")
  # A DOT BOUNDARY, not a character one: `src.visualizer` merely starts with
  # the same letters and keeps its own name.
  (t/is= nil (select/alias-label aliases "src.visualizer.x"))
  # Longest first here too, so the alias that covers most shortens most.
  (def two [{:alias "~~" :prefix "src.visualize"} {:alias "~" :prefix "src"}])
  (t/is= "~~.color" (select/alias-label two "src.visualize.color"))
  (t/is= "~.test" (select/alias-label two "src.test")))

(t/test "collapse folds a region into one node"
  (def graph
    {:nodes [{:name "p.go" :label "go" :ours true}
             {:name "p.py" :label "py" :ours true}
             {:name "p.shared" :label "shared" :ours true}
             {:name "main" :label "main" :ours true}
             {:name "util" :label "util" :ours true}]
     # Two members point out, one points in, and one edge is between members.
     :edges [["p.go" "main"] ["p.py" "main"] ["util" "p.go"] ["p.go" "p.shared"]]
     :ours {"p.go" true "p.py" true "p.shared" true "main" true "util" true}})
  (def sizes {"p.go" 10 "p.py" 20 "p.shared" 30 "main" 1 "util" 2})
  (def [out counts] (select/collapse graph ["p"] sizes))

  (t/is= ["main" "p" "util"] (sort (map |($ :name) (out :nodes)))
         "three files became one node")

  # THE COLLAPSED NODE WEARS THE EDGES ITS MEMBERS HAD. Two of them pointed
  # at main, and that is one arrow now: five files importing one thing is
  # one dependency once they are one node.
  (t/is= [["p" "main"] ["util" "p"]] (sort (out :edges)))

  # AN EDGE BETWEEN MEMBERS GOES. p.go -> p.shared is inside the node now,
  # and an arrow from a thing to itself says nothing the collapse did not.
  (t/ok (not (find |(= $ ["p" "p"]) (out :edges))))

  # THE LINE COUNT ADDS UP, so a collapsed box reads the size of what it
  # stands for.
  (t/is= 60 (counts "p"))
  (t/is= 1 (counts "main") "and the others are untouched")
  (t/is= nil (counts "p.go") "a member's own count goes with it"))

(t/test "collapse leaves a region of one alone"
  # Folding a single thing into itself changes only its name, and the point
  # of collapsing is to say less about a region's inside -- which a region
  # of one already does.
  (def graph {:nodes [{:name "a.only" :ours true} {:name "b" :ours true}]
              :edges [["a.only" "b"]]
              :ours {"a.only" true "b" true}})
  (def [out counts] (select/collapse graph ["a"] {"a.only" 5 "b" 3}))
  (t/is= ["a.only" "b"] (sort (map |($ :name) (out :nodes))))
  (t/is= 5 (counts "a.only") "and keeps its own count")

  # Nothing declared, nothing done.
  (def [same] (select/collapse graph [] {}))
  (t/is= 2 (length (same :nodes))))

(t/test "two collapses that overlap fold a node once"
  # First match by declaration order, like the boxes: a node folded into
  # both would be drawn twice.
  (def graph {:nodes [{:name "a.b.x" :ours true} {:name "a.b.y" :ours true}
                      {:name "a.c" :ours true}]
              :edges [["a.b.x" "a.c"]]
              :ours {"a.b.x" true "a.b.y" true "a.c" true}})
  (def [out] (select/collapse graph ["a" "a.b"] {}))
  (t/is= ["a"] (map |($ :name) (out :nodes))
         "the wider one declared first takes everything"))
