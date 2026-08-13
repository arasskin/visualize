# The graph, as DOT, and every transformation the config can apply to it.
#
# The scan produces a graph structure; this file turns it into the text
# graphviz lays out. The originals did all of this by regex over DOT SOURCE
# TEXT, because pydeps handed them a finished string and there was nothing
# else to work on. Here the scan is ours, so the hiding, grouping and
# colouring happen on the STRUCTURE and the DOT is generated once at the end,
# already correct. Nothing has to parse back what it just printed.
#
# Prefix matching is the whole config language, and `~` is the one special
# case: see `expand` below.

(import ./color)

# Graphviz resolves this through fontconfig, so it has to be a family name the
# system knows. If it is missing graphviz falls back to its default rather
# than failing, so the graph still renders.
(def default-font "Comic Sans MS")

(defn expand
  ``A config name as the node-name prefix it selects.

  `~` IS THE PROJECT, the way a shell expands `~` to a home directory:
  `~.OttoClip` is the OttoClip directory, `~.a.b` is that one file, and `~`
  alone is everything of ours. Every other name is literal, so `SwiftUI` is
  the framework -- which is what lets an external be grouped and hidden like
  any other node.

  `~` alone expands to the EMPTY prefix, and the empty prefix matching
  everything is exactly right for (show-only ~) -- with one catch: it would
  match the externals too. `matches?` below handles that by membership rather
  than by string prefix, which is why this can stay a pure string function.``
  [name]
  (def text (string/trim name))
  (cond
    (empty? text) ""
    (= text "~") ""
    (string/has-prefix? "~." text) (string/replace-all "." "_"
                                                       (string/trim (string/slice text 2) "."))
    (string/replace-all "." "_" (string/trim text "."))))

(defn matches?
  ``Does this node match this prefix?

  Everything is prefix-matched except the empty prefix that `~` expands to:
  that means "ours", which is a set membership test, not a string test.
  Without the special case (show-only ~) would keep the externals as well and
  mean nothing.``
  [name prefix ours]
  (if (empty? prefix)
    (truthy? (ours name))
    (string/has-prefix? prefix name)))

(defn- selector
  ``One config name as a predicate over node names.

  A TRAILING DOT means "the contents, not the thing itself":

      (hide ~.OttoClip)     the directory and every file in it
      (hide ~.OttoClip.)    the files only

  That is a longer prefix rather than a special case -- contents-only matches
  `OttoClip_`, with the separator that goes between a directory and its files.
  For a directory the two are nearly the same thing, since there is no node
  for the directory itself; the form is kept because `(hide ~.Otto.)` hides
  Otto/'s files while leaving OttoClip's alone, which a plain prefix cannot
  express.``
  [name ours]
  (def contents-only (string/has-suffix? "." (string/trim name)))
  (var prefix (expand name))
  # An empty prefix is `~`, which means ours. A trailing dot cannot make it
  # longer, and appending one would turn "everything of ours" into a literal
  # underscore that matches nothing.
  (when (and contents-only (not (empty? prefix)))
    (set prefix (string prefix "_")))
  (fn [node] (matches? node prefix ours)))

(defn keep
  ``Keep only the nodes under some prefixes, and the edges between them.

  Nothing declared means no filter at all -- so a config that says nothing
  shows the externals too, which is the only way to see what a project
  actually links against. (show-only ~) gives back just our own files.

  A node survives if it matches ANY prefix; an EDGE survives only if BOTH of
  its endpoints do. An edge to a node that is no longer drawn would leave
  graphviz inventing a blank box for it.``
  [graph only]
  (if (empty? only)
    graph
    (let [ours (graph :ours)
          tests (map |(selector $ ours) only)
          wanted? (fn [node] (some |($ node) tests))
          nodes (filter |(wanted? ($ :name)) (graph :nodes))]
      (merge graph
             {:nodes nodes
              :edges (filter (fn [[a b]] (and (wanted? a) (wanted? b))) (graph :edges))}))))

