# The layered layout: ranking, cycles, ordering, and the picture that comes out.

(import ../src/layout/layered)
(import ../src/layout)
(import ../src/select)
(import ./harness :as t)

(defn- names-at [places layer gap]
  (sort (seq [[name p] :pairs places :when (= (p :y) (* layer gap))] name)))

(t/test "a chain ranks one node per layer"
  (def [layer _] (layered/rank ["A" "B" "C"] [["A" "B"] ["B" "C"]]))
  (t/is= 0 (layer "A"))
  (t/is= 1 (layer "B"))
  (t/is= 2 (layer "C")))

(t/test "ranking is longest-path, not first-path"
  # D depends on A directly AND through B and C. It belongs below the longest
  # chain, or its edge to C would point upward.
  (def [layer _] (layered/rank ["A" "B" "C" "D"]
                               [["A" "B"] ["B" "C"] ["C" "D"] ["A" "D"]]))
  (t/is= 3 (layer "D") "the long way round wins"))

(t/test "a node nothing points at starts at the top"
  (def [layer _] (layered/rank ["A" "B" "Loose"] [["A" "B"]]))
  (t/is= 0 (layer "A"))
  (t/is= 0 (layer "Loose") "an orphan is a source"))

(t/test "a cycle is broken, ranked, and remembered"
  # A dependency graph is not a DAG -- two files importing each other is
  # common and worth SEEING. The back edge is recorded so the renderer can
  # draw it in its original direction, pointing back up the page.
  (def [layer back] (layered/rank ["A" "B"] [["A" "B"] ["B" "A"]]))
  (t/is= 0 (layer "A"))
  (t/is= 1 (layer "B") "the cycle did not stop the ranking")
  (t/is= 1 (length (keys back)) "exactly one edge was reversed"))

(t/test "a three-node cycle still ranks"
  (def [layer back] (layered/rank ["A" "B" "C"]
                                  [["A" "B"] ["B" "C"] ["C" "A"]]))
  (t/is= 0 (layer "A"))
  (t/is= 1 (layer "B"))
  (t/is= 2 (layer "C"))
  (t/is= 1 (length (keys back))))

(t/test "a self-edge is not a cycle to break"
  (def [layer back] (layered/rank ["A"] [["A" "A"]]))
  (t/is= 0 (layer "A"))
  (t/ok (empty? (keys back)) "a node depending on itself ranks fine"))

(t/test "placing puts every node on its layer's line"
  (def graph {:nodes [{:name "A" :label "A"} {:name "B" :label "B"}
                      {:name "C" :label "C"}]
              :edges [["A" "B"] ["A" "C"]]})
  (def out (layered/place graph {:layer-gap 100}))
  (def points (out :points))
  (t/is= 0 ((points "A") :y))
  (t/is= 100 ((points "B") :y))
  (t/is= 100 ((points "C") :y) "siblings share a layer")
  (t/ok (not= ((points "B") :x) ((points "C") :x)) "and do not overlap"))

(t/test "a parent sits between its children"
  (def graph {:nodes [{:name "P" :label "P"} {:name "L" :label "L"}
                      {:name "R" :label "R"}]
              :edges [["P" "L"] ["P" "R"]]})
  (def points ((layered/place graph) :points))
  (def parent ((points "P") :x))
  (def left (min ((points "L") :x) ((points "R") :x)))
  (def right (max ((points "L") :x) ((points "R") :x)))
  (t/ok (and (>= parent left) (<= parent right))
        "the parent is over the span of its children"))

(t/test "an edge crossing a layer gets bend points"
  # THE THING A FORCE LAYOUT CANNOT DO. A -> C spans two layers, so it is
  # routed around B rather than drawn through it.
  (def graph {:nodes [{:name "A" :label "A"} {:name "B" :label "B"}
                      {:name "C" :label "C"}]
              :edges [["A" "B"] ["B" "C"] ["A" "C"]]})
  (def out (layered/place graph {:layer-gap 100}))
  (t/is= 1 (length (get (out :routes) ["A" "C"]))
         "one bend, at the layer it skips")
  (t/is= 100 (((get (out :routes) ["A" "C"]) 0) 1) "and at that layer's y")
  (t/ok (not (get (out :routes) ["A" "B"]))
        "an edge between neighbours needs no routing"))

