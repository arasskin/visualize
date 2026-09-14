(import ./names)
(import ./json)

(def palette
  ["#ff4d6d"
   "#3bceac"
   "#ffa62b"
   "#8367c7"
   "#22a6f2"
   "#f5c518"
   "#ee6c4d"
   "#06d6a0"
   "#c04cfd"
   "#8ac926"
   "#ff70a6"
   "#118ab2"])

(def ungrouped "#7ea8c4")

(def named
  {"red" "#ff4d6d"
   "green" "#3bceac"
   "orange" "#ffa62b"
   "purple" "#8367c7"
   "blue" "#22a6f2"
   "yellow" "#f5c518"
   "orange-red" "#ee6c4d"
   "teal" "#06d6a0"
   "magenta" "#c04cfd"
   "yellow-green" "#8ac926"
   "pink" "#ff70a6"
   "dark-blue" "#118ab2"
   "grey" "#8d99ae"
   "gray" "#8d99ae"})

(def- hex-color (peg/compile ~(* (6 :h) -1)))

(defn as-hex

  [color]
  (def text (string/ascii-lower (string/trim (string color))))

  (if-let [hit (named text)]
    hit
    (when (peg/match hex-color text)
      (string "#" text))))

(defn- channels

  [color]
  (map |(scan-number (string "0x" (string/slice color $ (+ $ 2)))) [1 3 5]))

(defn- to-hex

  [parts]
  (string "#" (string/join (map |(string/format "%02x"
                                                (math/round (max 0 (min 255 $))))
                                parts))))

(defn tint

  [color weight]

  (def strength (+ 0.62 (* 0.38 (max 0 (min 1 weight)))))
  (to-hex (map |(- 255 (* (- 255 $) strength)) (channels color))))

(defn luminance

  [color]
  (def linear
    (map (fn [c]
           (def v (/ c 255))
           (if (<= v 0.04045)
             (/ v 12.92)
             (math/pow (/ (+ v 0.055) 1.055) 2.4)))
         (channels color)))
  (+ (* 0.2126 (linear 0)) (* 0.7152 (linear 1)) (* 0.0722 (linear 2))))

(defn contrast

  [one two]
  (def a (luminance one))
  (def b (luminance two))
  (def light (max a b))
  (def dark (min a b))
  (/ (+ light 0.05) (+ dark 0.05)))

(def- depths [0.34 0.26 0.20 0.15 0.10 0.05 0])

(defn ink

  [fill]
  (if (< (luminance fill) 0.18)
    "#f7f7f7"
    (do
      (def parts (channels fill))
      (or (some (fn [depth]
                  (def candidate (to-hex (map |(* $ depth) parts)))
                  (when (>= (contrast candidate fill) 4.5) candidate))
                depths)
          "#000000"))))

(defn ink-on-page

  [hue]
  (def parts (channels hue))
  (or (some (fn [depth]
              (def candidate (to-hex (map |(* $ depth) parts)))
              (when (>= (contrast candidate "#ffffff") 4.5) candidate))
            [0.55 0.45 0.34 0.26 0.20 0.15 0.10])
      "#000000"))

(defn ramp

  [counts]
  (def tiers (sorted (distinct (values counts))))
  (def last (- (length tiers) 1))
  (if (< last 1)
    (table ;(mapcat |[$ 1] (keys counts)))
    (do

      (def rank-of (table ;(mapcat |[(tiers $) (/ $ last)] (range (length tiers)))))
      (table ;(mapcat |[$ (rank-of (counts $))] (keys counts))))))

(def for-drawing
  {:ungrouped ungrouped
   :ink ink-on-page
   :tint |(tint $ 0.3)})

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

    :palette for-drawing})

(defn- reflow

  [state]

  (def spoken @{ungrouped true})
  (each g (state :groups)
    (when ((state :chosen) (g :prefix)) (put spoken (g :color) true)))
  (def free (filter |(not (spoken $)) palette))
  (def spare (filter |(not= $ ungrouped) palette))
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
  (sorted (keys named)))

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
        (let [resolved (as-hex wanted)]
          (cond
            (not resolved)
            (set wrong (string "'" wanted "' is not a colour -- "
                               "use rrggbb or a name like blue"))
            (= resolved ungrouped)
            (set wrong (string ungrouped " is what ungrouped nodes "
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

(defn visible [lines]
  (filter |(not (note? $)) lines))

(defn shown [lines problems]
  (var index 0)
  (def visible @[])
  (def moved @{})
  (eachp [i line] lines
    (unless (note? line)
      (array/push visible line)
      (when-let [why (get problems i)] (put moved index why))
      (++ index)))
  [visible moved])

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
    (def target (try (os/realpath path) ([_] path)))
    (def directory (string/join (slice (string/split "/" target) 0 -2) "/"))
    (def temporary (string (if (empty? directory) "." directory) "/.visualize-"
                          (string/join (map |(string/format "%02x" $) (os/cryptorand 12)) "")))
    (defer (when (os/stat temporary) (os/rm temporary))
      (spit temporary next)
      (when-let [permissions (os/stat target :permissions)] (os/chmod temporary permissions))
      (os/rename temporary target))))

(defn initialize [path]
  (unless (os/stat path :mode)
    (write-config path (string/split "\n" (string/trimr starter "\n")))))

(defn read-config [path]
  (def text (string (slurp path)))
  (def split (string/split "\n" text))
  (if (= "" (last split)) (slice split 0 -2) split))

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
