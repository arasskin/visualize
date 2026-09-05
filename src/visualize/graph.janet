(import ./select)
(import ./names)
(import ./layout)

(var- seen nil)

(defn- moved-since [stamps]
  ``Which nodes are new or have been written since the last drawing.

  Nothing on the FIRST draw -- there is no previous one to differ from, and
  flashing the whole graph on load would say only that the graph exists.``
  (def flashing @{})
  (when seen
    (eachp [name stamp] stamps
      (def before (seen name))
      (when (or (nil? before) (not= before stamp))
        (put flashing name true))))
  flashing)

(defn render-svg

  [tree state]
  (if (tree :error)
    [false (tree :error)]
    (do

      (def trimmed (select/drop-nodes (select/keep tree (state :only)) (state :hidden)))

      (def [folded sizes]
        (select/fold trimmed (state :folded) (tree :sizes)))

      (def aliased
        (if (empty? (state :aliases))
          folded
          (merge folded
                 {:nodes (map (fn [node]
                                (if-let [short (select/alias-label (state :aliases)
                                                                   (node :name))]

                                  (merge node
                                         {:label
                                          (let [cut (if (node :folded) short (names/stem short))
                                                ext (unless (node :folded) (names/extension short))
                                                rows (string/join
                                                       (string/split "." cut) ".\n")]
                                            (if ext (string rows "\n." ext) rows))})
                                  node))
                              (folded :nodes))})))

      (def labelled
        (if (state :sized)
          (merge aliased
                 {:nodes (map (fn [node]
                                (if-let [size (get sizes (node :name))]

                                  (merge node {:label (string (node :label) "\n" size)})
                                  node))
                              (aliased :nodes))})
          aliased))

      (def flashing (moved-since (tree :stamps)))
      (set seen (tree :stamps))

      (def resolved (select/resolve labelled (state :groups)
                                    (if (state :animated) flashing {})
                                    (state :palette)))
      (layout/draw resolved))))
