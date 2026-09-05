(import ./color)
(import ./names)

(defn new-state

  []
  @{:hidden @[]
    :groups @[]

    :root nil

    :chosen @{}

    :sized false

    :only @[]

    :folded @[]

    :animated false

    :palette color/for-drawing

    :aliases @[]})

(defn- reflow

  [state]

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

                            (spare (% taken (length spare))))]
                  (++ taken)
                  {:prefix (g :prefix) :color hue})))
            (state :groups))))

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

(def grammar
  ~{:space (any (set " \t"))

    :bare (<- (some (if-not (+ (set " \t()\"#") -1) 1)))

    :alias (<- (some (if-not (+ (set " \t()\"") -1) 1)))
    :quoted (* `"` (<- (any (if-not `"` 1))) `"`)
    :name (* :space (+ :quoted :bare) :space)

    :color (* :space (+ :quoted :bare) :space)

    :verb (* "(" :space ,(tuple ;(array '+ ;verb-rules)) ")")

    :comment (* "#" (any 1))
    :main (* :space (any (* :verb :space)) (? :comment) -1)})

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

  []
  (map (fn [spec]
         {:name (spec :name)
          :usage (usage spec)
          :args (map |(string $) (spec :args))
          :blurb (spec :blurb)})
       verb-specs))

(defn colours

  []
  (sorted (keys color/named)))

(defn- normalise

  [text]
  (string/replace-all "/" "." (string/trim text "./")))

(defn expand-aliases

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

  [dir name]
  (def head (first (string/split "." name)))
  (when (empty? head) (break false))
  (var found false)
  (each entry (try (os/dir dir) ([_] []))
    (unless found
      (def named (normalise entry))
      (when (or (= named head)

                (= (normalise (names/stem entry)) head))
        (set found true))))
  found)

(defn- apply-verb

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

        (empty? full)
        "a prefix needs something to stand for -- (prefix name p), like (prefix ~ src.visualize)"

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

    :visualize
    (let [named (string/trim (or (first args) "") "./")]
      (cond
        (empty? named)
        "a nested project needs a directory -- (visualize p), like (visualize lib)"

        (and (state :root) (not (nested-dir (state :root) named)))
        (string "there is no `" named "` here -- (visualize p) names a "
                "directory of this project")

        nil))))

(defn- complain

  [line]
  (def text (string/trim line))

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

(def marker "@visualize")

(defn note?

  [line]
  (string/has-prefix? marker (string/trim (or line ""))))

(defn eval-line

  [line state &opt only]
  (def text (string/trim (code-of line)))
  (cond
    (empty? text) nil
    (string/has-prefix? "#" text) nil

    (note? text) nil
    (if-let [forms (peg/match grammar text)]
      (do
        (var wrong nil)

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

(def config-name "visualize.conf")

(defn- visualize-targets

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

  [root p]
  (default root "")
  (def dir (string/trim p "./"))
  (when (or (empty? root) (empty? dir)) (break []))
  (def here (nested-dir root dir))
  (unless here (break []))

  (def here-dir here)
  (def path (string here "/" config-name))
  (unless (os/stat path :mode) (break []))
  (def text (try (slurp path) ([_] nil)))
  (unless text (break []))

  (def prefix (normalise dir))
  (def out @[])

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

          (unless (or (empty? args) (= verb :prefix))
            (def spec (find |(= ($ :name) (string verb)) verb-specs))
            (def kinds (if spec (spec :args) []))

            (def moved
              (seq [[at arg] :pairs args]
                (if (= (get kinds at) :name)

                  (let [raw (string/trim (expand-aliases aliases arg))
                        marked (or (names/external? raw) (= raw "?"))
                        full (normalise raw)]

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

          (array/push out line)
          (each p targets
            (each nested (nested-lines root p)
              (array/push next nested))))))
    (set todo next))
  out)

(defn run

  [lines &opt root]

  (def lines (if root (pasted lines root) lines))
  (def state (new-state))
  (put state :root root)
  (def problems @{})

  (eachp [i line] lines
    (when-let [wrong (eval-line line state :prefix)]
      (put problems i wrong)))

  (eachp [i line] lines
    (when-let [wrong (eval-line line state)]

      (unless (problems i) (put problems i wrong))))
  [state problems])

(def config-title "visualize")

(def starter
  ``# One verb per line. Press ? for the full list.
# A name is the dotted path a node shows: (box src.parsers) draws a box
# round that directory, (hide src.test) drops it. A name from OUTSIDE the
# tree wears the ?. the drawing shows it with: (hide ?.os), (box ?.SwiftUI).
# Comment out with '#'.
(lines)
``)

(defn notes

  [lines]
  (seq [line :in lines :when (note? line)]
    (filter |(not (empty? $))
            (string/split " " (string/trim (string/slice (string/trim line)
                                                         (length marker)))))))

(defn terminals

  [lines]
  (seq [words :in (notes lines)
        :when (and (= "terminal" (get words 0))
                   (= "socket" (get words 2))
                   (get words 1) (get words 3))]
    [(get words 1) (get words 3)]))

(defn labels

  [lines]
  (def out @{})
  (each line lines
    (when (note? line)
      (def rest (string/trim (string/slice (string/trim line) (length marker))))
      (when (string/has-prefix? "label " rest)
        (def body (string/slice rest (length "label ")))
        (def at (string/find " " body))
        (when at
          (def id (string/slice body 0 at))
          (def text (string/trim (string/slice body (+ at 1))))
          (unless (or (empty? id) (empty? text)) (put out id text))))))
  out)

(defn remember-labels

  [lines named]
  (def kept (array ;(filter |(not (and (note? $)
                                       (string/has-prefix?
                                         "label "
                                         (string/trim
                                           (string/slice (string/trim $)
                                                         (length marker))))))
                            lines)))
  (def written (seq [id :in (sorted (keys named))
                     :let [text (string/trim (or (get named id) ""))]
                     :when (not (empty? text))]
                 (string marker " label " id " " text)))
  (if (empty? written)
    kept
    (array ;kept ;(if (or (empty? kept) (empty? (string/trim (last kept))))
                    []
                    [""])
           ;written)))

(defn remember-terminals

  [lines pairs]
  (def kept (array ;(filter |(not (note? $)) lines)))

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

  [path]
  (unless (os/stat path :mode)
    (spit path (string (string/trimr starter "\n") "\n")))
  (def text (try (slurp path) ([_] "")))

  (def lines (string/split "\n" text))
  (if (and (> (length lines) 0) (= "" (last lines)))
    (slice lines 0 -2)
    lines))

(defn write-config

  [path lines]
  (def next (string (string/join lines "\n") "\n"))

  (def now (try (string (slurp path)) ([_] nil)))
  (unless (= next now)
    (spit path next)))

(def draws {"run" true "delete" true "reorder" true "regenerate" true})

(defn edit

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
