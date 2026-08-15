# The v language: a dependency graph as entity-attribute-value triples.
#
# WHY NOT DOT. DOT is a language for describing *drawings* -- ports, splines,
# rankdir, peripheries, HTML-like labels, a hundred attributes that exist
# because graphviz can draw a hundred things. We draw one thing: a dependency
# graph. Everything DOT offers past that is surface we would have to keep
# generating correctly and never read back. And it is a foreign syntax in a
# tree written in a lisp: emitting DOT meant quoting rules, identifier
# sanitising (`demo-api` -> `demo_api`, see scan/safe-name), and a parser we
# would never write because the text only ever went one way -- out, to a
# subprocess.
#
# WHY NOT NESTING, which is what v was first. The obvious lisp move is to make
# a group a form that CONTAINS its members:
#
#     (group ~.Otto "#ff4d6d" (node Otto_View "Otto/View"))
#
# It reads well and it is wrong, because it asserts a hierarchy the data does
# not have. Membership here is many-to-many and layer-crossing: a group's
# members land on whatever ranks the ranking pass gives them, which is why
# svg/draw has to draw ONE BOX PER LAYER rather than one around the lot. The
# parens claimed a containment the renderer already knew was a lie. And the
# tree was destroyed on read anyway -- `parse` flattened members straight back
# into one node list -- so the nesting was a shape that no consumer ever read
# as a shape.
#
# SO A FACT IS A TRIPLE: an entity, an attribute, a value.
#
#     (group ~.Otto :color "#ff4d6d")
#     (node Otto_App :label "Otto/\nApp" :ours :size 120)
#     (node Otto_View :label "Otto/\nView" :ours :size 1300 :group ~.Otto)
#     (edge Otto_View Otto_App)
#
# AND THERE IS NO `(graph ...)` WRAPPER ANY MORE. It existed to be the root
# of a tree, and a flat list of facts has no root -- wrapping one would be
# re-introducing the nesting this file just argued out of existence, for a
# pair of parens that says nothing. A v file IS its rows.
#
# Every one of those lines is sugar for a set of triples, and the triples are
# the language:
#
#     Otto_App   label  "Otto/\nApp"
#     Otto_App   ours   true
#     Otto_App   size   120
#     Otto_View  group  ~.Otto
#     ~.Otto     color  "#ff4d6d"
#
# WHAT THAT BUYS. Membership becomes an attribute rather than a position, so
# a node in two groups is expressible instead of unsayable. There are no
# positional rules left to get wrong -- the old reader had to know that the
# first bare word after a group name was its colour UNLESS it started with
# `#`, and that the first positional on a node was its label unless there
# wasn't one. And an attribute this version has never heard of is a row to
# carry rather than a subtree to drop, which is forward compatibility that
# costs nothing and loses nothing.
#
# THE FORMS ARE SUGAR, NOT THE MODEL. One-fact-per-line is honest and
# miserable to hand-write at forty nodes, so `(node X :label "..." :size 3)`
# collapses the rows that share an entity. `triples` is the seam: it turns
# text into rows, and `parse` builds a graph out of rows. A caller that wants
# the facts rather than the picture stops at the first one.
#
# IT ROUND-TRIPS, and that is the point of having a language rather than a
# serialiser. `render` writes a graph as v text; `parse` reads it back to the
# same graph. That makes the text a real interchange format -- an agent can
# read it, a human can hand-write one, a test can state a graph as source --
# rather than a write-only string on its way to a subprocess.
#
# THE PEG IS THE SPEC. There is no second description of the syntax to drift
# from it. `grammar` below is the language.

(import ./color)
(import ./select)

# The font a layout uses when the config names none. No longer a fontconfig
# family name that a subprocess has to resolve -- this goes into an SVG
# `font-family`, so the browser resolves it and a missing font falls back
# per the CSS rules rather than silently inside graphviz.
(def default-font "Comic Sans MS")

#
# The grammar.
#