(t/test "no two nodes on a layer overlap"
  # THE BUG THIS EXISTS FOR. Placement alternates pulling a layer toward its
  # neighbours and sweeping it apart, and a layer's last touch was not always
  # the sweep -- so a middle layer could end pulled-but-not-separated. It
  # rendered fine on a three-node graph and put two ellipses on top of each
  # other on the real one. Non-overlap is a property of the output now, so
  # this checks the output.
  #
  # A wide fan with a long chain beside it: enough layers that the sweeps
  # alternate, and enough width that a pull has somewhere to go wrong.
  (def wide (seq [i :range [0 14]] {:name (string "n" i) :label (string "n" i)}))
  (def graph {:nodes [;wide {:name "root" :label "root"}
                      {:name "mid" :label "mid"} {:name "leaf" :label "leaf"}]
              :edges [;(seq [i :range [0 14]] ["root" (string "n" i)])
                      ["n0" "mid"] ["n7" "mid"] ["n13" "mid"] ["mid" "leaf"]]})
  (def width 120)
  (def out (layered/place graph {:measure (fn [_] width) :node-gap 20}))
  (def points (out :points))
  (def rows @{})
  (eachp [name p] points
    (put rows (p :y) (array/push (or (rows (p :y)) @[]) name)))
  (var overlaps 0)
  (eachp [_ row] rows
    (def sorted-row (sorted-by |((points $) :x) row))
    (for i 0 (- (length sorted-row) 1)
      (def gap (- ((points (sorted-row (+ i 1))) :x)
                  ((points (sorted-row i)) :x)))
      # Two nodes of the same width clear each other only if their centres
      # are at least one full width apart.
      (when (< gap (- width 0.01)) (++ overlaps))))
  (t/is= 0 overlaps "every layer is swept apart, whatever the iteration order"))

(t/test "layers share a centre line"
  # Packing every layer flush left made the widest one set the left edge and
  # stranded the narrow ones under its first few nodes -- an eighteen-node
  # row over a one-node row came out as a diagonal smear rather than a tree.
  (def graph {:nodes [;(seq [i :range [0 9]] {:name (string "n" i) :label (string "n" i)})
                      {:name "one" :label "one"}]
              :edges (seq [i :range [0 9]] [(string "n" i) "one"])})
  (def points ((layered/place graph {:measure (fn [_] 100)}) :points))
  (def top (filter |(zero? ((points $) :y)) (keys points)))
  (def centre (/ (sum (map |((points $) :x) top)) (length top)))
  (t/ok (< (math/abs (- ((points "one") :x) centre)) 60)
        "the single node below sits under the middle of the row above"))

(t/test "a group's members end up side by side"
  # A GROUP BOX IS A CLAIM. The renderer draws it around the members'
  # bounding box, so a non-member sitting between two members gets swallowed
  # and the picture asserts a membership that is not there.
  (def graph {:nodes [{:name "g1" :label "g1"} {:name "other" :label "other"}
                      {:name "g2" :label "g2"} {:name "another" :label "another"}
                      {:name "g3" :label "g3"}]
              :edges []})
  (def out (layered/place graph
                          {:measure (fn [_] 100)
                           :group-of (fn [name]
                                       (when (string/has-prefix? "g" name) "G"))}))
  (def points (out :points))
  (def row (sorted-by |((points $) :x) (keys points)))
  (def spots (seq [[i name] :pairs row :when (string/has-prefix? "g" name)] i))
  (t/is= [(first spots) (+ 1 (first spots)) (+ 2 (first spots))] spots
         "the three members are adjacent, with nothing between them"))

