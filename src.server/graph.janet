(import ./select)
(import ./layout)
(import ./config)
(import ./config-graph)
(import ./scan)
(import ./trace)

(defn- moved-since [stamps seen]
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

  [tree state &opt seen]
  (if (tree :error)
    [false (tree :error)]
    (do

      (def trimmed (select/drop-nodes (select/keep tree (state :only)) (state :hidden)))

      (def [folded sizes]
        (select/fold trimmed (state :folded) (tree :sizes)))

      (def labelled
        (if (state :sized)
          (merge folded
                 {:nodes (map (fn [node]
                                (if-let [size (get sizes (node :name))]

                                  (merge node {:label (string (node :label) "\n" size)})
                                  node))
                              (folded :nodes))})
          folded))

      (def flashing (moved-since (tree :stamps) seen))

      (def resolved (select/resolve labelled (state :groups)
                                    (if (state :animated) flashing {})
                                    (state :palette)))
      (layout/draw resolved))))

(defn- run [[root requests replies]]
  (def path (string root "/" config/config-name))
  (var generation 0)
  (var fingerprint nil)
  (var commands nil)
  (var settings nil)
  (var tree nil)
  (var seen nil)
  (var drawing nil)
  (var drawing-key nil)
  (var working false)
  (def diagrams @{})
  (defn refresh []
    (def lines (config/visible (config/read-config path)))
    (def [state] (config/run lines root))
    (def next (scan/fingerprint root false (state :hidden) path))
    (def changed (not= next fingerprint))
    (def configured (or (not= commands (tuple ;lines)) (not (deep= settings state))))
    (when changed
      (set fingerprint next)
      (set tree nil))
    (when (or changed configured)
      (when configured (set tree nil))
      (set commands (tuple ;lines))
      (set settings state)
      (set drawing nil)
      (++ generation)
      (ev/give replies [0 true generation])))
  (defn handle [op sent]
    (case op
      :file
      (do
        (refresh)
        (unless tree (set tree (scan/scan root nil (settings :hidden))))
        (def node (find |(and (= ($ :name) (get sent "node"))
                             (= ($ :file) (get sent "file"))) (tree :nodes)))
        (def relative (when node (node :file)))
        (unless relative (error "this node does not correspond to a file"))
        (def full (os/realpath (string root "/" relative)))
        (unless (and full (= :file (os/stat full :mode))) (error "file is no longer available"))
        full)
      :draw
      (do
        (refresh)
        (when sent (set tree nil) (set drawing nil))
        (def lines (config/read-config path))
        (def [state problems] (config/run lines root))
        (def key [fingerprint (tuple ;(config/visible lines)) state])
        (unless (and drawing (deep= key drawing-key))
          (unless tree (set tree (scan/scan root nil (state :hidden))))
          (def [ok svg] (render-svg tree state seen))
          (when ok (set seen (tree :stamps)))
          (def [visible moved] (config/shown lines problems))
          (set drawing [visible moved ok svg generation])
          (set drawing-key key))
        drawing)
      :diagram
      (let [[target lines] sent
            key (tuple ;lines)]
        (var cached (diagrams target))
        (unless (= key (get cached 0))
          (def model (config-graph/model lines))
          (set cached [key model (config-graph/render model)])
          (put diagrams target cached))
        [(cached 1) (cached 2)])
      :diagnostics (trace/snapshot)
      (error "unknown graph operation")))
  (refresh)
  (var watching true)
  (ev/go (fn []
    (while watching
      (ev/sleep 0.7)
      (when (and watching (not working)) (try (refresh) ([e] (eprintf "watch: %s" e)))))))
  (var running true)
  (while running
    (def message (ev/take requests))
    (if (or (nil? message) (= (get message 1) :stop))
      (do (set running false) (set watching false))
      (let [[id op sent] message]
        (set working true)
        (def answer (try [id true (handle op sent)] ([e] [id false (string e)])))
        (set working false)
        (ev/give replies answer))))
  :stopped)

(defn start [root changed]
  (def requests (ev/thread-chan 64))
  (def replies (ev/thread-chan 64))
  (def supervisor (ev/thread-chan 1))
  (def pending @{})
  (def stopped (ev/chan 1))
  (var next 0)
  (var alive true)
  (ev/thread run [root requests replies] :n supervisor)
  (ev/go (fn []
    (while alive
      (when-let [message (ev/take replies)]
        (def [id ok value] message)
        (if (zero? id)
          (changed value)
          (when-let [ticket (get pending id)]
            (put pending id nil)
            (ev/give ticket [ok value])))))))
  (ev/go (fn []
    (ev/take supervisor)
    (set alive false)
    (each ticket (values pending) (ev/give ticket [false "graph worker stopped"]))
    (table/clear pending)
    (ev/chan-close requests)
    (ev/chan-close replies)
    (ev/give stopped true)))
  {:call (fn [_ op &opt value]
           (unless alive (error "graph worker stopped"))
           (++ next)
           (def id next)
           (def ticket (ev/chan 1))
           (put pending id ticket)
           (ev/give requests [id op value])
           (def [ok result] (ev/take ticket))
           (if ok result (error result)))
   :stop (fn [_] (when alive (ev/give requests [0 :stop nil]) (ev/take stopped)))})
