# The config language: real Janet, in an environment that only has these verbs.
#
# The originals had a hand-written reader for a flat s-expression dialect --
# atoms only, no nesting, six functions. It was small and it was honest about
# being small. This is Janet instead, which costs nothing (the reader is the
# host language's) and buys the thing the flat dialect could never do:
#
#     (each name ["Core" "UI" "Net"] (group (string "~." name)))
#     (def mine "~.OttoClip")
#     (unless (dyn :ci) (show-lines))
#
# The verbs are the same six, so every config the Python tools accept still
# reads the same way here.
#
# WHAT `~` IS. In a flat reader `~` was just a character in an atom. Janet
# reads `~x` as (quasiquote x), so the tilde forms are given real bindings
# instead: `~` is the string "~", and `~.OttoClip` is a symbol the environment
# resolves. Rather than predeclare every possible one, the evaluator catches
# the "unknown symbol" case and turns the symbol's NAME into the string the
# verbs already expect -- so `~.a.b` works without anything knowing in advance
# that a.b exists.
#
# SAFETY. The environment holds the six verbs, a handful of pure helpers, and
# nothing else -- no file, no os, no net. A config is a thing you edit through
# a web page, so it should not be able to delete your home directory when a
# stray character turns it into a different program.

(import ./color)
(import ./tilde)

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
    :font nil
    # What to run in the harness window, as argv. Nil means the built-in
    # default; the config names it because which agent you want is a property
    # of the project, not of the tool.
    :harness nil
    # Which layout draws the graph. Nil means graphviz, which is what a
    # config that says nothing has always got.
    :layout nil})

(defn- reflow
  ``Give every automatic group a hue no other group is using.

  Done over the whole list rather than once at assignment, because a colour
  named LATER can collide with one already handed out automatically --
  `(group ~.a) (group ~.b red)` where ~.a happened to draw red. An explicit
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

  Accepts a string, a symbol (`~.OttoClip` arrives as one) or a keyword, so a
  config can say the same thing whichever way is natural.``
  [value]
  (case (type value)
    :string value
    :symbol (string value)
    :keyword (string value)
    :buffer (string value)
    (errorf "expected a name like ~.Thing, got %q" value)))


# A binding as the environment table wants it. `defn` inside a function makes
# a local, not a module binding, so each verb is installed by hand -- which is
# also where its docstring comes from, and `(doc hide)` works in a config.
(defn- install [env name value docs]
  (put env (symbol name) @{:value value :doc docs}))