(def grammar
  ``The v language, as a PEG.

  Captures a flat list of forms, each form a list of its atoms. Whitespace
  and `;` comments are skipped everywhere between tokens.

  FLAT, NOT NESTED, and that is the change: a form is a head and its atoms,
  and no form contains another. What used to be nesting is now an attribute
  on the member (`:group ~.Otto`), so the grammar loses its one recursive
  rule and with it every question about what a sub-form inside a sub-form
  would have meant.

  A BARE WORD is anything that is not a delimiter, quote, or space -- so
  `~.Otto`, `#ff4d6d`, `Otto_App` and `demo-api` are all one token and none
  of them need escaping. That is the escaping problem gone rather than
  solved: DOT needed `safe-name` because a hyphen is a syntax error in a
  bare identifier, and here it simply is not.

  A STRING is double-quoted with backslash escapes, for labels -- which are
  the only place a space or a newline appears.``
  ~{:space (any (+ (set " \t\r\n") (* ";" (any (if-not "\n" 1)))))
    # A quoted string, with \" \\ and \n understood. The capture is the
    # DECODED text: a label arrives here already carrying real newlines.
    :string (* "\""
               (/ (% (any (+ (/ "\\n" "\n")
                             (/ "\\t" "\t")
                             (* "\\" (<- 1))
                             (<- (if-not (set "\"\\") 1)))))
                  ,|$)
               "\"")
    # A keyword: :ours, :size. This is what names an ATTRIBUTE now, so it is
    # kept distinct from a bare word -- a flag can never be mistaken for an
    # entity name, and an entity name can never be read as an attribute.
    :keyword (/ (* ":" (<- (some (if-not (set " \t\r\n()\";") 1))))
                ,keyword)
    # A number, so :size 120 arrives as a number rather than a string.
    :number (/ (<- (* (? "-") (some :d) (? (* "." (some :d)))))
               ,scan-number)
    :word (<- (some (if-not (set " \t\r\n()\";") 1)))
    :atom (+ :string :keyword :number :word)
    :form (/ (* "(" :space (any (* :atom :space)) ")")
             ,|(tuple ;$&))
    :main (* :space (any (* :form :space)) -1)})

(def- compiled (peg/compile grammar))

#
# Text to triples.
#

(defn- attributes
  ``The keyword-tagged attributes on a form, as [attribute value] pairs.

  `:ours` is a bare flag and its value is true; `:size 120` takes the value
  after it. Order is preserved, because a repeated attribute is a real thing
  to say and the last one should win the same way it would in a table.``
  [items]
  (def out @[])
  (var i 0)
  (while (< i (length items))
    (def item (items i))
    (if (keyword? item)
      (let [next-item (get items (+ i 1))]
        # A keyword followed by a non-keyword takes it as its value; a
        # keyword followed by another keyword (or nothing) is a bare flag.
        (if (and next-item (not (keyword? next-item)))
          (do (array/push out [item next-item]) (+= i 2))
          (do (array/push out [item true]) (+= i 1))))
      (++ i)))
  out)

(defn- positionals
  "The atoms of a form that are not attributes or their values."
  [items]
  (def out @[])
  (var i 0)
  (while (< i (length items))
    (def item (items i))
    (if (keyword? item)
      # Skip the keyword and, when it took one, its value.
      (let [next-item (get items (+ i 1))]
        (if (and next-item (not (keyword? next-item))) (+= i 2) (+= i 1)))
      (do (array/push out item) (++ i))))
  out)

