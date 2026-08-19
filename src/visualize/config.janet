# The config language: six verbs, parsed by a PEG.
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

(defn new-state
  ``What the config has said about the graph so far.

  Every field is ordered so that re-running a program is deterministic.``
  []
  @{:hidden @[]
    :groups @[]
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
   {:name "hide" :args [:name]
    :blurb "Hide all nodes starting with the given prefix."}
   {:name "only" :args [:name]
    :blurb "Only visualize nodes that start with the provided prefix. Multiple onlys will create a union of nodes."}
   {:name "lines" :args []
    :blurb "Write each file's line count under its name."}
   {:name "animate" :args []
    :blurb "Flash a node when its file is new or has been written since the last drawing. Nothing flashes on the first drawing, since there is no earlier one to differ from."}])

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
(def- grammar
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
  ``Every verb as {:name :usage :blurb}, in the order they are written above.

  FROM THE GRAMMAR'S OWN TABLE, so the help the page shows cannot describe a
  verb the parser does not have, or miss one it does. That is the whole
  reason `verb-specs` is a table of data rather than seven lines of PEG:
  documentation that is derived cannot go stale.``
  []
  (map (fn [spec]
         {:name (spec :name)
          :usage (usage spec)
          :blurb (spec :blurb)})
       verb-specs))

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

    :lines (do (put state :sized true) nil)
    :animate (do (put state :animated true) nil)))

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
  [lines]
  (def state (new-state))
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

(def config-name "visualize.conf")

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
# round that directory, (hide src.test) drops it. Any other name is
# literal, so (box SwiftUI) boxes the framework. Comment out with '#'.
(lines)
``)

# The starter above ends without a newline, because a long-string literal ends
# where it ends. Written as-is, the last line has nothing after it and the
# next edit through the page appends to it -- so the file is normalised on the
# way to disk exactly as `write-config` does it.

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
  "Write the lines back, as a real edit to the real file."
  [path lines]
  (spit path (string (string/join lines "\n") "\n")))

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
