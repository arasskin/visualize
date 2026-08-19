# What the config language MEANS: which nodes it selects, and how shaded they
# come out.
#
# The verbs are parsed in src/visualize/config.janet and drawn in
# src/visualize/layout.janet; this is the middle, where `(hide src.test)`
# becomes a set of nodes that are no longer on the graph. Three jobs, in the
# order the file has them: matching a name against a prefix, filtering the
# graph by those matches, and weighting what survives for colour.
#
# ALL OF IT WORKS ON THE STRUCTURE, never on rendered text. An earlier version
# did this by regex over DOT source, because the graph arrived as a finished
# string and there was nothing else to work on; here the scan is ours, so
# hiding, boxing and colouring happen on the graph and nothing has to parse
# back what it just printed.

(import ./color)

(defn- flatten-separators
  ``A config name as the node-name prefix it selects.

  Node names are dotted -- `src.visualize.color` -- and so are labels, so a
  config name is usually already in the right shape and this only trims the
  edges. A slash is accepted and converted because a path is a natural thing
  to type and there is no reason to refuse it.``
  [text]
  (string/replace-all "/" "." (string/trim text "./")))

(defn expand
  ``A config name as the node-name prefix it selects.

  A name is the dotted path, and every name is literal: `src.visualize` is
  that directory, `src.visualize.color` is that file, and `SwiftUI` is the
  external -- which is what lets an import be grouped and hidden like any
  other node.

  NO TOKEN IS SPECIAL HERE. `~` is whatever `(prefix ~ src.visualize)` bound
  it to, and config.janet has already expanded it by the time a name reaches
  this function -- so this sees paths and nothing else.

  The one shape with meaning of its own is the EMPTY prefix, which is
  "everything of ours": `matches?` reads it by membership rather than as a
  string test, so `(only "")` keeps your files and drops the externals.``
  [name]
  (def text (string/trim name))
  (cond
    (empty? text) ""
    (flatten-separators text)))

(defn matches?
  ``Does this node match this prefix?

  Everything is prefix-matched except the EMPTY prefix, which means "ours" --
  a set membership test rather than a string one. Without that case
  `(only "")` would match every node, since every string starts with the
  empty string, and mean nothing at all.``
  [name prefix ours]
  (if (empty? prefix)
    (truthy? (ours name))
    (string/has-prefix? prefix name)))

(defn- selector
  ``One config name as a predicate over node names.

  A TRAILING DOT means "the contents, not the thing itself":

      (hide src.visualize)     the directory and every file in it
      (hide src.visualize.)    the files only

  That is a longer prefix rather than a special case -- contents-only matches
  `src.visualize.`, with the separator that goes between a directory and its
  files. For a directory the two are nearly the same thing, since there is no
  node for the directory itself; the form is kept because `(hide src.)` hides
  src/'s files while leaving a sibling `srcgen` alone, which a plain prefix
  cannot express.``
  [name ours]
  (def contents-only (string/has-suffix? "." (string/trim name)))
  (var prefix (expand name))
  # The empty prefix means OURS. A trailing dot cannot make it longer, and
  # appending one would turn "everything of ours" into a literal dot that
  # matches nothing.
  (when (and contents-only (not (empty? prefix)))
    (set prefix (string prefix ".")))
  (fn [node] (matches? node prefix ours)))

(defn keep
  ``Keep only the nodes under some prefixes, and the edges between them.

  Nothing declared means no filter at all -- so a config that says nothing
  shows the externals too, which is the only way to see what a project
  actually links against. `(only "")` gives back just our own files.

  A node survives if it matches ANY prefix; an EDGE survives only if BOTH of
  its endpoints do. An edge to a node that is no longer drawn would point at
  nothing, and graphviz would rank the drawing against a node nobody can
  see.``
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

  A property of the graph rather than of a drawing, so it lives with the
  other graph functions and the renderer asks for it.``
  [graph]
  (color/ramp (degrees graph)))

(defn group-for
  ``Which group claims this node, if any.

  FIRST MATCH WINS when groups overlap, so a narrow group declared before a
  broad one still gets its own box rather than being swallowed.``
  [name groups ours]
  (find (fn [g] (matches? name (expand (g :prefix)) ours)) groups))
