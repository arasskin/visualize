(import ../../src.server/select)
(import ./harness :as t)

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

  (t/is= "" (select/expand "") "the empty prefix -- everything of ours")
  (t/is= "Otto" (select/expand "Otto"))
  (t/is= "Otto.Shared" (select/expand "Otto.Shared"))
  (t/is= "SwiftUI" (select/expand "SwiftUI") "a plain name means the external"))

(t/test "a config name is the dotted path, which is what the node shows"

  (t/is= "src.test" (select/expand "src.test") "as the label shows it")
  (t/is= "src.test" (select/expand "src/test") "a slash is taken too")
  (t/is= "src.test" (select/expand "src.test") "no prefix to strip any more")
  (t/is= "demo-api.worker" (select/expand "demo-api.worker")
         "a hyphen inside a name survives")
  (t/is= "" (select/expand "") "and the empty prefix is everything of ours"))

(t/test "the empty prefix means OURS, not everything"

  (def ours {"Otto.App" true})
  (t/ok (select/matches? "Otto.App" "" ours))
  (t/ok (not (select/matches? "SwiftUI" "" ours))))

(t/test "only narrows to a prefix and keeps only interior edges"

  (def got (select/keep (sample) [""]))
  (t/is= ["Otto.App" "Otto.View" "OttoClip.Cart"]
         (sorted (map |($ :name) (got :nodes)))
         "the external is gone")

  (t/is= [["Otto.View" "Otto.App"] ["OttoClip.Cart" "Otto.App"]]
         (sorted (got :edges))))

(t/test "nothing declared means no filter at all"
  (t/is= 4 (length ((select/keep (sample) []) :nodes))))

(t/test "hide removes nodes and every edge touching them"
  (def got (select/drop-nodes (sample) ["OttoClip"]))
  (t/ok (not (index-of "OttoClip.Cart" (map |($ :name) (got :nodes)))))
  (t/is= 2 (length (got :edges))))

(t/test "a trailing dot hides the contents, not the thing itself"

  (def both (select/drop-nodes (sample) ["Otto"]))
  (t/is= ["SwiftUI"] (map |($ :name) (both :nodes))
         "the plain prefix takes OttoClip with it, because a prefix is a prefix")
  (def just-otto (select/drop-nodes (sample) ["Otto."]))
  (t/is= ["OttoClip.Cart" "SwiftUI"] (sorted (map |($ :name) (just-otto :nodes)))
         "the trailing dot leaves OttoClip alone"))

(t/test "an orphaned node stays on the graph"

  (def got (select/drop-nodes (sample) ["Otto."]))
  (t/ok (index-of "SwiftUI" (map |($ :name) (got :nodes)))))

(t/test "degrees counts both directions"
  (def counts (select/degrees (sample)))
  (t/is= 2 (counts "Otto.View") "one in, one out")
  (t/is= 2 (counts "Otto.App"))
  (t/is= 1 (counts "SwiftUI")))

(t/test "boxes nest rather than compete"

  (def ours {"api.v1.users" true "web.page" true})
  (def boxes [{:prefix "api" :color "#b"} {:prefix "api.v1" :color "#r"}])

  (def chain (select/boxes-for "api.v1.users" boxes ours))
  (t/is= ["api" "api.v1"] (map |($ :prefix) chain) "widest first")

  (def flipped (select/boxes-for "api.v1.users" (reverse boxes) ours))
  (t/is= ["api" "api.v1"] (map |($ :prefix) flipped))

  (t/is= [] (select/boxes-for "web.page" boxes ours) "a node in neither")

  (t/is= "api.v1" ((select/group-for "api.v1.users" boxes ours) :prefix))

  (def with-all [{:prefix "" :color "#g"} ;boxes])
  (t/is= ["" "api" "api.v1"]
         (map |($ :prefix) (select/boxes-for "api.v1.users" with-all ours))))