(t/test "cohesion leaves an ungrouped layer alone"
  (def row @{0 @["a" "b" "c"]})
  (t/is= @{0 @["a" "b" "c"]} (layered/cohere row (fn [_] nil))))

(t/test "cohesion keeps two groups apart"
  (def row @{0 @["a1" "b1" "a2" "b2"]})
  (def out (layered/cohere row (fn [name] (string/slice name 0 1))))
  (t/is= @{0 @["a1" "a2" "b1" "b2"]} out
         "each group is contiguous, and the first-seen group goes first"))

(t/test "the same graph draws the same picture twice"
  # A watcher redraw must not become a jump scare.
  (def graph {:nodes [{:name "A" :label "A"} {:name "B" :label "B"}
                      {:name "C" :label "C"} {:name "D" :label "D"}]
              :edges [["A" "B"] ["A" "C"] ["B" "D"] ["C" "D"]]})
  (t/is= ((layered/place graph) :points) ((layered/place graph) :points)))

(t/test "an empty graph does not blow up"
  (def out (layered/place {:nodes [] :edges []}))
  (t/is= 0 (length (keys (out :points)))))

(t/test "a wide label is given room"
  # Nothing here can measure a font, so the layout asks the renderer for an
  # estimate. A node whose label is twice as wide must not be placed as if
  # it were not.
  (def graph {:nodes [{:name "A" :label "A"} {:name "B" :label "B"}]
              :edges []})
  (def narrow (layered/place graph {:measure (fn [_] 100)}))
  (def wide (layered/place graph {:measure (fn [_] 300)}))
  (def spread (fn [out] (math/abs (- ((get (out :points) "A") :x)
                                     ((get (out :points) "B") :x)))))
  (t/ok (> (spread wide) (spread narrow)) "wider labels sit further apart"))

#
# Through the seam, which is how the server reaches it.
#

(defn- sample []
  {:nodes [{:name "Otto_App" :label "Otto/\nApp" :ours true}
           {:name "Otto_View" :label "Otto/\nView" :ours true}
           {:name "SwiftUI" :label "SwiftUI" :ours false}]
   :edges [["Otto_View" "Otto_App"] ["SwiftUI" "Otto_View"]]
   :sizes {"Otto_App" 120 "Otto_View" 1300}
   :ours {"Otto_App" true "Otto_View" true}})

(t/test "layered is what a config that says nothing gets"
  (def [ok svg] (layout/draw (sample)))
  (t/ok ok)
  (t/ok (string/find "<svg" svg))
  (t/ok (string/find "<title>Otto_App</title>" svg) "a node keeps its name")
  (t/ok (string/find "<title>Otto_View-&gt;Otto_App</title>" svg)
        "and an edge is titled from-&gt;to, which is what web/app.js reads"))

(t/test "the force layout still draws through the same seam"
  (def [ok svg] (layout/draw (sample) {:layout "force"}))
  (t/ok ok)
  (t/ok (string/find "<title>Otto_App</title>" svg)))

(t/test "an unknown layout names the ones that exist"
  (def [ok why] (layout/draw (sample) {:layout "graphviz"}))
  (t/ok (not ok) "graphviz is gone and saying so is the whole message")
  (t/ok (string/find "force" why))
  (t/ok (string/find "layered" why)))

(t/test "a multi-line label becomes one tspan per line"
  (def [_ svg] (layout/draw (sample)))
  (t/ok (string/find "<tspan" svg))
  (t/ok (string/find ">Otto/<" svg) "the path segment keeps its separator")
  (t/ok (string/find ">App<" svg)))

(t/test "a group becomes a box only in the layered layout"
  (def opts {:groups [{:prefix "Otto_" :color "#ff4d6d"}]})
  (def [_ layered-svg] (layout/draw (sample) opts))
  (t/ok (string/find `class="cluster"` layered-svg)
        "the layered layout keeps members together, so a box means something")
  (def [_ force-svg] (layout/draw (sample) (merge opts {:layout "force"})))
  (t/ok (not (string/find `class="cluster"` force-svg))
        "a box around scattered members would claim a structure that is not there"))

