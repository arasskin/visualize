# The config language: pure Janet, six verbs, no sandbox.
#
#     (show-lines)
#     (group src.term)
#     (group web)
#     (group test) (hide test)
#
# WHAT IT IS. A config file is Janet source, evaluated in a real environment
# with the root bindings available. The verbs are MACROS, which is the whole
# trick: a macro receives its arguments unevaluated, so `(group web)` gets
# the SYMBOL `web` and stringifies it, and a bare name is a name without
# anything having to rewrite the source first.
#
# WHAT THAT REPLACED. The verbs used to be functions in a hand-built
# environment holding fifty whitelisted builtins, and a `literalise` pass
# walked every form turning unbound symbols into strings -- which meant
# tracking which symbols were bound by `each`, `let`, `defn` and friends so a
# loop variable did not become the string "n". About two hundred lines to
# make bare names work and keep a config from reaching `os`. Macros do the
# first for free; the second is now simply not done.
#
# THE SANDBOX IS GONE, deliberately and with the cost known. A config can
# call anything Janet can call, and the config is editable through the web
# page -- so anyone who can reach the page can run code as this process. That
# is the same trust boundary as the editor in your terminal, and the server
# binds to 127.0.0.1, but it is a real change from a config that could only
# describe a picture.
#
# EACH LINE IS ITS OWN PROGRAM. A config is evaluated a line at a time so a
# mistake on line three does not cost you lines one and two, and so the
# editor can point at the line that failed. That is why `run` takes a list of
# lines rather than a file.

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
    :sized-coloring false
    # Whether nodes carry their colour as a fill or just an outline. Outlines
    # by default: a wall of saturated boxes is harder to read the EDGES over.
    :filled false
    # Prefixes to narrow to. Empty means no filter, which is the WHOLE graph --
    # so a config saying nothing shows the externals too.
    :only @[]
    :font nil})

