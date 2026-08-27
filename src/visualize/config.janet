# The config language: seven verbs, parsed by a PEG.
#
#     (lines)
#     (box src.visualize)
#     (box web 22a6f2)
#     (hide src.test)
#     (prefix ~ src.visualize)
#
# A CLOSED LANGUAGE, which is the point of the grammar below. Every form the
# config can take is written out in `grammar` -- a verb, its arguments, and
# nothing else. There is no evaluation: a line is matched, and what it
# matched is applied. A config cannot loop, cannot define, cannot call, and
# cannot reach the machine, because the grammar has no way to say any of it.
#
# WHAT THIS REPLACED, twice. First the verbs lived in a hand-built Janet
# environment with fifty whitelisted builtins and a pass that rewrote unbound
# symbols into strings; then they were macros in a real environment, which
# made bare names free but handed a config the whole language -- and the
# config is edited through a web page, so that was a real exposure. Both
# versions inherited every feature Janet grew, whether or not it made sense
# for a file that says which directories to box. A grammar cannot grow
# features by accident.
#
# WHAT A NAME IS. The dotted path the node shows: `src.visualize.color`. A
# slash is accepted too, since a path is a natural thing to type. Names are
# bare -- no quotes -- because a config is mostly names and quoting them all
# is noise. A colour is `rrggbb` -- six hex digits, no hash, because a hash
# starts a comment -- or one of the names in src/visualize/color.
#
# A NAME MAY START WITH A PREFIX TOKEN. `(prefix this as)` binds a token to
# a path -- `(prefix ~ src.visualize)` -- and from then on a name whose HEAD
# is that token is expanded, and the nodes under the path wear the token as
# their label. Only the head: substitution that reached into the middle of a
# name would not be a prefix substitution.
#
# EACH LINE IS ITS OWN PROGRAM, so a mistake on line three does not cost you
# lines one and two, and the editor can point at the line that failed. That
# is why `run` takes a list of lines rather than a file.

(import ./color)
(import ./names)

(defn new-state
  ``What the config has said about the graph so far.

  Every field is ordered so that re-running a program is deterministic.``
  []
  @{:hidden @[]
    :groups @[]
    # THE DIRECTORY BEING DRAWN, when the caller knew it. `(visualize p)` is
    # the one verb that has to look at the disk -- to say so when p names no
    # directory -- and this is how it reaches it. Nil for a caller that
    # passed no root, in which case that check is simply not made.
    :root nil
    # Prefixes whose colour the program named outright. They keep it; the rest
    # are reassigned around them whenever the set changes.
    :chosen @{}
    # Line counts: whether to write them on the labels, and whether to shade
    # by them instead of by edge count. Separate because they answer separate
    # questions -- the number is exact, the colour is a glance -- and either is
    # useful without the other.
    :sized false
    # Prefixes to narrow to. Empty means no filter, which is the WHOLE graph --
    # so a config saying nothing shows the externals too.
    :only @[]
    # Prefixes to fold into one node each. In declaration order, because two
    # that overlap must not fold a node into both.
    :folded @[]
    # Whether a node whose file moved since the last drawing should flash.
    :animated false
    # THE PALETTE THIS CONFIG DRAWS WITH: the colour of a node no box
    # claimed, and the two derivations a renderer needs from any colour --
    # the ink that reads against the page, and the tint a flash breathes in.
    #
    # Here because a colour is a CONFIG choice. The verbs name colours, this
    # module resolves them, and the answers travel with the rest of what the
    # config decided rather than being fetched separately by whoever draws.
    :palette color/for-drawing
    # ALIASES, longest prefix first. `(prefix ~ src.visualize)` binds `~` to
    # that path: the nodes under it are RELABELLED to wear the alias, and
    # any later name starting with it is expanded before matching. Kept
    # sorted by the length of what they stand for, because with several
    # defined the most specific should win and for prefixes that is simply
    # the longest.
    :aliases @[]})

(defn- reflow
  ``Give every automatic group a hue no other group is using.

  Done over the whole list rather than once at assignment, because a colour
  named LATER can collide with one already handed out automatically --
  `(box a) (box b red)` where `a` happened to draw red. An explicit
  colour always wins and the automatic ones move out of its way, so the set of
  boxes stays distinguishable however the program was written.``
  [state]
  # `ungrouped` is reserved: a group wearing it would be invisible AS a group,
  # since every node outside a box already wears it.
  (def spoken @{color/ungrouped true})
  (each g (state :groups)
    (when ((state :chosen) (g :prefix)) (put spoken (g :color) true)))
  (def free (filter |(not (spoken $)) color/palette))
  (def spare (filter |(not= $ color/ungrouped) color/palette))
  (var taken 0)
  (put state :groups
       (map (fn [g]
              (if ((state :chosen) (g :prefix))
                g
                (let [hue (if (< taken (length free))
                            (free taken)
                            # More groups than free hues: walk the palette so
                            # the colours repeat predictably rather than every
                            # extra group sharing one.
                            (spare (% taken (length spare))))]
                  (++ taken)
                  {:prefix (g :prefix) :color hue})))
            (state :groups))))