(t/test "a group spanning two layers is one box, not one per layer"
  # A GROUP IS A BOX AROUND SOME NODES and says nothing about layers, so a
  # group whose members sit on two ranks is still one group with one name on
  # it. Banding it per layer made a split group look like two groups.
  (def graph {:nodes [{:name "t_a" :label "t_a" :ours true}
                      {:name "t_b" :label "t_b" :ours true}
                      {:name "other" :label "other" :ours true}]
              # t_b sits a layer below t_a, with `other` on t_b's layer.
              :edges [["t_a" "t_b"] ["t_a" "other"]]
              :sizes {} :ours {"t_a" true "t_b" true "other" true}})
  (def [_ svg] (layout/draw graph {:groups [{:prefix "t_" :color "#ff4d6d"}]}))
  (def rects (peg/match ~(any (+ (* `<rect` (some (if-not ">" 1)) ">" (constant 1)) 1)) svg))
  (t/is= 1 (length rects) "one rect over both layers, not a band each")
  # The <title> names it too, so count the drawn label rather than the text.
  (def labels (peg/match ~(any (+ (* `<text` (some (if-not ">" 1)) `>t_</text>`
                                     (constant 1))
                                  1))
                         svg))
  (t/is= 1 (length (or labels [])) "and it is named once"))

(t/test "a group's box holds its members and nothing else"
  # THE BOX IS A CLAIM. A non-member inside the members' bounding box asserts
  # a membership that is not there, which is the whole reason the renderer
  # used to give up and draw a band per layer instead.
  (def graph {:nodes [{:name "t_a" :label "t_a" :ours true}
                      {:name "t_b" :label "t_b" :ours true}
                      {:name "x1" :label "x1" :ours true}
                      {:name "x2" :label "x2" :ours true}
                      {:name "x3" :label "x3" :ours true}]
              # The group's two members straddle a rank crowded with others.
              :edges [["t_a" "t_b"] ["t_a" "x1"] ["t_a" "x2"] ["t_a" "x3"]]
              :sizes {} :ours {}})
  (def out (layered/place graph
                          {:measure (fn [_] 60)
                           :group-of (fn [n] (when (string/has-prefix? "t_" n) "t_"))}))
  (def points (out :points))
  (defn span [names axis]
    [(min ;(map |((points $) axis) names)) (max ;(map |((points $) axis) names))])
  (def [x0 x1] (span ["t_a" "t_b"] :x))
  (def [y0 y1] (span ["t_a" "t_b"] :y))
  (each other ["x1" "x2" "x3"]
    (def p (points other))
    (t/ok (not (and (<= x0 (p :x) x1) (<= y0 (p :y) y1)))
          (string other " is outside the group's bounding box"))))

(t/test "fill-color fills, and the default outlines"
  (def [_ plain] (layout/draw (sample) {:groups [{:prefix "Otto_" :color "#ff4d6d"}]}))
  (t/ok (string/find `fill="none"` plain))
  (def [_ filled] (layout/draw (sample) {:filled true
                                         :weights {"Otto_App" 0.5}
                                         :groups [{:prefix "Otto_" :color "#ff4d6d"}]}))
  (t/ok (not (string/find `<ellipse cx="0.0" cy="0.0" rx="0.0" ry="0.0" fill="none"` filled))
        "a filled node carries a colour"))

(t/test "no layout renders text a browser cannot read"
  # There is no subprocess left to sanitise for, but the SVG still has to be
  # well-formed XML: a raw & or < in a label would break the whole document.
  (def odd {:nodes [{:name "N" :label "a & b <c>" :ours true}]
            :edges [] :sizes {} :ours {"N" true}})
  (def [ok svg] (layout/draw odd))
  (t/ok ok)
  (t/ok (string/find "a &amp; b &lt;c&gt;" svg))
  (t/ok (not (string/find "b <c>" svg))))

