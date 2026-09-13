(import ./config)
(import ./graphviz)
(import ./json)

(defn visible [lines]
  (filter |(not (config/note? $)) lines))

(defn- uncomment [line]
  (def text (string/trim line))
  (if (string/has-prefix? "#" text) (string/triml (string/slice text 1)) text))

(defn- normalise [name]
  (string/replace-all "/" "." (string/trim name "./")))

(defn model [lines]
  (def plain (map uncomment lines))
  (def nodes @[])
  (def prefixes @{})
  (def edges @[])
  (eachp [index line] lines
    (unless (or (config/note? line) (empty? (string/trim line)))
      (def text (plain index))
      (def form (config/command text))
      (def commented (string/has-prefix? "#" (string/trim line)))
      (def verb (when form (first form)))
      (def arg (when form (get form 1)))
      (def target (when arg (normalise arg)))
      (def id (string "c" index))
      (def label (if form
        (string verb
                     (if (and (= verb :box) (get form 2)) (string " " (get form 2)) ""))
        text))
      (array/push nodes {:id id :kind "command" :label label :lines [index]
                         :commented commented :invalid (not form) :text line})
      (when target
        (def parts (string/split "." target))
        (var parent nil)
        (for i 1 (+ 1 (length parts))
          (def prefix (string/join (slice parts 0 i) "."))
          (def pid (string "p:" prefix))
          (unless (prefixes prefix)
            (def node @{:id pid :kind "prefix" :label (if (empty? prefix) "all" prefix)
                        :lines @[] :commented true})
            (put prefixes prefix node)
            (array/push nodes node)
            (when parent (array/push edges [parent pid])))
          (def node (prefixes prefix))
          (array/push (node :lines) index)
          (unless commented (put node :commented false))
          (set parent pid))
        (array/push edges [parent id]))))
  {:nodes nodes :edges edges})

(defn- rename-line [line before after]
  (def form (config/command (uncomment line)))
  (def path (normalise (get form 1)))
  (def renamed (string after (string/slice path (length before))))
  (def [start end] (peg/match
    '(* (any (set " \t")) (? (* "#" (any (set " \t"))))
        (some (if-not (set " \t") 1)) (some (set " \t")) (position)
        (+ (* `"` (any (if-not `"` 1)) `"`)
           (some (if-not (+ (set " \t\r\n#") -1) 1))) (position)) line))
  (def quoted (or (= (line start) (chr `"`)) (peg/find '(set " \t#()") renamed)))
  (string (string/slice line 0 start)
          (if quoted (string `"` renamed `"`) renamed)
          (string/slice line end)))

(defn change [disk sent &opt root]
  (def action (get sent "action"))
  (if (= action "append")
    (let [text (string/trim (get sent "command" ""))]
      (def undo (string/has-prefix? "un" text))
      (def form (config/command (if undo (string/slice text 2) text)))
      (when (or (empty? text) (string/find "\n" text) (string/find "\r" text)
                (not form) (and undo (not (string/has-prefix? (string "un" (first form)) text))))
        (error "Enter one command, such as fold src.web or unfold src.web"))
      (defn matches? [line]
        (def candidate (unless (config/note? line) (config/command line)))
        (and candidate (= (tuple ;form) (tuple ;candidate))))
      (if undo
        (config/unique-lines
          (map (fn [line]
            (if (matches? line) (string "#" line) line)) disk))
        (if (some matches? disk)
          disk
          (do
            (def [_ problems] (config/run [text] root))
            (when-let [problem (problems 0)] (error problem))
            (var restored false)
            (def next (map (fn [line]
              (if (and (string/has-prefix? "#" (string/triml line)) (matches? (uncomment line)))
                (do
                  (set restored true)
                  (def at (string/find "#" line))
                  (string (string/slice line 0 at) (string/slice line (+ at 1))))
                line)) disk))
            (config/unique-lines (if restored next (array ;disk text)))))))
    (do
      (def lines (visible disk))
      (unless (= (tuple ;lines) (tuple ;(get sent "base" [])))
        (error "Configuration changed. Reloaded the graph; try again."))
      (def node (find |(= ($ :id) (get sent "node")) ((model lines) :nodes)))
      (unless node (error "This configuration node no longer exists"))
      (def rename (= action "rename-prefix"))
      (def segment (when rename (string/trim (get sent "label" ""))))
      (when rename
        (unless (= (node :kind) "prefix") (error "Choose a prefix label to rename"))
        (when (or (some |(empty? (string/trim $)) (string/split "." segment))
                  (peg/find '(set "/\r\n\"\x00") segment))
          (error "Enter a dotted name with nonempty segments, without slashes, quotes, or line breaks")))
      (def before (when rename (string/slice (node :id) 2)))
      (def replacement (when rename
        (string/join (array ;(slice (string/split "." before) 0 -2) segment) ".")))
      (def chosen (tabseq [index :in (node :lines)] index true))
      (var index -1)
      (def out @[])
      (each line disk
        (if (config/note? line)
          (array/push out line)
          (do
            (++ index)
            (cond
              (not (chosen index)) (array/push out line)
              rename (array/push out (if (= before replacement) line (rename-line line before replacement)))
              (= action "subtree-delete") nil
              (= action "subtree-comment")
              (array/push out
                (if (node :commented) (uncomment line)
                  (if (string/has-prefix? "#" (string/trim line)) line (string "#" line))))
              (error "Unknown subtree action")))))
      (config/unique-lines out))))

(defn- html [text]
  (->> text (string/replace-all "&" "&amp;")
       (string/replace-all "<" "&lt;") (string/replace-all ">" "&gt;")
       (string/replace-all "\"" "&quot;")))

(defn render [model]
  (def dot @["digraph config { graph [bgcolor=transparent, pad=0.25, rankdir=TB, nodesep=0.35, ranksep=0.5]; node [shape=ellipse, width=1.65, fontname=Parkinsans, fontsize=14, margin=\"0.1,0.02\", penwidth=1.2]; edge [arrowsize=0.65, penwidth=1.1];"])
  (each node (model :nodes)
    (array/push dot (string (json/encode (node :id))
      " [label=<<TABLE BORDER=\"0\" CELLBORDER=\"0\" CELLSPACING=\"0\" CELLPADDING=\"4\">"
      "<TR><TD COLSPAN=\"2\">" (html (node :label)) "</TD></TR>"
      "<TR><TD WIDTH=\"28\" HEIGHT=\"28\">#</TD><TD WIDTH=\"28\" HEIGHT=\"28\">×</TD></TR></TABLE>>];")))
  (each [from to] (model :edges)
    (array/push dot (string (json/encode from) " -> " (json/encode to) ";")))
  (def parents (tabseq [[from to] :in (model :edges)] from true))
  (array/push dot "{rank=sink;")
  (each node (model :nodes)
    (unless (parents (node :id))
      (array/push dot (string (json/encode (node :id)) ";"))))
  (array/push dot "}")
  (array/push dot "}")
  (graphviz/render (string/join dot "\n")))