# THE VERBS, and the one place that knows them.
#
# Name, the arguments it takes, and what it does -- and every use of that is
# derived from here: the PEG's alternatives are built from `:args` below, the
# "there is no verb X, try..." message lists these names, and the page's help
# panel is rendered from the whole table. Adding a verb is adding an entry.
#
# THIS USED TO BE THREE PLACES. The grammar spelled each verb out, a `verbs`
# list beside it repeated the names for error messages, and the starter
# config described them in a comment -- so a new verb meant remembering all
# three, and `font` outlived its removal in two of them.
#
# `:args` is what the verb takes, as PEG rule names, and doubles as the
# usage line: [:name :color?] is `(box p color?)`. A trailing `?` marks
# the optional one. Nothing here is prose the parser reads -- `:blurb` is
# for the reader, and the parser never sees it.
(def verb-specs
  [{:name "prefix" :args [:alias :name]
    :blurb "Bind a name to a prefix. This lets you use an arbitrary name as an arbitrary prefix. Binding the same name twice is an error."}
   {:name "box" :args [:name :color?]
    :blurb "Draw a box around nodes starting with the provided prefix. Give an optional color (blue, red, ..., or rrggbb)."}
   {:name "fold" :args [:name]
    :blurb "Fold all nodes starting with prefix into one node aggregating line counts, incoming, and outgoing edges."}
   {:name "hide" :args [:name]
    :blurb "Hide all nodes starting with the given prefix."}
   {:name "only" :args [:name]
    :blurb "Only visualize nodes that start with the provided prefix. Multiple onlys will create a union of nodes."}
   {:name "lines" :args []
    :blurb "Write each file's line count under its name."}
   {:name "animate" :args []
    :blurb "Flash a node when its file is new or has been written since the last drawing. Nothing flashes on the first drawing, since there is no earlier one to differ from."}
   {:name "visualize" :args [:name]
    :blurb "Draw the subproject at p using its own visualize.conf. Every line of that file is read as though written here, with p put in front of the names it mentions, so a nested project keeps its own layout inside the bigger drawing."}])

# LONGEST NAME FIRST is not cosmetic: a PEG alternation takes the first
# branch that matches, so a verb whose name STARTS WITH another one -- were
# `lines` and `lines-by-size` both here -- would match the shorter rule and
# leave the rest unparsed. Sorting by length removes the need to remember
# that when adding a verb, which is exactly the kind of ordering a
# hand-written list gets wrong once and then keeps.