(defn drop-nodes
  ``Remove some nodes, and every edge touching them.

  A NODE LEFT WITH NO EDGES STAYS ON THE GRAPH. Hiding the test files takes
  every edge that touched XCTest, and the XCTest box is then drawn on its own.
  That is deliberate: a node with nothing attached says "this is here and
  nothing you are looking at uses it", which is a fact about the picture you
  asked for rather than a defect in it. Sweeping them would also mean a (hide)
  could silently remove a node it was never asked to remove.

  This is where `drop` and `keep` are asymmetric on purpose. `keep` drops an
  edge unless both ends survive, so narrowing cannot leave a half-drawn arrow;
  an orphan is the opposite case, where the node is really there and only its
  edges went.``
  [graph hidden]
  (if (empty? hidden)
    graph
    (let [ours (graph :ours)
          tests (map |(selector $ ours) hidden)
          hidden? (fn [node] (some |($ node) tests))]
      (merge graph
             {:nodes (filter |(not (hidden? ($ :name))) (graph :nodes))
              :edges (filter (fn [[a b]] (not (or (hidden? a) (hidden? b))))
                             (graph :edges))}))))

(defn degrees
  ``How many edges touch each node, in and out together.

  Direction is deliberately ignored: the question the colour answers is "how
  entangled is this file", and something twelve files reference is just as
  central as something referencing twelve.``
  [graph]
  (def counts @{})
  (each node (graph :nodes) (put counts (node :name) 0))
  (each [a b] (graph :edges)
    (when (counts a) (put counts a (+ 1 (counts a))))
    (when (counts b) (put counts b (+ 1 (counts b)))))
  counts)

(defn ramp-of
  ``The brightness ramp for a set of line counts.

  Ranked, not scaled -- see `color/ramp`. File sizes are long-tailed for the
  same reason edge counts are: one 1300-line view against a floor of 40-line
  ones, so a straight ratio would leave everything but the giant looking
  identical.``
  [sizes]
  (color/ramp sizes))

(defn thousands
  ``A line count as a short label: 240, 1k, 1.3k.

  Under a thousand is written out -- 0.2k throws away precision that fits
  anyway. Above it, one decimal, with a bare `1k` rather than `1.0k` since the
  tenth is only worth printing when it says something.``
  [count]
  (if (< count 1000)
    (string count)
    (let [scaled (/ (math/round (/ count 100)) 10)]
      (if (= scaled (math/floor scaled))
        (string (math/floor scaled) "k")
        (string scaled "k")))))

(defn- quoted
  "A string as a DOT literal, with quotes and backslashes escaped.

  Labels already contain a deliberate `\\n`, so only a lone backslash and a
  double quote need protecting."
  [text]
  (string "\"" (string/replace-all "\"" "\\\"" text) "\""))

(defn- group-for
  ``Which group claims this node, if any.

  FIRST MATCH WINS when groups overlap, so a narrow group declared before a
  broad one still gets its own box rather than being swallowed.``
  [name groups ours]
  (find (fn [g] (matches? name (expand (g :prefix)) ours)) groups))

