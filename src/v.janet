# The v language: a dependency graph as entities and their attributes.
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
# A FORM IS AN ENTITY AND WHAT IS TRUE OF IT:
#
#     (e a1 a2 a3 v3 ...)
#
# The first atom names the entity. Everything after it is an attribute, and
# an attribute either stands alone or takes the atom after it:
#
#     (src_color label "src/\ncolor" ours size 187 ~.term)
#
#       src_color  label  "src/\ncolor"
#       src_color  ours   true
#       src_color  size   187
#       src_color  in     ~.term
#
# THE SCHEMA IS WHAT MAKES THAT READABLE. `attributes` below declares every
# attribute this language has and whether it takes a value, so the parser
# never has to guess whether `ours` is a flag or the value of the thing
# before it. That is a closed set on purpose: v describes ONE domain, and an
# attribute nobody declared is a typo, not an extension point.
#
# `label` AND `:label` ARE THE SAME WORD. The colon is spelling. It used to
# be load-bearing -- the only way to tell an attribute from a value -- and
# with a schema it is decoration, so both are accepted and neither is wrong.
#
# EVERYTHING IS AN ENTITY, including the things that used to be forms:
#
#     (~.term color "#ff4d6d")            a group is an entity with a colour
#     (src_color->src_graph from src_color to src_graph)
#
# and a node joins a group by NAMING it -- a bare word that is not a declared
# attribute is an entity reference, which is how `~.term` above reads as a
# membership. That is the last inference in the language and it is decidable
# precisely because the schema is closed.
#
# WHY NOT NESTING, which is what v was first. The obvious lisp move is to
# make a group a form that CONTAINS its members. It reads well and it is
# wrong, because it asserts a hierarchy the data does not have: membership
# here is many-to-many and layer-crossing, which is why svg/draw has to draw
# ONE BOX PER LAYER rather than one around the lot. The parens claimed a
# containment the renderer already knew was a lie -- and the tree was
# flattened on read anyway, so it was a shape no consumer read as a shape.
#
# IT ROUND-TRIPS, and that is the point of having a language rather than a
# serialiser. `render` writes a graph as v text; `parse` reads it back to the
# same graph. That makes the text a real interchange format -- an agent can
# read it, a human can hand-write one, a test can state a graph as source --
# rather than a write-only string on its way to a subprocess.
#
# THE PEG AND THE SCHEMA ARE THE SPEC. `grammar` says what a form looks like
# and `attributes` says what may appear in one. There is no third description
# to drift from either.

(import ./color)
(import ./select)

# The font a layout uses when the config names none. No longer a fontconfig
# family name that a subprocess has to resolve -- this goes into an SVG
# `font-family`, so the browser resolves it and a missing font falls back
# per the CSS rules rather than silently inside graphviz.
(def default-font "Comic Sans MS")

#
# The schema.
#

(def attributes
  ``Every attribute v has, and whether it takes a value.

  :flag  -- stands alone, and its value is true (`ours`)
  :value -- takes the next atom (`size 187`, `label "..."`)

  THIS IS WHY THE PARSER NEVER GUESSES. Without it, `(A ours size 187)` is
  ambiguous: `size` could be the value of `ours` as easily as an attribute
  of its own. With it, `ours` is declared a flag and the question does not
  arise. Adding an attribute to the language is a line here.``
  {:label :value    # what the node draws
   :size  :value    # how many lines the file has
   :color :value    # a group's colour
   :from  :value    # an edge's tail
   :to    :value    # an edge's head
   :ours  :flag})   # is this file part of the project, or a dependency

(defn- attribute-of
  ``The attribute a word names, or nil if it names none.

  `label` and `:label` are the same attribute: the colon is spelling, so it
  is stripped before the lookup rather than distinguishing anything.``
  [word]
  (def name (if (keyword? word) (string word) (string word)))
  (def bare (if (string/has-prefix? ":" name) (slice name 1) name))
  (def as-key (keyword bare))
  (when (attributes as-key) as-key))

#
# The grammar.
#

