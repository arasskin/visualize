(import ./color)
(import ./names)
(import ./json)

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

    :palette color/for-drawing})

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
  [{:name "box" :args [:name :color?]
    :blurb "Draw a box around nodes starting with the provided prefix. Give an optional color (blue, red, ..., or rrggbb)."}
   {:name "fold" :args [:name]
    :blurb "Fold all nodes starting with prefix into one node aggregating line counts, incoming, and outgoing edges. Outer folds absorb nested folds regardless of declaration order."}
   {:name "hide" :args [:name]
    :blurb "Hide all nodes starting with the given prefix."}
   {:name "only" :args [:name]
    :blurb "Only visualize nodes that start with the provided prefix. Multiple onlys will create a union of nodes."}
   {:name "lines" :args []
    :blurb "Write each file's line count under its name."}
   {:name "animate" :args []
    :blurb "Flash a node when its file is new or has been written since the last drawing. Nothing flashes on the first drawing, since there is no earlier one to differ from."}
   {:name "visualize" :args [:name]
    :blurb "Draw the subproject at prefix using its own visualize_config. Every line of that file is read as though written here, with prefix put in front of the names it mentions, so a nested project keeps its own layout inside the bigger drawing."}])

(def- verb-rules
  (map (fn [spec]
         (def parts @[~(constant ,(keyword (spec :name))) (spec :name)])
         (each arg (spec :args)
             (case arg
               :name (array/push parts '(* :gap :name))
               :color? (array/push parts '(? (* :gap :color)))))
         (tuple ;(array '* ;parts)))
       (sorted-by |(- (length ($ :name))) verb-specs)))

(def grammar
  ~{:space (any (set " \t"))
    :gap (some (set " \t"))

    :bare (<- (some (if-not (+ (set " \t\r\n()\"#") -1) 1)))

    :quoted (* `"` (<- (any (if-not `"` 1))) `"`)
    :name (+ :quoted :bare)

    :color (+ :quoted :bare)

    :verb ,(tuple ;(array '+ ;verb-rules))

    :comment (* "#" (any 1))
    :main (* :space (? :verb) :space (? :comment) -1)})

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
             :name "prefix"
             :color? "color?"
             (string arg)))
         (spec :args)))
  (string/join (array (spec :name) ;parts) " "))

(defn docs

  []
  (map (fn [spec]
         {:name (spec :name)
          :usage (usage spec)
          :args (map |(string $) (spec :args))
          :blurb (string (spec :blurb) " Enter un" (usage spec)
                         " to comment out matching active commands; absent commands are left alone.")})
       verb-specs))

(defn colours

  []
  (sorted (keys color/named)))

(defn- normalise

  [text]
  (string/replace-all "/" "." (string/trim text "./")))

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
    (let [text (normalise (first args))]
      (unless (index-of text (state :hidden))
        (array/push (state :hidden) text))
      nil)

    :only
    (let [text (normalise (first args))]
      (unless (index-of text (state :only))
        (array/push (state :only) text))
      nil)

    :box
    (let [text (normalise (first args))
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

    :fold
    (let [text (normalise (first args))]
      (unless (index-of text (state :folded))
        (array/push (state :folded) text))
      nil)

    :lines (do (put state :sized true) nil)
    :animate (do (put state :animated true) nil)

    :visualize
    (let [named (string/trim (or (first args) "") "./")]
      (cond
        (empty? named)
        "a nested project needs a directory -- visualize prefix, like visualize lib"

        (and (state :root) (not (nested-dir (state :root) named)))
        (string "there is no `" named "` here -- visualize prefix names a "
                "directory of this project")

        nil))))

(defn- complain [line]
  (def verb (first (string/split " " (string/trim line))))
  (cond
    (and verb (not (index-of verb verbs)))
    (string "there is no verb `" verb "` -- try " (string/join verbs ", "))

    (and verb (index-of verb verbs))
    (let [spec (find |(= ($ :name) verb) verb-specs)]
      (string "`" verb "` takes " (usage spec)
              (if (empty? (spec :args))
                " and nothing else"
                (string " -- prefix matches the start of the labels on the graph, so"
                        " src.server catches every node under it"
                        (if (index-of :color? (spec :args))
                          ". A colour is rrggbb or a name like blue"
                          "")))))

    (string "use one command per line -- try " (string/join verbs ", "))))

(defn command [line]
  (def forms (peg/match grammar (string/trim (code-of line))))
  (when (and forms (not (empty? forms))) forms))

(def marker "@visualize")

(defn note?

  [line]
  (string/has-prefix? marker (string/trim (or line ""))))

(defn eval-line [line state]
  (def text (string/trim (code-of line)))
  (unless (or (empty? text) (note? text))
    (if-let [form (command text)]
      (apply-verb state form)
      (complain text))))

(def config-name "visualize_config")

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

          (unless (empty? args)
            (def spec (find |(= ($ :name) (string verb)) verb-specs))
            (def kinds (if spec (spec :args) []))

            (def moved
              (seq [[at arg] :pairs args]
                (if (= (get kinds at) :name)

                  (let [raw (string/trim arg)
                        marked (or (names/external? raw) (= raw "?"))
                        full (normalise raw)]

                    (if marked
                      (string full "@" prefix)
                      (if (not (holds? here-dir full))
                        full
                        (string prefix "." full))))
                  arg)))
            (array/push out
                        (string verb " " (string/join
                          (map |(if (peg/find '(set " \t#\"") $) (json/encode $) $) moved) " "))))))))
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
    (when-let [wrong (eval-line line state)]
      (put problems i wrong)))
  [state problems])

(def config-title "visualize")

(def starter
  "lines\n")

(defn- note-records [line]
  (unless (note? line) (break nil))
  (def text (string/trim (string/slice (string/trim line) (length marker))))
  (try
    (cond
      (string/has-prefix? "markdown " text)
      (let [documents (json/decode (string/slice text 9))]
        (when (dictionary? documents)
          (seq [[id file] :pairs documents] [id {:document file}])))
      (string/has-prefix? "label " text)
      (let [parts (peg/match '(* "label " (<- (some (if-not " " 1))) (some " ") (<- (any 1)) -1) text)]
        (when parts [[(parts 0) {:label (parts 1)}]]))
      (do
        (def tokens (peg/match
          ~{:gap (any (set " \t"))
            :quoted (/ (<- (* `"` (any (+ (* "\\" 1) (if-not `"` 1))) `"`)) ,json/decode)
            :bare (<- (some (if-not (set " \t\"") 1)))
            :main (* :gap (some (* (+ :quoted :bare) :gap)) -1)} text))
        (def kind (get tokens 0))
        (def id (get tokens 1))
        (when (and id (index-of kind ["terminal" "placement"]))
          (def fields @{})
          (if (= kind "placement")
            (put fields :placement (slice tokens 2))
            (do
              (var i 2)
              (while (< i (length tokens))
                (def key (keyword (tokens i)))
                (++ i)
                (case key
                  :placement
                  (let [start i]
                    (++ i)
                    (while (and (< i (length tokens)) (scan-number (tokens i))) (++ i))
                    (put fields key (slice tokens start i)))
                  (if (and (index-of key [:socket :label :document]) (< i (length tokens)))
                    (do (put fields key (tokens i)) (++ i))
                    (error "invalid terminal field"))))))
          [[id fields]])))
    ([_] nil)))

(defn- records [lines]
  (def out @{})
  (each line lines
    (each [id fields] (or (note-records line) [])
      (put out id (merge (get out id @{}) fields))))
  out)

(defn- note-token [value]
  (def text (string value))
  (if (or (empty? text) (peg/find '(set " \t\r\n\"\\#") text)) (json/encode text) text))

(defn- with-records [lines saved]
  (def out @[])
  (def written @{})
  (defn write-record [id]
    (def fields (saved id))
    (unless (or (written id) (empty? fields))
      (put written id true)
      (def words @[marker "terminal" (note-token id)])
      (each key [:socket :placement :label :document]
        (when-let [value (fields key)]
          (array/push words (string key))
          (if (= key :placement)
            (array/concat words (map note-token value))
            (array/push words (note-token value)))))
      (array/push out (string/join words " "))))
  (each line lines
    (if-let [old (note-records line)]
      (each [id _] old (write-record id))
      (array/push out line)))
  (while (and (not (empty? out)) (empty? (string/trim (last out)))) (array/pop out))
  (each id (sorted (keys saved)) (write-record id))
  out)

(defn- field-values [lines key]
  (def out @{})
  (eachp [id fields] (records lines)
    (when-let [value (fields key)] (put out id value)))
  out)

(defn- remember-field [lines key values]
  (def saved (records lines))
  (eachp [id fields] saved (put fields key (get values id)))
  (eachp [id value] values
    (unless (has-key? saved id) (put saved id @{key value})))
  (with-records lines saved))

(defn terminals [lines]
  (def sockets (field-values lines :socket))
  (seq [id :in (sorted (keys sockets))] [id (sockets id)]))

(defn remember-terminals [lines pairs]
  (remember-field lines :socket (table ;(mapcat identity pairs))))

(defn labels [lines] (field-values lines :label))

(defn remember-labels [lines named]
  (def values @{})
  (eachp [id text] named
    (def trimmed (string/trim (or text "")))
    (unless (empty? trimmed) (put values id trimmed)))
  (remember-field lines :label values))

(defn unique-lines [lines]
  (def seen @{})
  (filter (fn [line]
    (def text (string/trim line))
    (if (or (empty? text) (note? line))
      true
      (let [commented (string/has-prefix? "#" text)
            form (command (if commented (string/triml (string/slice text 1)) text))
            key (if form (tuple :command commented ;form) [:text text])]
        (if (seen key) false (do (put seen key true) true))))) lines))

(defn tidy-lines [lines]
  (def out @[])
  (each line (unique-lines (with-records lines (records lines)))
    (if (empty? (string/trim line))
      (when (and (not (empty? out)) (not (empty? (last out)))) (array/push out ""))
      (array/push out line)))
  (while (and (not (empty? out)) (empty? (last out))) (array/pop out))
  out)

(defn write-config

  [path lines]
  (def lines (tidy-lines lines))
  (def next (if (empty? lines) "" (string (string/join lines "\n") "\n")))
  (def now (try (string (slurp path)) ([_] nil)))
  (unless (= next now)
    (spit path next)))

(defn read-config

  [path]
  (unless (os/stat path :mode)
    (spit path (string (string/trimr starter "\n") "\n")))
  (def text (try (slurp path) ([_] "")))

  (def split (string/split "\n" text))
  (def lines (if (and (> (length split) 0) (= "" (last split)))
    (slice split 0 -2)
    split))
  (def unique (tidy-lines lines))
  (unless (= (tuple ;unique) (tuple ;lines)) (write-config path unique))
  unique)

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

(defn placements [lines]
  (def out @{})
  (eachp [id words] (field-values lines :placement)
      (def side (get words 0))
      (def x (scan-number (get words 1 "")))
      (def y (scan-number (get words 2 "")))
      (def w (scan-number (get words (if (index-of side ["top" "bottom"]) 2 3) "")))
      (def h (scan-number (get words (if (index-of side ["top" "bottom"]) 3 4) "")))
      (when (and id x (<= -100000 x 100000))
        (cond
          (and (index-of side ["top" "bottom"]) (>= x 0) (= x (math/floor x)))
          (put out id (if (and w h (> w 0) (> h 0)) [side x w h] [side x]))
          (and (= side "floating") y (<= -100000 y 100000))
          (put out id (if (and w h (> w 0) (> h 0)) [side x y w h] [side x y])))))
  out)

(defn remember-placements [lines positions]
  (remember-field lines :placement positions))

(defn markdown [lines]
  (field-values lines :document))

(defn remember-markdown [lines documents]
  (remember-field lines :document documents))
