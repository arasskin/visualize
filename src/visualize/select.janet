(defn- flatten-separators

  [text]
  (string/replace-all "/" "." (string/trim text "./")))

(import ./names)

(defn expand

  [name]
  (def text (string/trim name))
  (cond
    (empty? text) ""
    (flatten-separators text)))

(defn matches?

  [name prefix ours]
  (cond
    (empty? prefix) (truthy? (ours name))
    (string/has-prefix? prefix name) true

    false))

(defn- selector

  [name ours]
  (def contents-only (string/has-suffix? "." (string/trim name)))
  (var prefix (expand name))

  (when (and contents-only (not (empty? prefix)))
    (set prefix (string prefix ".")))
  (fn [node] (matches? node prefix ours)))

(defn keep

  [graph only]
  (if (empty? only)
    graph
    (let [ours (graph :ours)
          tests (map |(selector $ ours) only)
          wanted? (fn [node] (some |($ node) tests))
          nodes (filter |(wanted? ($ :name)) (graph :nodes))]
      (merge graph
             {:nodes nodes
              :edges (filter (fn [[a b]] (and (wanted? a) (wanted? b))) (graph :edges))}))))

(defn drop-nodes

  [graph hidden]
  (if (empty? hidden)
    graph
    (let [ours (graph :ours)

          scoped (fn [name]
                   (def at (string/find "@" name))
                   (when at
                     [(string/slice name 0 at) (string/slice name (+ at 1))]))
          reaches (fn [project node]
                    (var hit false)
                    (each [a b] (graph :edges)
                      (when (and (= b node)
                                 (string/has-prefix? (string project ".") a))
                        (set hit true)))
                    hit)
          tests (map (fn [name]
                       (if-let [[bare project] (scoped name)]
                         (let [test (selector bare ours)]
                           (fn [node] (and (test node) (reaches project node))))
                         (selector name ours)))
                     hidden)
          hidden? (fn [node] (some |($ node) tests))]
      (let [nodes (filter |(not (hidden? ($ :name))) (graph :nodes))
            edges (filter (fn [[a b]] (not (or (hidden? a) (hidden? b))))
                          (graph :edges))

            attached (do
                       (def seen @{})
                       (each [a b] edges (put seen a true) (put seen b true))
                       seen)]
        (merge graph
               {:nodes (filter |(or (not (names/external? ($ :name)))
                                    (attached ($ :name)))
                               nodes)
                :edges edges})))))

(defn fold

  [graph prefixes sizes]
  (if (empty? prefixes)
    [graph sizes]
    (let [ours (get graph :ours {})
          tests (map |[(expand $) (selector $ ours)] prefixes)

          folded-into (fn [name]
                        (var out nil)
                        (each [prefix test] tests
                          (when (and (nil? out) (test name)) (set out prefix)))
                        out)]

      (def members @{})
      (each node (get graph :nodes [])
        (when-let [into (folded-into (node :name))]
          (put members into (array/push (or (members into) @[]) node))))
      (def made @{})
      (eachp [prefix group] members
        (when (> (length group) 1) (put made prefix group)))

      (def kept @[])
      (each node (get graph :nodes [])
        (def into (folded-into (node :name)))
        (unless (and into (made into)) (array/push kept node)))

      (def nodes @[])
      (each node kept (array/push nodes node))
      (eachp [prefix members] made
        (array/push nodes
                    {:name prefix
                     :label (string/join (string/split "." prefix) ".\n")

                     :folded true

                     :ours (truthy? (find |($ :ours) members))}))

      (def stands-for
        (fn [name]
          (def into (folded-into name))
          (if (and into (made into)) into name)))

      (def out-sizes @{})
      (eachp [name n] (or sizes {})
        (def into (folded-into name))
        (unless (and into (made into)) (put out-sizes name n)))
      (eachp [prefix members] made
        (var total 0)
        (each m members (+= total (get (or sizes {}) (m :name) 0)))
        (when (> total 0) (put out-sizes prefix total)))

      (def pairs @{})
      (each [from to] (get graph :edges [])
        (def a (stands-for from))
        (def b (stands-for to))

        (unless (= a b) (put pairs [a b] true)))

      [(merge graph {:nodes (sorted-by |($ :name) nodes)
                     :edges (sorted (keys pairs))})
       out-sizes])))

(defn degrees

  [graph]
  (def counts @{})
  (each node (graph :nodes) (put counts (node :name) 0))
  (each [a b] (graph :edges)
    (when (counts a) (put counts a (+ 1 (counts a))))
    (when (counts b) (put counts b (+ 1 (counts b)))))
  counts)

(defn boxes-for

  [name groups ours]
  (def inside (filter (fn [g] (matches? name (expand (g :prefix)) ours)) groups))
  (sorted-by |(length (expand ($ :prefix))) inside))

(defn group-for

  [name groups ours]
  (last (boxes-for name groups ours)))

(defn alias-label

  [aliases name]
  (var out nil)
  (each entry aliases
    (unless out
      (def full (entry :prefix))
      (cond
        (= name full) (set out (entry :alias))
        (string/has-prefix? (string full ".") name)
        (set out (string (entry :alias) (string/slice name (length full)))))))
  out)

(defn resolve

  [graph groups flashing palette]
  (def ours (get graph :ours {}))
  (def ungrouped (palette :ungrouped))
  (def ink (palette :ink))
  (def tint (palette :tint))
  (merge graph
         {:nodes (map (fn [node]
                        (def inside (boxes-for (node :name) groups ours))
                        (def claimed (last inside))
                        (def hue (if claimed (claimed :color) ungrouped))
                        (merge node
                               {:box (when claimed (claimed :prefix))

                                :boxes (map |{:prefix ($ :prefix)
                                              :colour ($ :color)} inside)
                                :colour hue
                                :ink (ink hue)
                                :fill (tint hue)
                                :fresh (truthy? (get flashing (node :name)))}))
                      (get graph :nodes []))}))
