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

(defn fold
  ``Fold everything under each prefix into one node.

  `(fold src.visualize.parsers)` replaces the seven parser files with a
  single node called `src.visualize.parsers`, wearing every edge any of them
  had. What a folded region depends on, and what depends on it, is exactly
  what its members did -- so the picture keeps saying the same thing about
  the rest of the graph while saying less about the inside of one part.

  EDGES BETWEEN MEMBERS GO. Two parsers that import each other are one node
  now, and an arrow from a node to itself says nothing that the fold did
  not already say. Edges to the outside are kept, deduplicated: five files
  importing `scan` is one arrow once they are one node.

  THE LINE COUNT ADDS UP. A folded node stands for its members, so it
  carries what they carried -- `(lines)` on a folded parsers box reads the
  size of the directory, which is the number that is true of the thing now
  drawn.

  A PREFIX HOLDING ONE NODE LEAVES IT ALONE. Folding a single thing into
  itself changes only its name, which is a rename nobody asked for -- and
  the point of collapsing is to say less about a region's inside, which a
  region of one already does.``
  [graph prefixes sizes]
  (if (empty? prefixes)
    [graph sizes]
    (let [ours (get graph :ours {})
          tests (map |[(expand $) (selector $ ours)] prefixes)
          # Which prefix swallows a node, if any. FIRST MATCH by declaration
          # order, like the boxes -- two folds that overlap would
          # otherwise fold a node into both and draw it twice.
          folded-into (fn [name]
                        (var out nil)
                        (each [prefix test] tests
                          (when (and (nil? out) (test name)) (set out prefix)))
                        out)]

      # The nodes that survive: everything not folded, plus one per prefix
      # that actually swallowed something.
      # Members first, so a prefix holding only one can be put back.
      (def members @{})
      (each node (get graph :nodes [])
        (when-let [into (folded-into (node :name))]
          (put members into (array/push (or (members into) @[]) node))))
      (def made @{})
      (eachp [prefix group] members
        (when (> (length group) 1) (put made prefix group)))

      (def kept @[])
      (each node (get graph :nodes [])
        (def into (folded-into (node :name)))
        (unless (and into (made into)) (array/push kept node)))

      (def nodes @[])
      (each node kept (array/push nodes node))
      (eachp [prefix members] made
        (array/push nodes
                    {:name prefix
                     :label (string/join (string/split "." prefix) ".\n")
                     # SAYS IT IS A FOLD, so the drawing can show it. A folded
                     # node looks like any other -- one ellipse with a name --
                     # and nothing about it says it stands for seven files
                     # rather than being one. The page hatches it; see the
                     # stripes in style.css.
                     :folded true
                     # Ours if anything inside it was: a folded region of
                     # your own files is still yours.
                     :ours (truthy? (find |($ :ours) members))}))

      # Sizes follow their nodes. A folded one adds up what it stands for.
      # A name maps to its stand-in, but only where one was actually made.
      (def stands-for
        (fn [name]
          (def into (folded-into name))
          (if (and into (made into)) into name)))

      (def out-sizes @{})
      (eachp [name n] (or sizes {})
        (def into (folded-into name))
        (unless (and into (made into)) (put out-sizes name n)))
      (eachp [prefix members] made
        (var total 0)
        (each m members (+= total (get (or sizes {}) (m :name) 0)))
        (when (> total 0) (put out-sizes prefix total)))

      (def pairs @{})
      (each [from to] (get graph :edges [])
        (def a (stands-for from))
        (def b (stands-for to))
        # An arrow from a node to itself is what an edge between two members
        # becomes, and it says nothing the fold did not.
        (unless (= a b) (put pairs [a b] true)))

      [(merge graph {:nodes (sorted-by |($ :name) nodes)
                     :edges (sorted (keys pairs))})
       out-sizes])))

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

(defn boxes-for
  ``Every box this node falls inside, widest first.

  BOXES NEST. `(box api)` and `(box api.v1)` are not rivals for the same
  node -- the second is inside the first, and a node under both is drawn in
  both. Sorted by the length of what they match, so the list reads outermost
  to innermost and the renderer can nest them in that order.

  The EMPTY prefix is widest of all: it means "ours", so a box declared over
  it contains every one of your files and any box inside it.``
  [name groups ours]
  (def inside (filter (fn [g] (matches? name (expand (g :prefix)) ours)) groups))
  (sorted-by |(length (expand ($ :prefix))) inside))

(defn group-for
  ``The innermost box claiming this node, or nil.

  What a node's own colour comes from: the narrowest box it is in is the one
  that says something about it, where the outer ones say something about a
  region.``
  [name groups ours]
  (last (boxes-for name groups ours)))

(defn alias-label
  ``A node name written the shortest way a config could say it, or nil.

  The mirror of `expand-aliases`: with `~` bound to `src.visualize`, the node
  `src.visualize.color` LABELS itself `~.color`, so the picture reads in the
  same vocabulary the config is written in. Longest prefix first, again --
  the alias that covers most of the name is the one that shortens it most.``
  [aliases name]
  (var out nil)
  (each entry aliases
    (unless out
      (def full (entry :prefix))
      (cond
        (= name full) (set out (entry :alias))
        (string/has-prefix? (string full ".") name)
        (set out (string (entry :alias) (string/slice name (length full)))))))
  out)

(defn resolve
  ``Answer every question the config asks about a node, once, on the node.

  THE RENDERER READS FIELDS, NOT CONFIG. A drawing needs to know four things
  about a node -- what to call it, which box it is in, what colour, whether
  it is flashing -- and each of those is a question the config answers. Asked
  here, the renderer needs no opinion about prefixes and no import of this
  file; asked there, every renderer has to learn the config language over
  again, and `group-for` gets run three times over the same nodes because
  nowhere is the obvious place to remember the answer.

  Adds to each node:

    :box     the prefix of the INNERMOST box it is in, or nil
    :boxes   every box it is in as {:prefix :colour}, widest first
    :colour  the box's colour, or the ungrouped one
    :ink     that colour deepened until it reads against the page
    :fill    that colour tinted, for the flash
    :fresh   true when its file moved since the last drawing

  EXACT COLOURS, not a hue to derive them from. The renderer used to take
  the hue and ask the palette for its ink and its tint, which meant a module
  that writes DOT had to import a module that does contrast arithmetic.
  Resolved here, every colour on the node is a string the renderer prints.

  `palette` supplies the three answers this cannot compute: the ungrouped
  colour, and the two derivations. Passed in rather than imported, so the
  only module that knows what a colour IS is the one that owns them.

  Leaves :name and :label alone -- identity and text are already right by
  the time this runs.``
  [graph groups flashing palette]
  (def ours (get graph :ours {}))
  (def ungrouped (palette :ungrouped))
  (def ink (palette :ink))
  (def tint (palette :tint))
  (merge graph
         {:nodes (map (fn [node]
                        (def inside (boxes-for (node :name) groups ours))
                        (def claimed (last inside))
                        (def hue (if claimed (claimed :color) ungrouped))
                        (merge node
                               {:box (when claimed (claimed :prefix))
                                # Every box it is in, widest first, for the
                                # renderer to nest. Each carries its OWN
                                # colour: an outer box may hold nothing but
                                # inner boxes, so its hue cannot be read off
                                # a node -- those wear the inner box's.
                                :boxes (map |{:prefix ($ :prefix)
                                              :colour ($ :color)} inside)
                                :colour hue
                                :ink (ink hue)
                                :fill (tint hue)
                                :fresh (truthy? (get flashing (node :name)))}))
                      (get graph :nodes []))}))