#
# Routing, ranking and the shelf -- what reaching graphviz's picture took.
#

(t/test "an edge spanning layers is threaded through bend points"
  # THE DUMMIES ARE WHAT KEEP AN EDGE OFF THE NODES IT PASSES. A -> D spans
  # three layers, so it gets a bend on each one it crosses rather than a
  # straight line drawn over whatever is in between.
  (def graph {:nodes [{:name "A"} {:name "B"} {:name "C"} {:name "D"}]
              :edges [["A" "B"] ["B" "C"] ["C" "D"] ["A" "D"]]})
  (def out (layered/place graph {:measure (fn [_] 60)}))
  (def route (get (out :routes) ["A" "D"]))
  (t/is= 2 (length route) "one bend per layer crossed")
  (def points (out :points))
  # The bend has to clear the node sharing its layer, or the routing bought
  # nothing: this is the bug the dummy chain exists to fix.
  (each [bx by] route
    (each name ["B" "C"]
      (def p (points name))
      (when (= (p :y) by)
        (t/ok (> (math/abs (- bx (p :x))) 20)
              "the bend sits clear of the node on its layer")))))

(t/test "an edge between adjacent layers gets no bends"
  (def graph {:nodes [{:name "A"} {:name "B"}] :edges [["A" "B"]]})
  (def out (layered/place graph {:measure (fn [_] 60)}))
  (t/ok (empty? (keys (out :routes))) "nothing to route around"))

(t/test "a source drops to meet its children"
  # Longest-path ranking strands every parentless node on layer 0, which put
  # seventeen of this tool's thirty-three nodes in one row and set the width
  # of the whole picture. A node with no parent belongs just above its work.
  (def [layer _] (layered/rank ["A" "B" "C" "late"]
                               [["A" "B"] ["B" "C"] ["late" "C"]]))
  (t/is= 0 (layer "A"))
  (t/is= 2 (layer "C"))
  (t/is= 1 (layer "late") "it sank to just above C rather than staying at 0"))

(t/test "tightening never inverts an edge"
  (def names ["A" "B" "C" "D"])
  (def edges [["A" "B"] ["B" "D"] ["C" "D"]])
  (def [layer _] (layered/rank names edges))
  (each [from to] edges
    (t/ok (< (layer from) (layer to))
          (string "edge " from "->" to " still points down the page"))))

(t/test "a node with no edges goes on the shelf, not in the top rank"
  # It STAYS ON THE GRAPH -- it says "nothing you are looking at uses this"
  # -- but it has no relationships to express, so it does not get to set the
  # width of the rank that does. The shelf sits ABOVE the graph, where it is
  # read on the way in rather than found underneath afterwards.
  (def graph {:nodes [{:name "A"} {:name "B"} {:name "loose"}]
              :edges [["A" "B"]]})
  (def out (layered/place graph {:measure (fn [_] 60)}))
  (def points (out :points))
  (t/ok (not (nil? (points "loose"))) "it is still drawn")
  (t/ok (< ((points "loose") :y) ((points "A") :y))
        "and sits above the topmost connected rank")
  (t/ok (not= ((points "loose") :y) ((points "A") :y))
        "on a row of its own, not folded into rank 0"))

(t/test "a crowded shelf still clears the graph"
  # The shelf wraps into rows, and it is laid out downward from its own top,
  # so a shelf deep enough to need several rows has to be lifted by its own
  # height or its last row lands on rank 0.
  (def loose (map (fn [i] {:name (string "x" i)}) (range 40)))
  (def graph {:nodes [;loose {:name "A"} {:name "B"}] :edges [["A" "B"]]})
  (def out (layered/place graph {:measure (fn [_] 60)}))
  (def points (out :points))
  (def lowest (max ;(seq [i :range [0 40]] ((points (string "x" i)) :y))))
  (t/ok (< lowest ((points "A") :y))
        "even the shelf's bottom row sits above the graph"))