(defn- reflow
  ``Give every automatic group a hue no other group is using.

  Done over the whole list rather than once at assignment, because a colour
  named LATER can collide with one already handed out automatically --
  `(group a) (group b red)` where `a` happened to draw red. An explicit
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

(defn- as-name
  ``A verb's argument as the string the prefix matcher wants.

  Accepts a string, a symbol or a keyword, so a config can say the same thing
  whichever way is natural -- and because the macros below hand symbols
  through unevaluated, this is where `(group web)` becomes "web".``
  [value]
  (case (type value)
    :string value
    :symbol (string value)
    :keyword (string value)
    :buffer (string value)
    (errorf "expected a name like ~.Thing, got %q" value)))

# THE STATE THE VERBS WRITE TO. A dynamic binding rather than an argument,
# because a macro expands into a call the config author never sees -- and
# threading a state parameter through expansions would put it in their source.
(def- current (gensym))

# THIS MODULE'S OWN ENVIRONMENT, captured at load and handed to `eval` as its
# second argument. A config needs an environment where the verbs below are
# bound as well as everything Janet has, and this file's env is exactly that.
#
# CAPTURED HERE, NOT IN `eval-line`: `curenv` answers with the environment of
# whoever is running, so asking inside the function returns the caller's. And
# passed as an ARGUMENT, not through a dyn -- `eval` takes `(eval form &opt
# env)` and consults no dynamic binding, which cost an hour of setting
# `:current-env` and watching every verb come back "unknown symbol".
(def- verbs (curenv))

(defn- literal
  ``A macro argument as source that evaluates to itself.

  A bare `web` arrives as a symbol and becomes the string "web". Anything
  else -- a string, a keyword, a call like `(string "~." n)` -- is passed
  through untouched and evaluates normally.

  BARE NAMES AND LEXICAL VARIABLES CANNOT BOTH WORK, and this is the trade.
  Janet does not expose the compiler's lexical scope to a macro: inside
  `(each f [...] (hide f))` the argument `f` is a symbol, and inside
  `(hide web)` so is `web`, and at expansion time nothing distinguishes
  them -- `dyn`, `curenv` and a compile-time lookup all answer "unbound" for
  both. Deferring to runtime does not help either: a bound local resolves
  but a free symbol is a COMPILE error, so the expansion never runs to
  catch it.

  So the bare name wins, because that is what a config is mostly made of,
  and a config that wants a variable's VALUE unquotes it:

      (each f ["SwiftUI" "WebKit"] (hide ,f))

  which is Janet's own notation for "not the symbol, the thing".``
  [form]
  (cond
    (symbol? form) (string form)
    # `,f` reads as (unquote f) -- the escape hatch above. Hand the inner
    # form through so it evaluates.
    (and (tuple? form) (= :parens (tuple/type form))
         (= 'unquote (first form)))
    (in form 1)
    form))

(defmacro hide
  "(hide prefix) -- take a file, directory or external out of the graph."
  [name]
  ~(let [state (dyn ',current)
         text (,as-name ,(literal name))]
     (unless (index-of text (state :hidden))
       (array/push (state :hidden) text))
     nil))

(defmacro show-only
  `(show-only prefix) -- narrow the graph to this prefix. (show-only "~") is ours only.`
  [name]
  ~(let [state (dyn ',current)
         text (,as-name ,(literal name))]
     (unless (index-of text (state :only))
       (array/push (state :only) text))
     nil))

(defmacro group
  "(group prefix &opt color) -- box these files together, in `color` or the next palette hue."
  [name &opt wanted]
  ~(let [state (dyn ',current)
         text (,as-name ,(literal name))
         wanted ,(if wanted (literal wanted) nil)]
     (var hue "")
     (if wanted
       (let [resolved (,color/as-hex (,as-name wanted))]
         (unless resolved
           (errorf "'%s' is not a colour -- use #rrggbb or a name like blue"
                   (,as-name wanted)))
         (when (= resolved ,color/ungrouped)
           (errorf "%s is what ungrouped nodes already wear -- the group would be invisible; pick another colour"
                   ,color/ungrouped))
         (put (state :chosen) text true)
         (set hue resolved))
       (put (state :chosen) text nil))
     (put state :groups
          (array ;(filter |(not= ($ :prefix) text) (state :groups))
                 {:prefix text :color hue}))
     (,reflow state)
     nil))

(defmacro fill-color
  "(fill-color) -- fill nodes with their group's colour instead of outlining them."
  []
  ~(do (put (dyn ',current) :filled true) nil))

(defmacro show-lines
  "(show-lines) -- write each file's line count on its label."
  []
  ~(do (put (dyn ',current) :sized true) nil))

(defmacro show-lines-coloring
  "(show-lines-coloring) -- shade by line count rather than by edge count."
  []
  ~(do (put (dyn ',current) :sized true)
       (put (dyn ',current) :sized-coloring true)
       nil))

(defmacro font
  "(font name) -- draw the graph in a different typeface."
  [name]
  ~(do (put (dyn ',current) :font (,as-name ,(literal name))) nil))

(defn- complain
  ``An error value as one readable line.

  Janet hands back a string for `error`, but a struct with :error for a
  compile failure, and the raw form of either is not something to show
  somebody editing a config in a browser.``
  [err]
  (def text (if (or (string? err) (buffer? err))
              (string err)
              (string/format "%q" err)))
  # Compile errors arrive prefixed with a source name and position that names
  # a temporary buffer -- meaningless to the reader, since the line they are
  # looking at is right there.
  (def cleaned (peg/replace ~(* (any (if-not ":" 1)) ":" (some :d) ":" (some :d) ": ")
                            "" text))
  (string/trim (string cleaned)))

(defn eval-line
  ``Run one line against `state`. Returns nil, or a complaint about the line.

  ONE LINE IS THE UNIT. A config is a list of independent statements, so the
  line is what gets parsed, what gets evaluated, and what an error is
  attributed to -- which is what makes "this line is wrong" a thing the
  editor can point at.``
  [line state]
  (if (empty? (string/trim line))
    nil
    (do
      # THE TWO NOTATIONS JANET'S READER STEALS, refused rather than
      # misread. `~` begins a quasiquote and `#` begins a comment, so
      # `(hide ~.A)` reads as a quote of the symbol `.A` and `(group web
      # #22a6f2)` reads as a group with no colour at all -- both of which
      # produce a plausible wrong answer in silence. Caught here and named.
      (def bare-tilde (peg/find ~(* (+ "(" " ") "~" (+ ")" " " -1)) line))
      (def dotted-tilde (peg/find ~(* (+ "(" " ") "~" ".") line))
      (def hash-colour (peg/find ~(* (+ "(" " ") "#" (6 (range "09" "af" "AF"))) line))
      (cond
        (or bare-tilde dotted-tilde)
        (string "`~` is Janet's quasiquote -- write it as a string: "
                "(hide \"~.A\") or (show-only \"~\")")
        hash-colour
        (string "`#` starts a comment -- write a colour as a string: "
                "(group web \"#22a6f2\")")
        (try
          (do
            # The verbs reach the state through a dynamic binding, so the
            # config's own source never mentions it.
            #
            # Evaluated in this module's environment -- see `verbs` -- so a
            # config sees the verbs and everything Janet has.
            (with-dyns [current state]
              (def p (parser/new))
              (parser/consume p line)
              (parser/eof p)
              (while (parser/has-more p)
                (eval (parser/produce p) verbs)))
            nil)
          ([err] (complain err)))))))

(defn run
  ``Every line, in order, against one fresh state.

  Returns [state problems], where `problems` maps a line's INDEX to what went
  wrong with it -- the index because that is what the editor draws against.``
  [lines]
  (def state (new-state))
  (def problems @{})
  (eachp [i line] lines
    (when-let [wrong (eval-line line state)]
      (put problems i wrong)))
  [state problems])