(def grammar
  ``The v language, as a PEG.

  Captures a flat list of forms, each form a list of its atoms. Whitespace
  and `;` comments are skipped everywhere between tokens.

  FLAT, NOT NESTED, and that is deliberate: a form is an entity and its
  attributes, and no form contains another. What used to be nesting is a
  named entity reference now, so the grammar loses its one recursive rule
  and with it every question about what a form inside a form would mean.

  THE GRAMMAR DOES NOT KNOW THE SCHEMA. It captures atoms; `read-form`
  below decides which are attributes. Keeping the two apart is what lets
  `label` and `:label` be the same word without the PEG caring.

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
    # A number, so `size 187` arrives as a number rather than a string.
    :number (/ (<- (* (? "-") (some :d) (? (* "." (some :d)))))
               ,scan-number)
    # Everything else is one word, colon or no colon.
    :word (<- (some (if-not (set " \t\r\n()\";") 1)))
    :atom (+ :string :number :word)
    :form (/ (* "(" :space (any (* :atom :space)) ")")
             ,|(tuple ;$&))
    :main (* :space (any (* :form :space)) -1)})

(def- compiled (peg/compile grammar))

#
# Text to facts.
#

(defn- read-form
  ``One form as [entity rows], where a row is [attribute value].

  The scan is left to right and the schema decides each step: a declared
  attribute either takes the next atom or stands alone, and anything else
  is an entity this one refers to -- which is how a node names its groups.

  Returns [entity rows problem]; `problem` is a string when the form cannot
  be read at all.``
  [form]
  (if (or (not (indexed? form)) (empty? form))
    [nil nil "an empty form"]
    (do
      (def entity (string (first form)))
      (def rows @[])
      (var problem nil)
      (var i 1)
      (while (and (not problem) (< i (length form)))
        (def atom (form i))
        (if-let [attribute (and (string? atom) (attribute-of atom))]
          (if (= :value (attributes attribute))
            (if (< (+ i 1) (length form))
              (do (array/push rows [attribute (form (+ i 1))]) (+= i 2))
              (do (set problem
                       (string "'" atom "' needs a value, and the form ends"))
                  (+= i 1)))
            (do (array/push rows [attribute true]) (++ i)))
          # Not a declared attribute. A bare word is a reference to another
          # entity -- a node naming its group. A string or number here has
          # nothing to attach to, which is a value with no attribute.
          (if (string? atom)
            (do (array/push rows [:in (string atom)]) (++ i))
            (do (set problem
                     (string/format "%m has no attribute to belong to" atom))
                (++ i)))))
      (if (empty? entity)
        [nil nil "a form with no entity"]
        [entity rows problem]))))

(defn facts
  ``Read v text into a flat list of [entity attribute value] rows.

  Returns [true rows] or [false message]. THIS IS THE LANGUAGE; `parse`
  below is one consumer of it, the one that builds the graph a layout
  wants. A caller after the facts rather than the picture stops here.

  Every form contributes an existence row for its entity, so an entity that
  says nothing else about itself is still an entity that exists.``
  [text]
  (def forms (try (peg/match compiled text) ([_] nil)))
  (if-not forms
    [false "not valid v: the text does not parse"]
    (do
      (def rows @[])
      (var problem nil)
      (each form forms
        (unless problem
          (def [entity found trouble] (read-form form))
          (if trouble
            (set problem trouble)
            (do
              (array/push rows [entity :is true])
              (each [a v] found (array/push rows [entity a v]))))))
      (if problem [false problem] [true rows]))))

#
# Facts to a graph.
#

