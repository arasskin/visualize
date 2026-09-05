(import ./trace)

(def- font "Parkinsans")

(def- label-slope 4.4)
(def- label-intercept 8.0)

(def- min-width 0.86)
(def- points-per-inch 72)

(def- row-height 13.2)
(def- rows-padding 18.0)

(defn- label-height

  [label]
  (def rows (array ;(string/split "\n" (string label))))
  (var drawn (length rows))
  (var small 0)
  (when (and (> (length rows) 1)
             (peg/match ~(* (some (range "09")) -1) (last rows)))
    (array/pop rows)
    (++ small))
  (when (and (> (length rows) 1) (string/has-prefix? "." (last rows)))
    (array/pop rows)
    (++ small))

  (when (> small 1) (-= drawn (- small 1)))
  (max 0.62 (/ (+ (* row-height drawn) rows-padding) points-per-inch)))

(defn- label-width

  [label]
  (def lines (string/split "\n" (string label)))
  (def longest (max ;(map length lines)))
  (def radius (+ (* label-slope longest) label-intercept))
  (max min-width (/ (* 2 radius) points-per-inch)))

(defn- quoted

  [text]
  (->> (string text)
       (string/replace-all "\\" "\\\\")
       (string/replace-all "\"" "\\\"")
       (string/replace-all "\n" "\\n")))

(defn- raw [text] {:raw (string text)})

(defn- attrs

  [pairs]
  (if (empty? pairs)
    ""
    (string " ["
            (string/join (map (fn [[k v]]
                                (if (and (dictionary? v) (v :raw))
                                  (string k "=<" (v :raw) ">")
                                  (string k "=\"" v "\"")))
                              pairs)
                         ", ")
            "]")))

(defn- escaped-html

  [text]
  (->> (string text)
       (string/replace-all "&" "&amp;")
       (string/replace-all "<" "&lt;")
       (string/replace-all ">" "&gt;")))

(def- count-size 8)

(def- gap-size 4)

(defn- small-row [text]
  (string "<BR/><FONT POINT-SIZE=\"" count-size "\">" (escaped-html text) "</FONT>"))

(defn- label-markup

  [label]
  (def rows (string/split "\n" (string label)))

  (var body (array ;rows))
  (var count nil)
  (var ext nil)
  (when (and (> (length body) 1)
             (peg/match ~(* (some (range "09")) -1) (last body)))
    (set count (array/pop body)))
  (when (and (> (length body) 1)
             (string/has-prefix? "." (last body)))
    (set ext (array/pop body)))
  (when (or count ext)

    (def tail (string/join (filter identity [ext count]) "  "))
    (string (string/join (map escaped-html body) "<BR/>")
            "<BR/><FONT POINT-SIZE=\"" gap-size "\"> </FONT>"
            (small-row tail))))

(defn- hatch-id

  [ink]
  (string "fold-" (string/replace-all "#" "" (string ink))))