(t/test "the shelf keeps a group's members together"
  # Same claim a group box makes anywhere else: a non-member between two
  # members gets swallowed by the box.
  (def graph {:nodes [{:name "g1"} {:name "x"} {:name "g2"}]
              :edges []})
  (def out (layered/place graph
                          {:measure (fn [_] 60)
                           :group-of (fn [name]
                                       (when (string/has-prefix? "g" name) "G"))}))
  (def row (sorted-by |((get (out :points) $) :x) (keys (out :points))))
  (t/is= ["g1" "g2" "x"] row "the members are adjacent"))

(t/test "the sweep scores a group's members together"
  # THE MECHANISM. Ordering a layer and then shuffling the group together
  # afterwards fixes where the ungrouped nodes go BEFORE the group has taken
  # its slot, so a node whose only edge runs past the group gets stranded on
  # the wrong side of it. Scoring the members as one node seats the group and
  # everything around it in the same decision.
  #
  # `g1` and `g2` have neighbours at opposite ends of the layer above. Scored
  # separately they sort to opposite ends too; scored together they share the
  # median of both and stay adjacent, and `lone` -- whose neighbour is in the
  # middle -- lands between the group and the end rather than inside it.
  (def above @["p0" "p1" "p2" "p3"])
  (def layers @{0 above 1 @["g1" "lone" "g2"]})
  (def up {"g1" ["p0"] "g2" ["p3"] "lone" ["p1"]})
  (def down {})
  (defn group-of [n] (when (string/has-prefix? "g" n) "G"))

  (def apart (layered/order layers (fn [n] (get up n [])) (fn [n] (get down n [])) 1))
  (def together (layered/order layers (fn [n] (get up n [])) (fn [n] (get down n [])) 1
                               group-of))
  (defn spots [row] (seq [[i n] :pairs row :when (group-of n)] i))
  (def far (spots (apart 1)))
  (def near (spots (together 1)))
  (t/is= 2 (- (far 1) (far 0))
         "scored apart, the two members sort to opposite ends")
  (t/is= 1 (- (near 1) (near 0))
         "scored together, they stay side by side"))

(t/test "grouping never leaves two nodes on top of each other"
  # The group passes move nodes outside the usual separation, so this is the
  # invariant that has to survive all of them.
  (def names (map (fn [i] (string (if (even? i) "g" "x") i)) (range 12)))
  (def graph {:nodes (map |{:name $} names)
              :edges (seq [i :range [0 10]] [(names i) (names (+ i 2))])})
  (def out (layered/place graph
                          {:measure (fn [_] 70)
                           :group-of (fn [n] (when (string/has-prefix? "g" n) "G"))}))
  (def points (out :points))
  (def rows @{})
  (eachp [name p] points
    (put rows (p :y) (array/push (or (rows (p :y)) @[]) (p :x))))
  (eachp [_ xs] rows
    (def sorted (sort xs))
    (for i 0 (- (length sorted) 1)
      (t/ok (>= (- (sorted (+ i 1)) (sorted i)) 69)
            "neighbours on a row stay a node apart"))))

# NOT TESTED HERE: the pass that gives back the slack a group's claim opens
# (see `place-x`). Its effect is real and measured -- on this repository's own
# graph it moved `src/watchdog` from 275 units away from `src/term/host` to 94,
# and took the edges crossing the `web` box from two to none -- but every
# minimal graph tried here lays out the same with the pass on or off, so a test
# built on one would assert nothing. It needs a group genuinely narrower on one
# rank than another AND enough of a tail after it for the shove to accumulate,
# which so far only the real graph produces.

#
# `settle` -- the one place separation happens.
#

(t/test "settle keeps the order and the gaps"
  (def w @{"a" 60 "b" 60 "c" 60})
  # All three want the same spot; they spread symmetrically around it.
  (def out (layered/settle ["a" "b" "c"] (fn [_] 0) w 20))
  (t/is= 0 (out "b") "the middle one keeps what it wanted")
  (t/is= -80 (out "a"))
  (t/is= 80 (out "c") "and the others clear it by width + gap"))