(defn parse
  ``Read v text into a graph: {:nodes :edges :sizes :ours :groups}.

  Returns [true graph] or [false message]. A parse failure is a value, not
  an exception, because the caller is a render path that already answers in
  that shape and a malformed graph should reach the page as a message rather
  than as a stack trace.

  THE SHAPE IS UNCHANGED from every earlier version, deliberately:
  `layered`, `force` and `svg` read this table and none of them should have
  to care what the text behind it looks like. An EDGE IS AN ENTITY in the
  language and a `[from to]` pair in this table, because that is what four
  layout passes already iterate.

  WHAT COUNTS AS A NODE. An entity carrying `from`/`to` is an edge; an
  entity that anything claims membership in is a group; everything else is
  a node. That is decided after all the rows are in, so a file may declare
  things in any order and a group named before it is described still reads
  as a group.``
  [text]
  (def [ok rows] (facts text))
  (if-not ok
    [false rows]
    (do
      # Every entity's attributes, gathered before anything is classified.
      (def order @[])          # entities, in the order they first appear
      (def held @{})           # entity -> {attribute value}
      (def memberships @{})    # entity -> [entities it named]

      (defn touch [entity]
        (unless (held entity)
          (put held entity @{})
          (array/push order entity)))

      (each [entity attribute value] rows
        (touch entity)
        (case attribute
          :is nil
          :in (do
                # A group named by a member is an entity in its own right,
                # even if no form ever describes it -- otherwise `(A G)`
                # would claim a membership in something that does not exist.
                (touch (string value))
                (put memberships entity
                     (array/push (or (memberships entity) @[]) (string value))))
          (put (held entity) attribute value)))

      # Which entities are groups: the ones somebody named. An entity that
      # only carries a colour is one too, so a declared-but-unjoined group
      # still draws.
      (def is-group @{})
      (eachp [_ named] memberships
        (each g named (put is-group g true)))
      (each entity order
        (when (and ((held entity) :color)
                   (not ((held entity) :from)))
          (put is-group entity true)))

      (defn edge? [entity]
        (def attrs (held entity))
        (or (attrs :from) (attrs :to)))

      (def nodes @[])
      (def edges @[])
      (def sizes @{})
      (def ours @{})
      (def claimed @{})
      (def groups @[])
      (var problem nil)

      (each entity order
        (def attrs (held entity))
        (cond
          (edge? entity)
          (let [from (attrs :from) to (attrs :to)]
            (if (and from to)
              (array/push edges [(string from) (string to)])
              (set problem
                   (string "the edge '" entity "' needs both from and to"))))

          (is-group entity)
          (array/push groups {:prefix entity
                              :color (string (or (attrs :color) color/ungrouped))})

          # A node. Its unknown attributes ride along in the table rather
          # than being dropped -- though with a closed schema the parser
          # would have refused an undeclared one long before here.
          (do
            (def node @{:name entity
                        :label (string (or (attrs :label) entity))
                        :ours (truthy? (attrs :ours))})
            (each [a v] (pairs attrs)
              (unless (find |(= $ a) [:label :ours :size])
                (put node a v)))
            (array/push nodes (table/to-struct node))
            (when (attrs :size) (put sizes entity (attrs :size)))
            (when (attrs :ours) (put ours entity true))
            (when-let [named (memberships entity)]
              (put claimed entity (first named))))))

      # An edge may name a node no form declared. The row that names it is
      # enough to create it, which is why order never matters.
      (def known @{})
      (each node nodes (put known (node :name) true))
      (each [from to] edges
        (each end [from to]
          (unless (or (known end) (is-group end))
            (put known end true)
            (array/push nodes {:name end :label end :ours false}))))

      (if problem
        [false problem]
        [true {:nodes nodes
               :edges edges
               :sizes sizes
               :ours ours
               :groups groups
               # Membership as the TEXT stated it, for a caller that wants
               # what was written rather than what a prefix rule derives.
               :claimed claimed}]))))

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
  ``One node as a v form: the entity, then what is true of it.

  The attributes go out in a fixed order -- label, ours, size, then any
  groups -- so the same graph writes the same bytes every time and a diff
  of two v files is a diff of what changed rather than of what got
  iterated first.``
  [node sizes group]
  (def name (node :name))
  (def parts @[(string "(" name " label " (quoted (or (node :label) name)))])
  (when (node :ours) (array/push parts " ours"))
  (when (sizes name) (array/push parts (string " size " (sizes name))))
  (when group (array/push parts (string " " group)))
  (array/push parts ")")
  (string/join parts))

(defn- edge-name
  "An edge's entity name, built from its ends so it is stable and unique."
  [from to]
  (string from "->" to))

(defn render
  ``A graph as v text.

  `opts` carries what the config decided -- :groups is the only key that
  affects what comes out, and it does so by naming a group on each node it
  claims. Colour, fill and font are decisions a LAYOUT makes from the
  graph, not facts about the graph, so they do not appear here.

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
  (def claimed (or (graph :claimed) {}))

  # WHAT THE TEXT SAID WINS. `select/group-for` derives membership from the
  # config's prefixes, which is right when the graph came from a scan; a
  # graph that came from v text already carries the memberships it was
  # written with, and re-deriving them would silently rewrite the file.
  (defn group-for [name]
    (or (when-let [named (claimed name)]
          (find |(= (get $ :prefix) named) groups))
        (when-let [named (claimed name)]
          {:prefix named})
        (select/group-for name groups ours)))

  (def out @[])

  # Group declarations first, so a reader meets a group's colour before it
  # meets a node naming it. Nothing REQUIRES that order -- entities accrete
  # in any sequence -- but a file is read top to bottom by people.
  (each g groups
    (array/push out (string "(" (g :prefix) " color " (quoted (g :color)) ")")))

  (each node (graph :nodes)
    (def owner (group-for (node :name)))
    (array/push out (node-form node sizes (when owner (owner :prefix)))))

  # Edges last, and each one is an entity like everything else.
  (each [a b] (graph :edges)
    (array/push out
                (string "(" (edge-name a b) " from " a " to " b ")")))

  (string/join out "\n"))