(defn to-dot

  [graph]
  (def out @[])
  (array/push out "digraph G {")
  (array/push out "  rankdir=TB;")

  (array/push out (string "  graph [bgcolor=\"transparent\", fontname=\""
                          (quoted font) "\", fontsize=10];"))

  (array/push out
              (string "  node [shape=ellipse, fontname=\"" (quoted font)
                      "\", fontsize=11, penwidth=1.2, fixedsize=true];"))
  (array/push out "  edge [arrowsize=0.7, color=\"#8a8a8a\"];")

  (defn node-line [node indent]
    (def name (node :name))
    (def ink (node :ink))
    (def fresh (node :fresh))

    (def marks (filter identity [(when fresh "fresh")
                                 (when (node :folded) "folded")]))
    (array/push out
                (string indent "\"" (quoted name) "\""
                        (attrs
                          [["label" (if-let [markup (label-markup (node :label))]
                                       (raw markup)
                                       (quoted (node :label)))]

                           ["width" (string/format "%.3f" (label-width (node :label)))]
                           ["height" (string/format "%.3f" (label-height (node :label)))]
                           ["color" ink]
                           ["fontcolor" ink]

                           ;(if fresh
                              [["style" "filled"]
                               ["fillcolor" (node :fill)]]
                              [])

                           ;(if (empty? marks)
                              []
                              [["class" (string/join marks " ")]])])
                        ";")))

  (def hue-of @{})
  (each node (get graph :nodes [])
    (each box (get node :boxes [])
      (put hue-of (box :prefix) (box :colour))))

  (def kids @{})
  (def top @{})
  (def held @{})
  (each node (get graph :nodes [])
    (def chain (map |($ :prefix) (get node :boxes [])))
    (if (empty? chain)
      (put held :loose (array/push (or (held :loose) @[]) node))
      (do
        (put held (last chain) (array/push (or (held (last chain)) @[]) node))
        (put top (first chain) true)
        (for i 0 (- (length chain) 1)
          (def parent (chain i))
          (def child (chain (+ i 1)))
          (def seen (or (kids parent) @{}))
          (put seen child true)
          (put kids parent seen)))))

  (defn emit-box [key depth]
    (def pad (string/repeat "  " (+ depth 1)))
    (def hue (hue-of key))
    (array/push out (string pad "subgraph \"cluster_" (quoted key) "\" {"))

    (array/push out (string pad "  label=\"" (quoted key) "\"; style=dashed;"
                            " color=\"" hue "\";"
                            " fontcolor=\"" hue "\";"
                            " fontsize=11;"))

    (each child (sorted (keys (or (kids key) @{})))
      (emit-box child (+ depth 1)))
    (each node (or (held key) [])
      (node-line node (string pad "  ")))
    (array/push out (string pad "}")))

  (each key (sorted (keys top)) (emit-box key 0))

  (each node (or (held :loose) [])
    (node-line node "  "))

  (each [from to] (get graph :edges [])
    (array/push out (string "  \"" (quoted from) "\" -> \"" (quoted to) "\";")))

  (array/push out "}")
  (string/join out "\n"))

(defn- folded-inks

  [graph]
  (distinct (map |($ :ink)
                 (filter |($ :folded) (get graph :nodes [])))))

(defn- trimmed-svg

  [text inks]
  (def at (string/find "<svg" text))
  (def body (if at (string/slice text at) text))
  (def fixed (string/replace-all "&#45;&gt;" "-&gt;" body))

  (def hatch
    (string "<defs>"
            (string/join
              (map (fn [ink]
                     (string "<pattern id=\"" (hatch-id ink) "\""
                             " width=\"6\" height=\"6\""
                             " patternUnits=\"userSpaceOnUse\""
                             " patternTransform=\"rotate(45)\">"
                             "<rect x=\"0\" y=\"0\" width=\"1\" height=\"6\""
                             " fill=\"" ink "\" fill-opacity=\"0.55\"/>"
                             "</pattern>"))
                   inks)
              "")
            "</defs>"))
  (if-let [shut (string/find ">" fixed)]
    (string (string/slice fixed 0 (+ shut 1)) hatch (string/slice fixed (+ shut 1)))
    fixed))

(defn draw

  [graph]
  (trace/measure "layout-draw"
  (def dot (to-dot graph))
  (try
    (let [proc (os/spawn ["dot" "-Tsvg"] :px {:in :pipe :out :pipe})]
      (:write (proc :in) dot)
      (:close (proc :in))
      (def svg (:read (proc :out) :all))
      (def status (os/proc-wait proc))
      (if (zero? status)
        [true (trimmed-svg (string svg) (folded-inks graph))]
        [false "graphviz failed to draw this graph"]))
    ([err]
      [false (string "graphviz is required to draw the graph, and running "
                     "`dot` failed: " err
                     ". Install it with `brew install graphviz`.")]))))
