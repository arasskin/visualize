# Prefix matching and the filtering the config can apply to a graph.
#
# WAS src/dot.janet, which held two unrelated jobs: these transforms, and
# generating DOT text for a subprocess. The second is gone -- see src/v.janet
# for the language that replaced it -- and what is left is what the config
# language actually does, which is choose which of the scanned nodes you
# wanted to look at.
#
# All of it works on the STRUCTURE, never on rendered text. The originals did
# this by regex over DOT source, because pydeps handed them a finished string
# and there was nothing else to work on; here the scan is ours, so hiding,
# grouping and colouring happen on the graph and nothing has to parse back
# what it just printed.
#
# Prefix matching is the whole config language, and `~` is the one special
# case: see `expand` below.

(import ./color)

(defn- flatten-separators
  ``A config name with every path separator turned into the underscore that
  node names use. `src/test`, `src.test` and `src_test` all arrive as
  `src_test`, so a config can be written the way the label reads.``
  [text]
  (string/replace-all "/" "_"
                      (string/replace-all "." "_" (string/trim text "./"))))

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
    # SLASHES AND DOTS BOTH, because a node shows one and this used to
    # accept only the other. A label reads `src/test` -- that is the path,
    # wrapped a segment per line -- while the node's IDENTITY is the
    # flattened `src_test`, and a config could only say `src.test`. The dots
    # came from pydeps, where a module path really is dotted; for a file tree
    # they are a translation nobody asked for, and a reader who types what
    # the picture shows deserves a match rather than silence.
    (string/has-prefix? "~." text) (flatten-separators (string/slice text 2))
    (flatten-separators text)))

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
  its endpoints do. An edge to a node that is no longer drawn would point at
  nothing -- and in the layered layout, would rank against a node that is not
  on the page.``
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

(defn weights-for
  ``The default shading: how entangled each node is, ranked.

  Was computed inside the DOT renderer, where it was one more thing the text
  generator knew about. It is a property of the graph, so it lives with the
  other graph functions and the layouts ask for it.``
  [graph]
  (color/ramp (degrees graph)))

(defn thousands
  ``A line count as a label: 240, 1000, 1300.

  Written out in full. The abbreviated form this used to print -- 1.3k for
  1300 -- rounded away the difference between files a hundred lines apart,
  which is exactly the comparison the number is on the box to support.``
  [count]
  (string count))

(defn group-for
  ``Which group claims this node, if any.

  FIRST MATCH WINS when groups overlap, so a narrow group declared before a
  broad one still gets its own box rather than being swallowed.``
  [name groups ours]
  (find (fn [g] (matches? name (expand (g :prefix)) ours)) groups))