(def- verb-rules
  (map (fn [spec]
         (def parts @[~(constant ,(keyword (spec :name))) (spec :name)])
         (if (empty? (spec :args))
           (array/push parts :space)
           (each arg (spec :args)
             (case arg
               :alias (do (array/push parts :space) (array/push parts :alias))
               :name (array/push parts :name)
               :color? (array/push parts ~(? :color)))))
         (tuple ;(array '* ;parts)))
       (sorted-by |(- (length ($ :name))) verb-specs)))

# THE GRAMMAR. Every form the language has, in one readable place.
#
# A NAME is the dotted path plus the characters a real directory can carry --
# letters, digits, underscore, hyphen, dot, and slash for someone typing a
# path. It may be written bare or quoted; quoting exists for a name with a
# space in it, not as the normal case.
#
# The captures are shaped so `apply` below reads them as [verb & args]: the
# verb name as a keyword, then its arguments as strings.
# EXPORTED so tooling reads a config the way the app does. `tools/mark-externals`
# rewrites names in place and must agree with this parse exactly; a second
# grammar written beside it would drift.
(def grammar
  ~{:space (any (set " \t"))
    # A NAME MAY WEAR AN ALIAS, so the character set is "anything a path or
    # an alias token can hold" rather than the path characters alone: with
    # `~` bound, `~.color` is a name. The grammar cannot know which tokens
    # are bound -- that is state, and this is a parse -- so it accepts the
    # shape and `expand-aliases` decides the meaning. An unbound token simply
    # matches no node, which is what a wrong path does too.
    :bare (<- (some (if-not (+ (set " \t()\"#") -1) 1)))
    # AN ALIAS IS ANY SHORT TOKEN, not a name: the whole point is to pick a
    # character a path never contains, so `~` and `@` and `#lib` are all
    # fair. Parens and whitespace end it, and `#` would start a comment at
    # the head of a line, so the alias is read where a comment cannot begin.
    :alias (<- (some (if-not (+ (set " \t()\"") -1) 1)))
    :quoted (* `"` (<- (any (if-not `"` 1))) `"`)
    :name (* :space (+ :quoted :bare) :space)
    # A colour is a name as far as the shape goes -- `red` and `22a6f2` both
    # arrive as text and src/visualize/color decides which, complaining when
    # it is neither. NO LEADING `#`: that character starts a comment, and one
    # character means one thing.
    :color (* :space (+ :quoted :bare) :space)
    # `,` so the alternation is spliced in when this table is BUILT, not
    # left as a literal for the PEG compiler to choke on.
    :verb (* "(" :space ,(tuple ;(array '+ ;verb-rules)) ")")
    # A TRAILING COMMENT is part of the line, not a syntax error. `#` to
    # end of line, the way it works in Janet and the shell -- and the way
    # the config's own file is written, since the default one ships with
    # explanatory lines in it.
    :comment (* "#" (any 1))
    :main (* :space (any (* :verb :space)) (? :comment) -1)})

# A `#` ANYWHERE ENDS THE LINE. The grammar above only allows a comment
# between verbs, which is where a well-formed one sits -- but `#` is the
# comment character wherever it appears, so the text is cut at the first one
# outside quotes before the grammar ever sees it. Without this,
# `(box web #22a6f2)` was a SYNTAX ERROR rather than a box call with a
# comment after it, which is a confusing way to learn that colours are
# written bare.
#
# Quotes are respected, so `(hide "a#b")` keeps its hash.
(defn- code-of [line]
  (var cut nil)
  (var quoted false)
  (var i 0)
  (while (and (nil? cut) (< i (length line)))
    (def ch (line i))
    (cond
      (= ch (chr `"`)) (set quoted (not quoted))
      (and (= ch (chr "#")) (not quoted)) (set cut i))
    (++ i))
  (if cut (string/slice line 0 cut) line))

(def- verbs (map |($ :name) verb-specs))

(defn usage
  ``One verb's call shape, from the same `:args` the parser was built from.

  `(box p color?)`. The `?` marks the optional argument. A prefix argument is
  `p` -- short, because it appears in nearly every verb and a long word
  repeated down the list is read as noise rather than as a placeholder. An
  alias argument is `name`, which is what the verb gives the prefix:
  `(prefix name p)` reads as "name this prefix".``
  [spec]
  (def parts
    (map (fn [arg]
           (case arg
             :alias "name"
             :name "p"
             :color? "color?"
             (string arg)))
         (spec :args)))
  (string "(" (string/join (array (spec :name) ;parts) " ") ")"))

(defn docs
  ``Every verb as {:name :usage :args :blurb}, in the order written above.

  FROM THE GRAMMAR'S OWN TABLE, so the help the page shows cannot describe a
  verb the parser does not have, or miss one it does. That is the whole
  reason `verb-specs` is a table of data rather than seven lines of PEG:
  documentation that is derived cannot go stale.

  `:args` IS THE KIND OF EACH SLOT -- "alias", "name", "color?" -- and it is
  here so the page can complete the right thing in each. Without it the
  editor had to assume every argument after a verb was a prefix, which is
  wrong for the colour `box` takes second. As names rather than keywords,
  since this crosses into JSON.``
  []
  (map (fn [spec]
         {:name (spec :name)
          :usage (usage spec)
          :args (map |(string $) (spec :args))
          :blurb (spec :blurb)})
       verb-specs))

(defn colours
  ``Every colour a config can name.

  For the editor to complete: the closed set is worth offering, since a
  colour is either in it or it is a hex triple you already know.``
  []
  (sorted (keys color/named)))

(defn- normalise
  ``A name as the prefix it selects: slashes to dots, edges trimmed.

  Node names are dotted paths, so a config name is usually already the right
  shape and this only tidies. See src/visualize/select.janet, which does the
  matching.``
  [text]
  (string/replace-all "/" "." (string/trim text "./")))

(defn expand-aliases
  ``A name with its alias replaced by what the alias stands for.

  `(prefix ~ src.visualize)` then `(hide ~.color)` hides
  `src.visualize.color`; `~` alone is `src.visualize` itself.

  ONLY IN PREFIX POSITION, which is the whole rule and the reason the verb
  is called `prefix`. The token has to be the HEAD of the name and nothing
  more is asked of it -- with `~` bound to `src.config`, `~~.something`
  expands to `src.config~.something`: the first `~` is the prefix, and the
  second is an ordinary character in the rest of the name, because a
  substitution anywhere but the head would not be a prefix substitution.
  No segment boundary is required; a prefix is a prefix.

  One pass, never re-scanned. What an alias stands for is a path, not more
  aliases, so expanding the result again could only find tokens that were
  part of the name the user wrote.

  LONGEST FIRST, which is what "most specific wins" means for prefixes: with
  both `~` and `~~` bound, `~~.color` is the longer token's. The list is kept
  sorted by the length of the ALIAS, so the longer one is tried first.

  Exported because the same expansion has to happen to a label -- see
  `select/alias-label`, its mirror -- and doing it twice from two spellings
  is how the two would drift apart.``
  [aliases text]
  (var out text)
  (var done false)
  (each entry aliases
    (unless done
      (def token (entry :alias))
      (when (string/has-prefix? token text)
        (set out (string (entry :prefix) (string/slice text (length token))))
        (set done true))))
  out)

(defn- nested-dir
  ``The directory `p` names, or nil when there is none.

  THE DIRECTORY IS FOUND BY NAMING THE DIRECTORIES, not by turning the name
  back into a path. A node name is the dotted form of a path and that
  mapping is not reversible: a directory called `my.lib` is the node
  `my.lib`, and splitting on dots would send this looking for `my/lib`.

  So the tree is walked instead. At each step the real entries are named the
  way a node is named, and the one whose name the target starts with is
  descended into -- longest first, so `my.lib` wins over `my` when both are
  there. What is left over after a match is what remains to find, and
  anything left at the end means the name does not describe a directory.``
  [root dir]
  (var here root)
  (var rest dir)
  (var found true)
  (while (and found (not (empty? rest)))
    (set found false)
    (def entries
      (sorted-by |(- (length $))
                 (filter |(= :directory (os/stat (string here "/" $) :mode))
                         (try (os/dir here) ([_] [])))))
    (each entry entries
      (unless found
        (def named (normalise entry))
        (when (or (= rest named) (string/has-prefix? (string named ".") rest))
          (set here (string here "/" entry))
          (set rest (if (= rest named) "" (string/slice rest (+ 1 (length named)))))
          (set found true)))))
  (when (empty? rest) here))

(defn- holds?
  ``Does the project at `dir` hold something called `name`?

  The FIRST SEGMENT only, which is what decides whose name it is: with an
  `otto` directory, `otto.store` is this project's; with no `urllib`,
  `urllib.parse` is a name it merely refers to.

  A FILE COUNTS, not only a directory -- `(hide tests)` may name either, and
  a node is a file as often as it is a folder. Entries are named the way a
  node is named, so a file's extension is not part of the comparison.``
  [dir name]
  (def head (first (string/split "." name)))
  (when (empty? head) (break false))
  (var found false)
  (each entry (try (os/dir dir) ([_] []))
    (unless found
      (def named (normalise entry))
      (when (or (= named head)
                # `tests.py` is named `tests`; the stem is what a node wears.
                (= (normalise (names/stem entry)) head))
        (set found true))))
  found)

(defn- apply-verb
  "One matched form against the state. Returns nil, or a complaint."
  [state form]
  (def [verb & args] form)
  (case verb
    :hide
    (let [text (normalise (expand-aliases (state :aliases) (first args)))]
      (unless (index-of text (state :hidden))
        (array/push (state :hidden) text))
      nil)

    :only
    (let [text (normalise (expand-aliases (state :aliases) (first args)))]
      (unless (index-of text (state :only))
        (array/push (state :only) text))
      nil)

    :box
    (let [text (normalise (expand-aliases (state :aliases) (first args)))
          wanted (get args 1)]
      (var hue "")
      (var wrong nil)
      (if wanted
        (let [resolved (color/as-hex wanted)]
          (cond
            (not resolved)
            (set wrong (string "'" wanted "' is not a colour -- "
                               "use rrggbb or a name like blue"))
            (= resolved color/ungrouped)
            (set wrong (string color/ungrouped " is what ungrouped nodes "
                               "already wear -- the group would be invisible; "
                               "pick another colour"))
            (do (put (state :chosen) text true)
                (set hue resolved))))
        (put (state :chosen) text nil))
      (or wrong
          (do
            (put state :groups
                 (array ;(filter |(not= ($ :prefix) text) (state :groups))
                        {:prefix text :color hue}))
            (reflow state)
            nil)))

    :prefix
    (let [token (first args)
          full (normalise (get args 1))
          bound (find |(= ($ :alias) token) (state :aliases))]
      (cond
        # No empty-name branch: `:alias` needs at least one character, so a
        # `(prefix)` or `(prefix ~)` never parses and never reaches here. An
        # empty PATH does reach it, because `""` is a legal quoted name.
        (empty? full)
        "a prefix needs something to stand for -- (prefix name p), like (prefix ~ src.visualize)"

        # REBINDING IS AN ERROR, not a replacement. A config is read top to
        # bottom and every line is its own program, so a second binding would
        # silently change what the lines above it meant. Say it instead.
        bound
        (string "`" token "` is already bound to `" (bound :prefix)
                "` -- a name stands for one path")

        (do
          (put state :aliases
               (sorted-by |(- (length ($ :alias)))
                          (array ;(state :aliases) {:alias token :prefix full})))
          nil)))

    :fold
    (let [text (normalise (expand-aliases (state :aliases) (first args)))]
      (unless (index-of text (state :folded))
        (array/push (state :folded) text))
      nil)

    :lines (do (put state :sized true) nil)
    :animate (do (put state :animated true) nil)

    # NOTHING TO DO HERE. The work is `run`'s: it reads the named project's
    # own config and applies those lines in a pass of its own, after this
    # file's, so that what the parent says still wins. This case exists so
    # the verb is not an unhandled one, and to catch the empty name -- which
    # parses, since `""` is a legal quoted name, and would otherwise read as
    # "the project at the root", which is this one.
    :visualize
    (let [named (string/trim (or (first args) "") "./")]
      (cond
        (empty? named)
        "a nested project needs a directory -- (visualize p), like (visualize lib)"

        # A NAME THAT IS NO DIRECTORY IS A TYPO, and worth saying so. A
        # directory with no config of its own is different and stays silent:
        # it has nothing to say about how it is drawn, which is a fact. But
        # `(visualize otto)` where the directory is `otto-ios` matched
        # nothing, drew nothing, and said nothing -- and looked exactly like
        # a nesting that had failed.
        #
        # Only when a root was passed. Without one there is no disk to
        # check against, and complaining would be guessing.
        (and (state :root) (not (nested-dir (state :root) named)))
        (string "there is no `" named "` here -- (visualize p) names a "
                "directory of this project")

        nil))))

(defn- complain
  ``What is wrong with a line the grammar refused.

  The grammar knows only that it did not match, which is not something to
  show somebody editing a config in a browser. These are the mistakes worth
  naming; anything else gets the list of verbs, which is short enough to be
  an answer in itself.``
  [line]
  (def text (string/trim line))
  # THE FORM THAT FAILED, not the first one on the line. A line may hold
  # several -- `(box src.web) (hide)` is what the compose bar writes when it
  # appends to a selected line -- and reading the verb off the front named
  # `box` for a mistake in `hide`, which is a confusing thing to be told.
  #
  # Each form is tried on its own and the first that the grammar refuses is
  # the one to talk about. A line that fails only as a WHOLE -- unbalanced
  # parentheses, text outside a form -- has no such piece, and falls back to
  # the front of the line, which is where the rest of these messages point.
  (def forms (peg/match ~(any (+ (<- (* "(" (any (if-not ")" 1)) ")"))
                                 (if-not "(" 1)))
                        text))
  (def broken (find |(nil? (peg/match grammar $)) (or forms [])))
  (def named (peg/match ~(* "(" (any (set " \t")) (<- (some (range "az" "AZ" "--"))))
                        (or broken text)))
  (def verb (and named (first named)))
  (cond
    (not (string/has-prefix? "(" text))
    "a config line is a form in parentheses, like (hide src.test)"

    (not (string/has-suffix? ")" text))
    "this line is missing its closing parenthesis"

    (and verb (not (index-of verb verbs)))
    (string "there is no verb `" verb "` -- try " (string/join verbs ", "))

    # THE VERB'S OWN SHAPE, from the table the parser was built from. This
    # used to be one canned sentence for every verb, ending "and a colour is
    # rrggbb or a name" -- so `(lines extra)` and `(prefix ~)` both complained
    # about a colour neither of them takes, and every arity error read like a
    # `box` error.
    (and verb (index-of verb verbs))
    (let [spec (find |(= ($ :name) verb) verb-specs)]
      (string "`" verb "` takes " (usage spec)
              (if (empty? (spec :args))
                " and nothing else"
                (string " -- p is a prefix of the labels on the graph, so"
                        " src.visualize catches every node under it"
                        (if (index-of :color? (spec :args))
                          ". A colour is rrggbb or a name like blue"
                          "")))))

    (string "not a config form -- try " (string/join verbs ", "))))

# THE MARK ON VISUALIZE'S OWN LINES, defined here because the parser is the
# first thing that has to recognise one and skip it. What the notes are for,
# and the rest of the vocabulary, is at the bottom of this file.
(def marker "@visualize")

(defn note?
  "Is this line one of visualize's own notes rather than config?"
  [line]
  (string/has-prefix? marker (string/trim (or line ""))))

(defn eval-line
  ``Run one line against `state`. Returns nil, or a complaint about the line.

  ONE LINE IS THE UNIT. A config is a list of independent statements, so the
  line is what gets matched, what gets applied, and what a complaint is
  attributed to -- which is what makes "this line is wrong" a thing the
  editor can point at.

  A COMMENT IS A LINE THAT DOES NOTHING, and so is a blank one. `#` starts a
  comment, as it does in Janet and in the shell.

  `only` names the one verb to apply, or nil for every verb but that one.
  That is how `run` gets its two passes -- see the note there. It selects on
  the VERB rather than the line, because a line may hold several forms and
  `(prefix ~ src) (hide ~.a)` must bind on the first pass and hide on the
  second.``
  [line state &opt only]
  (def text (string/trim (code-of line)))
  (cond
    (empty? text) nil
    (string/has-prefix? "#" text) nil
    # VISUALIZE'S OWN NOTES ARE NOT CONFIG. They are written by the program
    # for the program -- see `marker` -- and complaining that one is not a
    # call would be complaining about a line nobody typed.
    (note? text) nil
    (if-let [forms (peg/match grammar text)]
      (do
        (var wrong nil)
        # A line may hold more than one form -- `(box test) (hide test)` --
        # and the first complaint is the one worth reporting.
        (var i 0)
        (while (< i (length forms))
          (def verb (forms i))
          (def args @[])
          (++ i)
          (while (and (< i (length forms)) (string? (forms i)))
            (array/push args (forms i))
            (++ i))
          (def mine (if only (= verb only) (not= verb :prefix)))
          (when (and mine (not wrong))
            (set wrong (apply-verb state [verb ;args]))))
        wrong)
      (complain text))))

# THE ONE SPELLING of the config file's name. Up here because `nested-lines`
# below needs it to find a subproject's own config, and a constant belongs
# above its first reader.
(def config-name "visualize.conf")

(defn- visualize-targets
  ``The subprojects a line asks for, as written.

  A line may hold several forms, so `(visualize a) (visualize b)` names
  both. Anything that does not parse names none -- the complaint about that
  belongs to the ordinary passes, which have already made it.``
  [line]
  (def text (string/trim (code-of line)))
  (def out @[])
  (when (and (not (empty? text))
             (not (string/has-prefix? "#" text))
             (not (note? text)))
    (when-let [forms (peg/match grammar text)]
      (var i 0)
      (while (< i (length forms))
        (def verb (forms i))
        (++ i)
        (def args @[])
        (while (and (< i (length forms)) (string? (forms i)))
          (array/push args (forms i))
          (++ i))
        (when (and (= verb :visualize) (not (empty? args)))
          (array/push out (first args))))))
  out)

(defn- nested-lines
  ``The lines of `p`'s own visualize.conf, rewritten to speak about `p`.

  A NESTED PROJECT KEEPS ITS OWN LAYOUT. `(visualize lib)` reads
  `lib/visualize.conf` and folds it into this config as though its lines had
  been written here -- with `lib` put in front of every name they mention,
  because a child config says `vendor` about a node this drawing calls
  `lib.vendor`.

  VERBS THAT NAME NOTHING ARE DROPPED. `lines` and `animate` are decisions
  about the WHOLE drawing -- whether every node carries a line count,
  whether every changed file flashes -- and a subproject does not get to
  make them for the graph it is sitting in. Only the verbs that carry a name
  come through, and each of those is scoped by the prefix.

  Missing or unreadable is not an error. A directory with no config of its
  own has nothing to say about how it is drawn, which is a fact rather than
  a mistake.``
  [root p]
  (default root "")
  (def dir (string/trim p "./"))
  (when (or (empty? root) (empty? dir)) (break []))
  (def here (nested-dir root dir))
  (unless here (break []))
  # The child's own directory, for deciding which of its names are places.
  (def here-dir here)
  (def path (string here "/" config-name))
  (unless (os/stat path :mode) (break []))
  (def text (try (slurp path) ([_] nil)))
  (unless text (break []))
  # The NAME prefix stays dotted: it is what the nodes are called.
  (def prefix (normalise dir))
  (def out @[])
  # THE CHILD'S OWN BINDINGS, READ FIRST. A nested config may name a prefix
  # for its own convenience -- `(prefix v vendor)` and then `(box v)` -- and
  # those `v`s are not paths, so prefixing them gives `lib.v`, which matches
  # nothing and silently does nothing.
  #
  # The binding cannot come through either: it would put the child's token
  # into the parent's namespace, where it would collide with the parent's
  # own and mean a different thing. So the alias is EXPANDED HERE, where it
  # still means what the child said, and only the resulting path travels.
  # `(prefix v vendor) (box v)` in lib arrives as `(box lib.vendor)`.
  #
  # Two passes for the same reason `run` has two: a prefix binds a token the
  # lines above it may already use, and where the binding sits in the file
  # should not change what the file means.
  (def aliases @[])
  (each line (string/split "\n" (string text))
    (def trimmed (string/trim (code-of line)))
    (when (and (not (empty? trimmed))
               (not (string/has-prefix? "#" trimmed))
               (not (note? trimmed)))
      (when-let [forms (peg/match grammar trimmed)]
        (var i 0)
        (while (< i (length forms))
          (def verb (forms i))
          (++ i)
          (def args @[])
          (while (and (< i (length forms)) (string? (forms i)))
            (array/push args (forms i))
            (++ i))
          (when (and (= verb :prefix) (= 2 (length args)))
            (array/push aliases
                        {:alias (first args) :prefix (normalise (get args 1))}))))))
  # LONGEST TOKEN FIRST, the same order `run` keeps them in, so that with
  # both `~` and `~~` bound the longer one is tried first.
  (def aliases (sorted-by |(- (length ($ :alias))) aliases))
  (each line (string/split "\n" (string text))
    (def trimmed (string/trim (code-of line)))
    (when (and (not (empty? trimmed))
               (not (string/has-prefix? "#" trimmed))
               (not (note? trimmed)))
      (when-let [forms (peg/match grammar trimmed)]
        (var i 0)
        (while (< i (length forms))
          (def verb (forms i))
          (def args @[])
          (++ i)
          (while (and (< i (length forms)) (string? (forms i)))
            (array/push args (forms i))
            (++ i))
          # A verb with no arguments is a whole-drawing decision; see above.
          # A `prefix` line has already been read into `aliases` and must not
          # travel: its token would land in the parent's namespace.
          (unless (or (empty? args) (= verb :prefix))
            (def spec (find |(= ($ :name) (string verb)) verb-specs))
            (def kinds (if spec (spec :args) []))
            # PREFIX THE NAMES AND NOTHING ELSE. `(box p color)` has a colour
            # in its second slot and `(prefix ~ p)` an alias in its first --
            # neither is a node name, and putting `lib.` on either would
            # break it. The verb table already says which slot is which.
            (def moved
              (seq [[at arg] :pairs args]
                (if (= (get kinds at) :name)
                  # THE MARK IS READ BEFORE `normalise` TRIMS IT. `?.` on its
                  # own means every external, and normalise trims dots from
                  # both ends -- so the bare mark arrived here as `?`, which
                  # `names/external?` does not recognise. Asked of the raw
                  # argument instead.
                  # THE MARK IS READ BEFORE `normalise` TRIMS IT. `?.` on
                  # its own means every external, and normalise trims dots
                  # from both ends -- so the bare mark arrived here as `?`,
                  # which `names/external?` does not recognise.
                  #
                  # A BARE `?` IS THE SAME REQUEST. Someone hiding every
                  # external types the mark, and whether they finish it with
                  # the dot is not a distinction worth having: `(hide ?)` and
                  # `(hide ?.)` both mean "the externals this project pulls
                  # in", and one of them silently meaning "every external in
                  # the drawing" is how a subproject erased its siblings'.
                  (let [raw (string/trim (expand-aliases aliases arg))
                        marked (or (names/external? raw) (= raw "?"))
                        full (normalise raw)]
                    # A NAME FROM OUTSIDE THE TREE IS NOT A PLACE, and does
                    # not take the prefix. `os` and `pydantic` are nodes but
                    # not files: there is nothing under this project called
                    # os, so `shoppingagent.os` matches nothing at all --
                    # which is how a config with twenty-six such hides drew
                    # every one of them anyway.
                    #
                    # Told apart by ASKING THE DISK: a name is the project's
                    # own if the project HOLDS something by that name --
                    # a directory or a file, since `(hide tests)` may mean
                    # either. Anything else is a name the project merely
                    # refers to, and means the same thing here as it does
                    # to the parent.
                    #
                    # Only the FIRST segment is asked about, because that is
                    # what decides whose name it is: `otto.store` is this
                    # project's if it has an `otto`, and `urllib.parse` is
                    # not if it has no `urllib`.
                    #
                    # AN EXTERNAL IS SCOPED TO THE PROJECT THAT NAMED IT.
                    # An external has no place -- that is what the mark says
                    # -- so it cannot take a path prefix. But a nested
                    # config's `(hide ?.)` means "the externals THIS project
                    # pulls in", and passing it up unchanged made it mean
                    # every external in the whole drawing: one subproject
                    # hiding its libraries erased every other subproject's
                    # too.
                    #
                    # So the project travels with the name, after an `@`.
                    # `?.` from `shoppingagent` arrives as `?.@shoppingagent`
                    # and `?.uvicorn` as `?.uvicorn@shoppingagent`, which
                    # `drop-nodes` reads by asking which nodes that project
                    # actually references. A name written at the TOP level
                    # carries no scope and still means every match, which is
                    # what `(hide ?.archive)` in the parent relies on.
                    (if marked
                      (string full "@" prefix)
                      (if (not (holds? here-dir full))
                        full
                        (string prefix "." full))))
                  arg)))
            (array/push out
                        (string "(" verb " " (string/join moved " ") ")")))))))
  out)

(defn- pasted
  ``The lines, with every `(visualize p)` replaced by p's own config.

  A NESTED CONFIG IS PASTED IN, and that is the whole of the mechanism. The
  lines that come back are ordinary lines: `run` binds and applies them like
  any others, and a complaint about one is a complaint about the line the
  paste put there.

  DEPTH COSTS NOTHING. `nested-lines` puts p in front of the names its
  lines mention, and `(visualize q)` inside p carries a name like every
  other verb -- so it arrives here as `(visualize p.q)`, already pointing at
  the right directory, and the next turn of this loop reads it. Two levels
  or ten, the only thing that recurses is the paste.

  AFTER THE LINE IT REPLACES, so a parent's own words still win: `run`
  applies in order, and what is written here about p comes before what p
  says about itself.

  A CYCLE WOULD NOT TERMINATE -- a config naming a directory that names it
  back -- so the walk is bounded. Any project nested a hundred deep is a
  mistake rather than a layout, and stopping is better than hanging.``
  [lines root]
  (def out @[])
  (var todo (array ;lines))
  (var rounds 0)
  (while (and (not (empty? todo)) (< rounds 100))
    (++ rounds)
    (def next @[])
    (each line todo
      (def targets (visualize-targets line))
      (if (empty? targets)
        (array/push out line)
        (do
          # The line itself is kept: it is what the editor draws, and its
          # own complaints (an empty name) belong to it.
          (array/push out line)
          (each p targets
            (each nested (nested-lines root p)
              (array/push next nested))))))
    (set todo next))
  out)

(defn run
  ``Every line, in order, against one fresh state.

  Returns [state problems], where `problems` maps a line's INDEX to what went
  wrong with it -- the index because that is what the editor draws against.

  TWO PASSES, and `prefix` is the reason. A prefix binds a token that other
  lines then spell names with, so it has to be known before any of them are
  read -- otherwise `(hide ~.color)` above `(prefix ~ src.visualize)` hides a
  node literally called `~.color`, silently, because an unbound token is a
  name like any other. Declaring a prefix at the foot of the file is a
  reasonable thing to do, and where it sits should not change what the file
  means.

  So: every `prefix` first, in order, then everything else, in order. Within
  each pass the file still reads top to bottom, which is what `box` needs
  for its colours and what makes "the first binding of a token wins" true.
  Nothing else here is order-dependent across the two.``
  [lines &opt root]
  # THE NESTED CONFIGS ARE PASTED IN FIRST, and then everything below runs
  # on the result. A line that came from a subproject is a line: it binds,
  # it applies, it complains, in the same two passes as every other -- and
  # a `(visualize a.b)` among them is expanded by the same paste that put it
  # there, so nesting goes as deep as the directories do with no mechanism
  # of its own.
  (def lines (if root (pasted lines root) lines))
  (def state (new-state))
  (put state :root root)
  (def problems @{})
  # Pass one: the bindings. A complaint here is the prefix line's own.
  (eachp [i line] lines
    (when-let [wrong (eval-line line state :prefix)]
      (put problems i wrong)))
  # Pass two: everything else, now that every token stands for something.
  (eachp [i line] lines
    (when-let [wrong (eval-line line state)]
      # A line whose prefix already failed keeps that complaint rather than
      # collecting a second one for the same text.
      (unless (problems i) (put problems i wrong))))
  [state problems])

# -- the config file -------------------------------------------------------
#
# WHERE THE LANGUAGE MEETS THE DISK. Reading, writing and editing the file
# are all about what a config IS, so they live with the grammar that reads
# one -- rather than in the renderer, which was importing this module to
# parse a file it had just read itself.


# What the panel calls itself: the file, without the extension. The panel IS
# visualize.conf -- what you type there is what lands in it -- so naming it
# anything else made the two look like different things.
(def config-title "visualize")

# Written on first run so there is something to edit rather than a blank pane.
# Comments survive a round-trip through the editor, so they are worth having.
# THE STARTER no longer lists the verbs. It used to, and that made it the
# third place that had to be remembered when one changed -- `font` outlived
# its deletion here. The `?` in the corner is generated from the grammar and
# is therefore always right, so this points at it instead.
(def starter
  ``# One verb per line. Press ? for the full list.
# A name is the dotted path a node shows: (box src.parsers) draws a box
# round that directory, (hide src.test) drops it. A name from OUTSIDE the
# tree wears the ?. the drawing shows it with: (hide ?.os), (box ?.SwiftUI).
# Comment out with '#'.
(lines)
``)

# The starter above ends without a newline, because a long-string literal ends
# where it ends. Written as-is, the last line has nothing after it and the
# next edit through the page appends to it -- so the file is normalised on the
# way to disk exactly as `write-config` does it.

# -- what visualize writes to itself ----------------------------------------
#
# A LINE THAT BEGINS `@visualize` IS THE PROGRAM'S OWN NOTE, not yours. It is
# not a call, the parser above never sees it, the editor does not show it,
# and the graph does not know it exists. It is here because the config file
# is the one thing that outlives a crash and belongs to this project: a state
# directory somewhere else would be a second place to look and a second thing
# to keep in step with the tree it describes.
#
# WHAT IT IS FOR. Each terminal pane runs behind its own supervisor process,
# reachable only through a socket named after the pane. The page holds those
# ids in memory, so a server that goes down takes the list with it -- and a
# supervisor that survives is then a live session nothing can reach, costing
# a process and a pty with no way back to it. Written down, the next server
# reads them, greets the ones that answer, and clears out the ones that do
# not.
#
# THE SHAPE IS THE VERBS' SHAPE, a name and its arguments, so a person who
# opens the file recognises it even though nothing asked them to read it:
#
#     @visualize terminal 3 socket /tmp/visualize-2f330cb2.3.sock
#
(defn notes
  "Every note in `lines`, each as its words after the marker."
  [lines]
  (seq [line :in lines :when (note? line)]
    (filter |(not (empty? $))
            (string/split " " (string/trim (string/slice (string/trim line)
                                                         (length marker)))))))

(defn terminals
  ``The panes the last run left behind, as [id socket] pairs.

  Order is the file's order, which is the order they were opened.``
  [lines]
  (seq [words :in (notes lines)
        :when (and (= "terminal" (get words 0))
                   (= "socket" (get words 2))
                   (get words 1) (get words 3))]
    [(get words 1) (get words 3)]))

(defn remember-terminals
  ``The lines, with their terminal notes replaced by `pairs`.

  REWRITTEN WHOLE rather than appended to, because the notes are a record of
  what is open right now: a pane that has gone has to leave the file, and
  editing in place would mean finding it first. Everything that is not a
  note is untouched and keeps its order -- the notes go at the end, out of
  the way of a file someone is reading.``
  [lines pairs]
  (def kept (array ;(filter |(not (note? $)) lines)))
  # THE SEPARATOR GOES WITH THEM. A blank line is put before the notes so
  # they read as a footnote rather than as the next thing you wrote -- and
  # it has to come off again when they go, or opening and closing panes
  # leaves a blank line behind on every round and the file grows a tail of
  # them.
  #
  # Only a trailing blank, and only one: a blank line someone typed in the
  # middle of their config is theirs.
  (while (and (> (length kept) 1) (empty? (string/trim (last kept))))
    (array/pop kept))
  (def written (seq [[id socket] :in pairs]
                 (string marker " terminal " id " socket " socket)))
  (if (empty? written)
    kept
    (array ;kept ;(if (or (empty? kept) (empty? (string/trim (last kept))))
                    []
                    [""])
           ;written)))

(defn read-config
  "The config file as a list of lines, creating it if it is not there."
  [path]
  (unless (os/stat path :mode)
    (spit path (string (string/trimr starter "\n") "\n")))
  (def text (try (slurp path) ([_] "")))
  # A trailing newline is one empty string on the end, which would show as a
  # phantom blank row in the editor.
  (def lines (string/split "\n" text))
  (if (and (> (length lines) 0) (= "" (last lines)))
    (slice lines 0 -2)
    lines))

(defn write-config
  ``Write the lines back, as a real edit to the real file.

  A WRITE THAT CHANGES NOTHING DOES NOT HAPPEN. The config lives in the tree
  the watcher watches -- it is the drawing's own source, and hiding it from a
  tool for seeing a directory would be the wrong trade -- so every `spit`
  moves its mtime, and a moved mtime is indistinguishable from someone
  editing the file. That is a loop: the page saves, the watcher announces
  that the source changed, the page redraws, its open panes re-register
  themselves in the file (see `remember-terminals`), and it saves again. One
  delete click cost five full redraws.

  Most of those writes carry no news. `remember-panes` runs whenever a pane
  is made and writes the same list it wrote last time; only the FIRST write
  after a real change says anything. Comparing before writing is what turns
  the rest into nothing at all, and it is worth more than the loop it closes:
  no write here ever announces a change it did not make.

  A REAL EDIT STILL REDRAWS, which is the point of the watcher and is not
  what this touches -- different bytes still reach the disk, still move the
  mtime, and still tell the page.``
  [path lines]
  (def next (string (string/join lines "\n") "\n"))
  # `slurp` HANDS BACK A BUFFER, and a buffer is never `=` to a string in
  # Janet however identical the bytes -- the first version of this compared
  # the two directly, was false every time, and skipped nothing at all.
  # `string` on the way out is what makes the comparison about content.
  (def now (try (string (slurp path)) ([_] nil)))
  (unless (= next now)
    (spit path next)))

# Which actions are worth a redraw. Inserting adds an EMPTY line, which by
# definition draws the same graph -- so it saves and returns immediately
# instead of making you wait to see nothing change. Deleting is not here by
# oversight: removing a line really can change the picture.
(def draws {"run" true "delete" true "reorder" true "regenerate" true})

(defn edit
  ``Apply one button press to the file's lines.

  The browser sends the lines it is showing along with the action, so an
  in-place typo and the button that acts on it arrive together -- there is no
  separate save step to forget.

  'run', 'reorder', 'regenerate' and 'check' change no text: every action
  re-runs the file anyway, so running IS just saving what is on screen, and
  `check` is running WITHOUT the saving.``
  [lines action index]
  (def out (array ;lines))
  (cond
    (or (= action "run") (= action "reorder") (= action "regenerate")
        (= action "check")) out
    (= action "insert-above") (array/insert out (max 0 index) "")
    (= action "insert-below") (array/insert out (min (length out) (+ index 1)) "")
    (= action "delete") (if (and (>= index 0) (< index (length out)))
                          (array/remove out index)
                          out)
    (errorf "unknown action '%s'" action)))