(defn environment
  ``The environment a config runs in: the verbs, and a few pure helpers.

  Deliberately NOT a copy of the root environment. A config is edited through
  a web page, and the blast radius of a typo there should be a wrong-looking
  graph, not a deleted directory -- so there is no `os`, no `file`, no `net`
  and no `import` in here.``
  [state]

  (defn as [value] (as-name value))

  (def env @{})

  (defn hide [name]
    (def text (as name))
    (unless (index-of text (state :hidden)) (array/push (state :hidden) text))
    nil)

  (defn show-only [name]
    (def text (as name))
    (unless (index-of text (state :only)) (array/push (state :only) text))
    nil)

  (defn group [name &opt wanted]
    (def text (as name))
    (var hue "")
    (if wanted
      (let [resolved (color/as-hex (as wanted))]
        (unless resolved
          (errorf "'%s' is not a colour -- use #rrggbb or a name like blue" (as wanted)))
        (when (= resolved color/ungrouped)
          (errorf "%s is what ungrouped nodes already wear -- the group would be invisible; pick another colour"
                  color/ungrouped))
        (put (state :chosen) text true)
        (set hue resolved))
      (put (state :chosen) text nil))
    (put state :groups
         (array ;(filter |(not= ($ :prefix) text) (state :groups))
                {:prefix text :color hue}))
    (reflow state)
    nil)

  (defn fill-color [] (put state :filled true) nil)
  (defn show-lines [] (put state :sized true) nil)
  (defn show-lines-coloring []
    (put state :sized true) (put state :sized-coloring true) nil)
  (defn font [name] (put state :font (as name)) nil)

  (defn layout [name]
    ``Which layout draws the graph.

    `(layout graphviz)` is the default -- a real layered layout, and the
    reason `dot` is on the requirements list. `(layout force)` needs
    nothing installed: nodes repel, edges pull, and the picture settles.
    It shows relatedness rather than direction of dependency, so it reads
    better for a tangle than for a hierarchy.``
    (put state :layout (as name))
    nil)

  (defn harness [name & args]
    ``What to run in the harness window.

    `(harness "claude")`, `(harness "pi")`, or any command with arguments.
    Nothing about the terminal knows which one it is running -- the pty takes
    argv and the emulator takes bytes -- so this is a list of strings rather
    than a choice from a fixed set.``
    (put state :harness (map as [name ;args]))
    nil)

  (install env "hide" hide
           "(hide prefix) -- take a file, directory or external out of the graph.")
  (install env "show-only" show-only
           "(show-only prefix) -- narrow the graph to this prefix. (show-only ~) is ours only.")
  (install env "group" group
           "(group prefix &opt color) -- box these files together, in `color` or the next palette hue.")
  (install env "fill-color" fill-color
           "(fill-color) -- fill nodes with their group's colour instead of outlining them.")
  (install env "show-lines" show-lines
           "(show-lines) -- write each file's line count on its label.")
  (install env "show-lines-coloring" show-lines-coloring
           "(show-lines-coloring) -- shade by line count rather than by edge count.")
  (install env "font" font
           "(font name) -- draw the graph in a different typeface.")
  (install env "harness" harness
           "(harness cmd & args) -- what to run in the terminal window, e.g. (harness claude) or (harness pi).")
  (install env "layout" layout
           "(layout name) -- graphviz (default, needs dot) or force (needs nothing).")

  # `~` alone, for a config that quotes it or reaches it through a helper.
  # The bare `(show-only ~)` form never gets this far -- src/tilde.janet turns
  # it into a string before the reader sees it -- but a config that says
  # `(def mine ~)` deserves to work.
  (install env "~" "~" "The project itself: everything scanned, no externals.")

  # Pure helpers, so a config can compute rather than only declare. Nothing
  # here touches the filesystem, the network or the process.
  (each name ["string" "string/join" "string/replace" "string/replace-all"
              "string/has-prefix?" "string/has-suffix?" "string/split"
              "each" "map" "filter" "range" "length" "when" "unless" "if"
              "do" "let" "def" "var" "set" "fn" "defn" "seq" "loop"
              "+" "-" "*" "/" "=" "not=" "<" ">" "<=" ">=" "not" "and" "or"
              "true" "false" "nil" "print" "pp" "string/format" "keys" "values"
              "array" "tuple" "table" "struct" "get" "put" "indexed?" "quote"
              "quasiquote" "unquote" "splice" "upscope"]
    (when-let [found (get root-env (symbol name))]
      (put env (symbol name) found)))

  env)

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

# Forms that introduce names. A symbol bound by one of these is a real
# variable everywhere inside it, so `literalise` must not turn it into a
# string -- `(each n [...] (group n))` would otherwise group a file called
# "n".
# Where each binding form keeps the names it introduces. `:first` is the one
# slot after the head (`(each n ...)`, `(def x ...)`); `:pairs` is a binding
# vector of name/value pairs (`(let [a 1 b 2] ...)`).
#
# Modelled per form rather than swept generically, because the two mistakes
# are not symmetric: missing a binding rewrites a loop variable into a string
# and silently changes what the config does, while over-collecting stops a
# real name from being a literal and produces a loud "unknown symbol".
(def- binders
  {'each :first 'eachp :first 'eachk :first 'for :first 'loop :first
   'seq :first 'generate :first 'accumulate :first
   'fn :params 'defn :params
   'let :pairs 'if-let :pairs 'when-let :pairs 'with-syms :pairs
   'def :first 'var :first 'defn- :params 'def- :first})

(defn- names-in
  "Every symbol in a destructuring pattern, which may be nested."
  [pattern]
  (def found @[])
  (defn sweep [node]
    (cond
      (symbol? node) (array/push found node)
      (indexed? node) (each part node (sweep part))))
  (sweep pattern)
  found)

(defn- collect-bindings
  "The names a binding form introduces, by where that form keeps them."
  [form]
  (def shape (binders (first form)))
  (case shape
    :first (if (> (length form) 1) (names-in (form 1)) [])
    :params (if (> (length form) 1)
              # `(fn [a b] ...)` and `(defn name [a b] ...)`: take every
              # bracketed vector before the body, so both shapes are covered.
              (mapcat names-in (filter |(and (indexed? $) (not (symbol? $)))
                                       (slice form 1 (min 3 (length form)))))
              [])
    :pairs (if (and (> (length form) 1) (indexed? (form 1)))
             # Names sit at the even POSITIONS of the binding vector; the odd
             # ones are the values they are bound to.
             (let [pairs (form 1)]
               (mapcat |(names-in (pairs $))
                       (filter even? (range (length pairs)))))
             [])
    []))