(defn triples
  ``Read v text into a flat list of [entity attribute value] rows.

  Returns [true rows] or [false message]. THIS IS THE LANGUAGE; `parse`
  below is one consumer of it, the one that builds the graph a layout wants.
  A caller after the facts rather than the picture stops here.

  Three heads desugar, and every one of them produces rows and nothing else:

    (node N :label "L" :ours :size 3)  ->  [N label "L"] [N ours true] ...
    (group G :color "#fff")            ->  [G color "#fff"]
    (edge A B)                         ->  [A edge-to B]

  `edge` is the one row whose VALUE is an entity, which is what makes this a
  graph rather than a table. Anything else is a fact about one thing.``
  [text]
  (def forms (try (peg/match compiled text) ([_] nil)))
  (if-not forms
    [false "not valid v: the text does not parse"]
    (do
      (def rows @[])
      (var problem nil)

      (each form forms
        (def head (when (and (indexed? form) (> (length form) 0))
                    (let [h (first form)] (when (string? h) h))))
        (def rest (slice form 1))
        (def bare (positionals rest))
        (case head
          "node"
          (let [name (string (get bare 0 ""))]
            (if (empty? name)
              (set problem "a (node) form with no name")
              (do
                # A node exists whether or not it says anything else, so the
                # bare fact of it is a row too -- otherwise `(node Solo)`
                # would parse to nothing at all.
                (array/push rows [name :node true])
                (each [a v] (attributes rest)
                  (array/push rows [name a v])))))

          "group"
          (let [name (string (get bare 0 ""))]
            (if (empty? name)
              (set problem "a (group) form with no name")
              (do
                (array/push rows [name :group-decl true])
                (each [a v] (attributes rest)
                  (array/push rows [name a v])))))

          "edge"
          (let [ends (filter string? bare)]
            (if (< (length ends) 2)
              (set problem "an (edge) form needs two node names")
              (array/push rows [(string (ends 0)) :edge-to (string (ends 1))])))

          # A bare `(graph)` is accepted and says nothing. Older v files
          # wrapped everything in one, and while the nested body inside such
          # a file will no longer parse at all, an empty wrapper is a fact-
          # free line and there is no reason to die on it.
          "graph" nil

          # A head we do not know is skipped rather than fatal, for the same
          # reason an unknown attribute is: forward compatibility costs
          # nothing here and a hard error costs the whole picture. It is a
          # cheaper promise to keep now than it was under nesting, where
          # skipping a form meant silently dropping everything inside it.
          nil))

      (if problem [false problem] [true rows]))))

#
# Triples to a graph.
#

(defn parse
  ``Read v text into a graph: {:nodes :edges :sizes :ours :groups}.

  Returns [true graph] or [false message]. A parse failure is a value, not
  an exception, because the caller is a render path that already answers in
  that shape and a malformed graph should reach the page as a message rather
  than as a stack trace.

  THE SHAPE IS UNCHANGED from the nested version, deliberately: `layered`,
  `force` and `svg` read this table and none of them should have to care
  that the text behind it became triples.

  GROUPS COME BACK TOO, with the colour they were declared with. The config
  is still where groups are DECLARED, but a v file that carries them can be
  read back into the same picture -- and now membership rides on the member
  (`:group ~.Otto`) rather than on where the node sat in a tree, so a group
  whose members land on four different layers says exactly what it means.``
  [text]
  (def [ok rows] (triples text))
  (if-not ok
    [false rows]
    (do
      (def nodes @[])
      (def seen @{})       # name -> its index in `nodes`, so rows can accrete
      (def edges @[])
      (def sizes @{})
      (def ours @{})
      (def group-order @[])
      (def group-color @{})
      (def claimed @{})    # node name -> the group named on it

      (defn touch-node [name]
        (unless (seen name)
          (put seen name (length nodes))
          (array/push nodes @{:name name :label name :ours false})))

      (defn note-group [name]
        (unless (find |(= $ name) group-order)
          (array/push group-order name)))

      (each [entity attribute value] rows
        (case attribute
          :node (touch-node entity)
          :group-decl (note-group entity)
          :edge-to (do (touch-node entity)
                       (touch-node (string value))
                       (array/push edges [entity (string value)]))
          :label (do (touch-node entity)
                     (put (nodes (seen entity)) :label (string value)))
          :ours (do (touch-node entity)
                    (put (nodes (seen entity)) :ours (truthy? value))
                    (if (truthy? value) (put ours entity true) (put ours entity nil)))
          :size (do (touch-node entity) (put sizes entity value))
          :group (do (touch-node entity)
                     (note-group (string value))
                     (put claimed entity (string value)))
          # A colour belongs to whichever entity carries it, which for a
          # `(group G :color ...)` row is the group.
          :color (do (note-group entity) (put group-color entity (string value)))
          # An attribute we do not understand is carried in the node's table
          # rather than dropped, so a v file written by a newer version of
          # this tool still draws -- minus whatever the extra meant.
          (do (touch-node entity)
              (put (nodes (seen entity)) attribute value))))

      [true {:nodes (map |(table/to-struct $) nodes)
             :edges edges
             :sizes sizes
             :ours ours
             :groups (map (fn [name]
                            {:prefix name
                             :color (or (group-color name) color/ungrouped)})
                          group-order)
             # Membership as read off the members, for a caller that wants to
             # know what the TEXT said rather than re-derive it from prefixes.
             :claimed claimed}])))