(t/test "resolve answers the config's questions on the node"

  (def graph {:nodes [{:name "a.b" :label "b"}
                      {:name "a.c" :label "c"}
                      {:name "x" :label "x"}]
              :ours {"a.b" true "a.c" true "x" true}})

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

  (t/is= "#111111-ink" (get-in by-name ["a.b" :ink]) "the ink is resolved")
  (t/is= "#111111-fill" (get-in by-name ["a.b" :fill]) "and so is the flash fill")

  (t/ok (get-in by-name ["x" :fresh]) "a moved file is flagged")
  (t/ok (not (get-in by-name ["a.b" :fresh])) "an unmoved one is not")

  (t/is= "b" (get-in by-name ["a.b" :label]) "the label is left alone")
  (t/is= "a.b" (get-in by-name ["a.b" :name]) "and so is the name"))

(t/test "fold turns a region into one node"
  (def graph
    {:nodes [{:name "p.go" :label "go" :ours true}
             {:name "p.py" :label "py" :ours true}
             {:name "p.shared" :label "shared" :ours true}
             {:name "main" :label "main" :ours true}
             {:name "util" :label "util" :ours true}]

     :edges [["p.go" "main"] ["p.py" "main"] ["util" "p.go"] ["p.go" "p.shared"]]
     :ours {"p.go" true "p.py" true "p.shared" true "main" true "util" true}})
  (def sizes {"p.go" 10 "p.py" 20 "p.shared" 30 "main" 1 "util" 2})
  (def [out counts] (select/fold graph ["p"] sizes))

  (t/is= ["main" "p" "util"] (sort (map |($ :name) (out :nodes)))
         "three files became one node")

  (t/is= [["p" "main"] ["util" "p"]] (sort (out :edges)))

  (t/ok (not (find |(= $ ["p" "p"]) (out :edges))))

  (t/is= 60 (counts "p"))
  (t/is= 1 (counts "main") "and the others are untouched")
  (t/is= nil (counts "p.go") "a member's own count goes with it"))

(t/test "folded edges retain each original connection through repeated folds"
  (def graph {:nodes (map |{:name $ :ours true}
                         ["source" "pkg" "pkg.sub.a.py" "pkg.sub.b.py" "pkg.other.py"])
              :edges [["source" "pkg.sub.b.py"] ["source" "pkg.sub.a.py"]
                      ["source" "pkg.sub.a.py"] ["source" "pkg"]
                      ["pkg.sub.a.py" "pkg.sub.b.py"]]})
  (def [inner] (select/fold graph ["pkg.sub"] {}))
  (t/is= [["source" "pkg.sub.a.py"] ["source" "pkg.sub.b.py"]]
         (get-in inner [:edge-origins ["source" "pkg.sub"]]))
  (def [outer] (select/fold inner ["pkg"] {}))
  (t/is= [["source" "pkg"]] (outer :edges))
  (t/is= [["source" "pkg"] ["source" "pkg.sub.a.py"] ["source" "pkg.sub.b.py"]]
         (get-in outer [:edge-origins ["source" "pkg"]])
         "merged edges retain destinations, including an existing prefix node, without duplicates"))

(t/test "fold leaves a region of one alone"

  (def graph {:nodes [{:name "a.only" :ours true} {:name "b" :ours true}]
              :edges [["a.only" "b"]]
              :ours {"a.only" true "b" true}})
  (def [out counts] (select/fold graph ["a"] {"a.only" 5 "b" 3}))
  (t/is= ["a.only" "b"] (sort (map |($ :name) (out :nodes))))
  (t/is= 5 (counts "a.only") "and keeps its own count")

  (def [same] (select/fold graph [] {}))
  (t/is= 2 (length (same :nodes))))

(t/test "outer folds absorb nested folds in either declaration order"

  (def graph {:nodes [{:name "a.b.x" :ours true} {:name "a.b.y" :ours true}
                      {:name "a.c" :ours true}]
              :edges [["a.b.x" "a.c"] ["a.c" "a.b.y"]]
              :ours {"a.b.x" true "a.b.y" true "a.c" true}})
  (each prefixes [["a" "a.b"] ["a.b" "a"] ["a/b" "a"]]
    (def [out sizes] (select/fold graph prefixes {"a.b.x" 10 "a.b.y" 20 "a.c" 30}))
    (t/is= ["a"] (map |($ :name) (out :nodes)))
    (t/is= [] (out :edges) "all internal edges disappear")
    (t/is= {"a" 60} sizes "every member is counted once")))