(t/test "settle leaves a roomy layer alone"
  (def w @{"a" 60 "b" 60})
  (def out (layered/settle ["a" "b"] (fn [n] (if (= n "a") -100 100)) w 20))
  (t/is= -100 (out "a"))
  (t/is= 100 (out "b") "nothing moves when nothing overlaps"))

(t/test "a fixed node holds its place and the rest give way"
  # A group's member is fixed: its column IS the box, so it is the one thing
  # that may not be traded away.
  (def w @{"a" 60 "g" 60})
  (def out (layered/settle ["a" "g"] (fn [_] 100) w 20 (fn [n] (= n "g"))))
  (t/is= 100 (out "g") "the fixed node kept its position")
  (t/is= 20 (out "a") "and its neighbour moved instead"))

(t/test "a bound survives a merge"
  # THE BUG THIS EXISTS FOR. The bounds were combined with a `cond` that read
  # as four clauses rather than three, so a pair with either side missing
  # answered nil and the bound vanished -- which held while every block was
  # one node and stopped holding the moment two merged. A node with a hard
  # floor against a group's box sat inside it anyway.
  (def w @{"a" 60 "b" 60})
  (def out (layered/settle ["a" "b"] (fn [_] 0) w 20 nil
                           (fn [n] (when (= n "b") 500))))
  (t/ok (>= (out "b") 500) "the floor held even though the two blocks merged")
  (t/ok (<= (+ (out "a") 30 20) (- (out "b") 30)) "and they are still apart")
  (def ceil (layered/settle ["a" "b"] (fn [_] 0) w 20 nil nil
                            (fn [n] (when (= n "a") -200))))
  (t/ok (<= (ceil "a") -200) "a ceiling survives it too"))

(t/test "no layer comes out overlapping, whatever is asked of it"
  # The property the whole arrangement exists for: passes say what they want
  # and `settle` decides, so non-overlap is a property of the output rather
  # than of the order the passes ran in.
  (def names (map |(string "n" $) (range 12)))
  (def w (table ;(mapcat |[$ 70] names)))
  # Everything wants the same place, half of it is fixed there, and two have
  # bounds that contradict each other.
  (def out (layered/settle names (fn [_] 0) w 20
                           (fn [n] (find |(= $ n) ["n3" "n7"]))
                           (fn [n] (when (= n "n5") 400))
                           (fn [n] (when (= n "n5") -400))))
  (def sorted (sorted-by |(out $) names))
  (for i 0 (- (length sorted) 1)
    (t/ok (>= (- (out (sorted (+ i 1))) (out (sorted i))) 69.9)
          "neighbours stay a node apart")))

(t/test "a real node wins a near-tie with a bend"
  # A bend's median comes from the ONE chain link it has, so it is exact; a
  # real node's is the average of everything it touches, and a single
  # unrelated neighbour off to one side drags it half a position. `src/scan`
  # scored 8.5 from links at 7 and 10 while the `src/json -> src/graph` bend
  # scored exactly 8, so the bend sorted ahead of it by half a slot and got
  # pushed out the far side -- its bend landed ninety units from the straight
  # line between its own ends and the edge took the long way round.
  #
  # Half a position is not a real preference, so the node keeps the slot.
  # Reproduced here: the bend's link is at 1, the node's links average 1.5,
  # and the node starts ahead -- so without the nudge the bend jumps it.
  (def layers @{0 @["p0" "p1" "p2"] 1 @["node" "bend"]})
  (def up {"bend" ["p1"] "node" ["p1" "p2"]})
  (defn order-with [bend?]
    ((layered/order layers (fn [n] (get up n [])) (fn [_] []) 1 nil bend?) 1))
  (t/is= ["bend" "node"] (order-with nil)
         "scored plainly, the exact median sorts first")
  (t/is= ["node" "bend"] (order-with (fn [n] (= n "bend")))
         "as a bend, it yields the slot and routes past instead"))