#
# Writing.
#

(defn- quoted
  "A string as a v literal: double quotes, with escapes for what breaks one."
  [text]
  (def out @"\"")
  (each byte (string text)
    (cond
      (= byte (chr "\"")) (buffer/push-string out "\\\"")
      (= byte (chr "\\")) (buffer/push-string out "\\\\")
      (= byte (chr "\n")) (buffer/push-string out "\\n")
      (= byte (chr "\t")) (buffer/push-string out "\\t")
      (buffer/push-byte out byte)))
  (buffer/push-string out "\"")
  (string out))

(defn- node-form
  ``One node as a v form: the entity, then every attribute it carries.

  The attributes go out in a fixed order -- label, ours, size, group -- so
  the same graph writes the same bytes every time and a diff of two v files
  is a diff of what changed rather than of what got iterated first.``
  [node sizes group]
  (def name (node :name))
  (def parts @[(string "(node " name " :label " (quoted (or (node :label) name)))])
  (when (node :ours) (array/push parts " :ours"))
  (when (sizes name) (array/push parts (string " :size " (sizes name))))
  (when group (array/push parts (string " :group " group)))
  (array/push parts ")")
  (string/join parts))

(defn render
  ``A graph as v text.

  `opts` carries what the config decided -- :groups is the only key that
  affects what comes out, and it now does so by writing a `:group` ATTRIBUTE
  on each claimed node rather than by moving that node inside a box. Colour,
  fill and font are decisions a LAYOUT makes from the graph, not facts about
  the graph, so they do not appear here.

  THIS IS WHERE DOT AND V DIVERGE MOST. `dot/render` baked the whole visual
  decision -- fillcolor, fontcolor, style, shape -- into the text, because
  the text was the last chance to say anything before graphviz took over.
  Here the text says what the graph IS and the layout decides how it looks,
  which is why `(layout force)` and the layered layout can differ without
  either of them re-parsing attributes meant for the other.``
  [graph &opt opts]
  (default opts {})
  (def groups (or (opts :groups) []))
  (def ours (or (graph :ours) {}))
  (def sizes (or (graph :sizes) {}))

  # `select/group-for` is the one test, and it understands `~`. Duplicating a
  # plain prefix check here would claim a node for a group the rest of the
  # tree does not think it belongs to.
  (defn group-for [name] (select/group-for name groups ours))

  (def out @[])

  # Group declarations first, so a reader meets a group's colour before it
  # meets a node claiming membership in it. Nothing REQUIRES that order --
  # rows accrete in any sequence, which is the point of triples -- but a
  # file is read top to bottom by people.
  (each g groups
    (array/push out (string "(group " (g :prefix) " :color " (quoted (g :color)) ")")))

  # Then every node, in the graph's own order. Unlike the nested version
  # there is no bucketing into boxed-and-loose: a node's group is something
  # it SAYS, so the nodes come out in the order they came in.
  (each node (graph :nodes)
    (def claimed (group-for (node :name)))
    (array/push out (node-form node sizes (when claimed (claimed :prefix)))))

  # Edges last. There is no ordering requirement -- an edge may reference a
  # node declared later, since a row naming an unknown entity simply creates
  # it -- but keeping them together makes a hand-read file readable.
  (each [a b] (graph :edges)
    (array/push out (string "(edge " a " " b ")")))

  (string/join out "\n"))