(defn- literalise
  ``Replace every unbound bare name in a form with the name itself.

  THE RULE THE PYTHON READER HAD: an atom that is not a verb is just a name.
  `(group SwiftUI)` groups the framework, `(group ~.A red)` names a colour,
  and neither SwiftUI nor red was ever a variable.

  Janet would read both as symbols and fail with "unknown symbol", so they are
  turned into strings here -- but ONLY when the environment has no binding for
  them. That is what keeps real code working: in

      (each n ["A" "B"] (group (string "~." n)))

  `each`, `group` and `string` are bound and stay symbols, `n` is bound by the
  loop... except that the loop binds it at RUNTIME and this runs before that.
  So a symbol in a binding position, and every symbol under a form that
  introduces one, is left alone; see `binders` below.

  A quoted form is left entirely alone, since its symbols are already data.``
  [form env &opt shadowed]
  (default shadowed @{})
  (cond
    (symbol? form)
    (if (or (env form) (shadowed form)) form (string form))

    (and (tuple? form) (= :parens (tuple/type form)) (not (empty? form)))
    (let [head (first form)]
      (cond
        # Data, not code. Its symbols mean themselves already.
        (index-of head ['quote 'quasiquote]) form
        # A form that BINDS names. Everything it binds is a real variable
        # inside it, so those symbols must not become strings.
        #
        # The HEAD is never rewritten either way: it is the thing being
        # called, and a call to a string is not a call.
        (binders head)
        (let [inner (merge @{} shadowed)]
          (each name (collect-bindings form) (put inner name true))
          (tuple head ;(map |(literalise $ env inner) (drop 1 form))))

        # Any other call. Its arguments are walked left to right, and a `def`
        # among them binds a name for everything AFTER it -- which is what
        # makes `(do (def mine "~.X") (hide mine))` work. `shadowed` is
        # therefore threaded through the sequence rather than shared by it.
        (let [running (merge @{} shadowed)]
          (tuple head
                 ;(map (fn [part]
                         (def done (literalise part env running))
                         (when (and (tuple? part) (not (empty? part))
                                    (binders (first part)))
                           (each name (collect-bindings part)
                             (put running name true)))
                         done)
                       (drop 1 form))))))

    (and (tuple? form) (= :brackets (tuple/type form)))
    (tuple/brackets ;(map |(literalise $ env shadowed) form))

    (array? form) (array ;(map |(literalise $ env shadowed) form))
    (struct? form) (struct ;(mapcat |[(literalise $ env shadowed)
                                      (literalise (form $) env shadowed)]
                                    (keys form)))
    (table? form) (table ;(mapcat |[(literalise $ env shadowed)
                                    (literalise (form $) env shadowed)]
                                  (keys form)))
    form))

(defn eval-line
  ``Run ONE line of config against `state`. Returns nil, or an error string.

  Per line rather than per file, because a bad line must not stop the rest:
  this runs on every page load, and one typo in a file you are midway through
  editing should leave you looking at a graph with one complaint attached
  rather than at an error page.

  ONE CONSEQUENCE WORTH KNOWING: a form cannot span lines, because a line is
  the unit that gets parsed. That is the same limit the Python tools had, and
  it is what makes "this line is wrong" a thing the editor can point at.``
  [line state]
  (if (empty? (string/trim line))
    nil
    (try
      (do
        (def source (tilde/prepare line))
        (def env (environment state))
        (def p (parser/new))
        (parser/consume p source)
        (parser/eof p)
        (var failure nil)
        (while (and (not failure) (parser/has-more p))
          (def form (literalise (parser/produce p) env))
          (def compiled (compile form env "config"))
          (if (function? compiled)
            (compiled)
            (set failure (complain (get compiled :error compiled)))))
        failure)
      ([err] (complain err)))))

(defn run
  ``Evaluate every line into a fresh state.

  Returns [state problems], where `problems` maps a 0-based line index to what
  went wrong there. The editor draws each complaint under its own line, so a
  message never has to name a number the reader then has to go and count.``
  [lines]
  (def state (new-state))
  (def problems @{})
  (eachp [index line] lines
    (when-let [failed (eval-line line state)]
      (put problems index failed)))
  [state problems])