(defn render
  ``The whole graph as DOT text.

  `opts` carries what the config decided: :groups, :filled, :sized,
  :weights, :font.

  Within a box a node's fill is its group's hue at a strength set by
  :weights -- edge count by default, line count under (show-lines-coloring).
  Either way the busiest files read brightest.``
  [graph &opt opts]
  (default opts {})
  (def groups (or (opts :groups) []))
  (def ours (graph :ours))
  (def sizes (or (graph :sizes) {}))
  (def font (or (opts :font) default-font))
  (def filled (opts :filled))
  (def weights (or (opts :weights) (color/ramp (degrees graph))))

  (defn node-line [node indent]
    (def name (node :name))
    (def claimed (group-for name groups ours))
    (def hue (if claimed (claimed :color) color/ungrouped))
    (def weight (or (weights name) 0))
    (def fill (color/tint hue weight))
    (def label
      (if (and (opts :sized) (sizes name))
        (string (node :label) "\\n" (thousands (sizes name)))
        (node :label)))
    (string indent name " ["
            "label=" (quoted label)
            (if filled
              # A solid block of the group's hue.
              (string ",style=filled,fillcolor=" (quoted fill)
                      ",fontcolor=" (quoted (color/ink fill)))
              # OUTLINE ONLY, the default. A wall of saturated boxes is harder
              # to read the EDGES over, and the edges are what a dependency
              # graph is for. fillcolor="none" rather than no fill at all:
              # style=filled is in the node defaults, so a node merely lacking
              # a fillcolor comes out solid black. "none" is also transparent
              # rather than white, which matters -- the page rectangle is
              # hidden in CSS so the graph floats on the pane, and a white node
              # would be a card sitting on top of it.
              (string ",fillcolor=\"none\""
                      ",fontcolor=" (quoted (color/ink-on-page hue))))
            ",color=" (quoted hue)
            "];"))

  (def out @[])
  (array/push out "digraph G {")
  (array/push out "    concentrate=false;")
  # Comic Sans is wider than Helvetica at the same size, so the default
  # ranksep crowds once the labels grow.
  (array/push out (string "    graph [fontname=" (quoted font)
                          ", ranksep=0.6, nodesep=0.35];"))
  (array/push out (string "    edge [fontname=" (quoted font) "];"))
  (array/push out (string "    node [style=filled,fontname=" (quoted font)
                          ",fontsize=10,shape=box];"))

  # Nodes inside their boxes first, then the loose ones, then the edges --
  # clusters have to be declared before the edges that reference them.
  (def boxed @{})
  (def loose @[])
  (each node (graph :nodes)
    (if-let [claimed (group-for (node :name) groups ours)]
      (put boxed (claimed :prefix)
           (array/push (or (boxed (claimed :prefix)) @[]) node))
      (array/push loose node)))

  (each node loose (array/push out (node-line node "    ")))

  (each g groups
    (when-let [members (boxed (g :prefix))]
      # A cluster's name must be unique and DOT-safe; the expanded prefix is
      # both, and it keeps the generated DOT readable. `~` expands to empty,
      # which would collide, so the index disambiguates.
      (def safe (let [p (expand (g :prefix))] (if (empty? p) "all" p)))
      (array/push out (string "    subgraph cluster_" safe " {"))
      (array/push out (string "        label=" (quoted (g :prefix))
                              "; style=rounded; color=" (quoted (g :color)) ";"))
      (array/push out (string "        fontname=" (quoted font)
                              "; fontsize=12; fontcolor=" (quoted (g :color)) ";"))
      (each node members (array/push out (node-line node "        ")))
      (array/push out "    }")))

  (each [a b] (graph :edges)
    (array/push out (string "    " a " -> " b ";")))
  (array/push out "}")
  (string/join out "\n"))

(defn to-svg
  ``Lay the DOT out with graphviz. Returns [ok svg-or-error].

  The one external dependency, and a deliberate one: `dot` is a compiler for
  this tool, not a library to vendor. Its Sugiyama layout is decades of work
  that a hand-rolled one would only approximate.``
  [text &opt cwd]
  (def proc (try
              (os/spawn ["dot" "-Tsvg"] :px
                        {:in :pipe :out :pipe :err :pipe :cd (or cwd (os/cwd))})
              ([_] nil)))
  (if-not proc
    [false "graphviz not found on PATH (brew install graphviz)"]
    (do
      # Written and read CONCURRENTLY. `dot` does not drain its input before
      # it starts producing output, so writing the whole graph and only then
      # reading deadlocks on a large one: the pipe buffer fills, dot blocks
      # writing its SVG, and we block writing the DOT it would need to read
      # first. `ev/gather` runs all three and waits for them together.
      (def collected @"")
      (def errors @"")
      (ev/gather
        (ev/go (fn []
                 # A closed pipe here is not an error worth reporting: it
                 # means dot rejected the graph and exited, and the reason is
                 # already on its way up the stderr fiber.
                 (try
                   (do (:write (proc :in) text) (:close (proc :in)))
                   ([_] nil))))
        (ev/go (fn [] (while (def chunk (:read (proc :out) 65536))
                        (buffer/push-string collected chunk))))
        (ev/go (fn [] (while (def chunk (:read (proc :err) 65536))
                        (buffer/push-string errors chunk)))))
      # `os/proc-wait` THROWS on a non-zero exit rather than returning it, so
      # a graph dot rejects would escape as an exception and the careful error
      # message below would never be reached.
      (def code (try (os/proc-wait proc) ([_] 1)))
      (if (zero? code)
        [true (string collected)]
        [false (let [why (string/trim (string errors))]
                 (if (empty? why) "dot failed" why))]))))