(t/test "a parent fold absorbs children even when it has no direct files"
  (def graph {:nodes [{:name "milestone1.X.a" :ours true}
                      {:name "milestone1.X.b" :ours true}
                      {:name "outside" :ours true}]
              :edges [["milestone1.X.a" "outside"] ["milestone1.X.b" "outside"]
                      ["outside" "milestone1.X.b"]]
              :ours {"milestone1.X.a" true "milestone1.X.b" true "outside" true}})
  (def [out sizes] (select/fold graph ["milestone1.X" "milestone1"]
                              {"milestone1.X.a" 10 "milestone1.X.b" 20 "outside" 5}))
  (t/is= ["milestone1" "outside"] (map |($ :name) (out :nodes)))
  (t/is= [["milestone1" "outside"] ["outside" "milestone1"]] (out :edges))
  (t/is= {"milestone1" 30 "outside" 5} sizes)
  (def boxes [{:prefix "milestone1" :color "blue"} {:prefix "milestone1.X" :color "red"}])
  (t/is= ["milestone1"]
         (map |($ :prefix) (select/boxes-for "milestone1" boxes (graph :ours)))))

(t/test "an external is named with its mark, and only with its mark"

  (def ours {"otto.mcp.core.py" true})
  (t/ok (select/matches? "?.uvicorn" "?.uvicorn" ours) "marked matches")
  (t/ok (not (select/matches? "?.uvicorn" "uvicorn" ours))
        "and unmarked no longer does")

  (t/ok (select/matches? "?.structlog.typing" "?.structlog" ours)
        "a marked prefix reaches the names under it")
  (t/ok (select/matches? "?.anything" "?." ours) "and `?.` alone is all of them")

  (t/ok (select/matches? "otto.mcp.core.py" "otto.mcp" ours))
  (t/ok (not (select/matches? "otto.mcp.core.py" "?.otto.mcp" ours))
        "and marking it stops it matching the file"))

(t/test "an external under a name we also own is told apart by the mark"

  (def ours {"archive.otto-py.core.py" true})
  (t/ok (select/matches? "archive.otto-py.core.py" "archive" ours))
  (t/ok (not (select/matches? "?.archive.otto-py.ui" "archive" ours))
        "hiding the directory leaves the external alone")
  (t/ok (select/matches? "?.archive.otto-py.ui" "?.archive" ours)
        "and the marked name reaches it"))

(t/test "a scoped external hide reaches only that project's externals"

  (def g {:nodes [{:name "childA.a.py" :ours true}
                  {:name "childB.b.py" :ours true}
                  {:name "?.libA" :ours false}
                  {:name "?.libB" :ours false}]
          :edges [["childA.a.py" "?.libA"] ["childB.b.py" "?.libB"]]
          :ours {"childA.a.py" true "childB.b.py" true}})
  (def out (select/drop-nodes g ["?@childA"]))
  (def left (sorted (map |($ :name) (out :nodes))))
  (t/ok (not (index-of "?.libA" left)) "childA's external went")
  (t/ok (index-of "?.libB" left) "childB's stayed")

  (def all (select/drop-nodes g ["?"]))
  (t/is= ["childA.a.py" "childB.b.py"] (sorted (map |($ :name) (all :nodes)))
         "an unscoped mark takes them all"))

(t/test "hiding the last thing that referenced an external takes it too"

  (def g {:nodes [{:name "archive.old.py" :ours true}
                  {:name "src.main.py" :ours true}
                  {:name "src.orphan.py" :ours true}
                  {:name "?.structlog" :ours false}
                  {:name "?.WebKit" :ours false}]
          :edges [["archive.old.py" "?.structlog"]
                  ["src.main.py" "?.WebKit"]]
          :ours {"archive.old.py" true "src.main.py" true
                 "src.orphan.py" true}})
  (def out (select/drop-nodes g ["archive"]))
  (def left (sorted (map |($ :name) (out :nodes))))
  (t/ok (not (index-of "?.structlog" left))
        "the external went with the only file that named it")
  (t/ok (index-of "?.WebKit" left)
        "one still referenced stayed")
  (t/ok (index-of "src.orphan.py" left)
        "and a file of ours with no edges is still a fact worth drawing"))
