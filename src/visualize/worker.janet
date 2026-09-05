(import ./config)
(import ./scan)
(import ./graph)
(import ./json)
(import ./trace)

(defn- shown [lines problems]
  (var index 0)
  (def visible @[])
  (def moved @{})
  (eachp [i line] lines
    (unless (config/note? line)
      (array/push visible line)
      (when-let [why (get problems i)] (put moved index why))
      (++ index)))
  [visible moved])

(defn- run [[root requests replies]]
  (def path (string root "/" config/config-name))
  (var generation 0)
  (var fingerprint nil)
  (var tree nil)
  (var drawing nil)
  (var drawing-key nil)
  (var working false)
  (defn hidden []
    (def out @[])
    (each line (config/read-config path)
      (each hit (or (peg/match ~(any (+ (* "(hide" (some (set " \t"))
                                         (<- (some (if-not (+ (set " \t()") -1) 1)))) 1))
                             (string line)) [])
        (def name (string/trim hit "./"))
        (unless (or (empty? name) (string/find "." name))
          (when (= :directory (os/stat (string root "/" name) :mode))
            (array/push out name)))))
    out)
  (defn refresh []
    (def skips (hidden))
    (def next (scan/fingerprint root false skips))
    (unless (= next fingerprint)
      (set fingerprint next)
      (set tree nil)
      (set drawing nil)
      (++ generation)
      (ev/give replies [0 true generation])))
  (defn render [lines state problems]
    (refresh)
    (def key [fingerprint (tuple ;lines)])
    (unless (and drawing (= key drawing-key))
      (unless tree (set tree (scan/scan root nil (hidden))))
      (def [ok svg] (graph/render-svg tree state))
      (def [visible moved] (shown lines problems))
      (set drawing [visible moved ok svg generation])
      (set drawing-key key))
    drawing)
  (defn handle [op sent]
    (case op
      :read (config/read-config path)
      :notes
      (do
        (def lines (config/read-config path))
        (config/write-config path
          (config/remember-labels (config/remember-terminals lines sent)
                                  (config/labels lines)))
        true)
      :label
      (do
        (def lines (config/read-config path))
        (def labels (config/labels lines))
        (put labels (sent 0) (sent 1))
        (config/write-config path (config/remember-labels lines labels))
        true)
      :draw
      (let [lines (config/read-config path)
            [state problems] (config/run lines root)]
        (render lines state problems))
      :edit
      (do
        (def action (string (get sent "action" "")))
        (def index (math/floor (or (get sent "index") -1)))
        (def disk (config/read-config path))
        (def redraw (and (truthy? (get sent "draw")) (= action "run")))
        (def edited (if redraw disk (config/edit (map string (get sent "lines" [])) action index)))
        (def lines (if redraw edited
                     (config/remember-labels
                       (config/remember-terminals edited (config/terminals disk))
                       (config/labels disk))))
        (unless (or redraw (= action "check")) (config/write-config path lines))
        (when (= action "regenerate") (set tree nil) (set drawing nil))
        (def [state problems] (config/run lines root))
        (def [visible moved] (shown lines problems))
        (var ok true)
        (var svg "")
        (var drawn-generation generation)
        (when (and (truthy? (get sent "draw")) (config/draws action))
          (def result (render lines state problems))
          (set ok (result 2))
          (set svg (result 3))
          (set drawn-generation (result 4)))
        (json/encode {"lines" visible "problems" moved "svg" (if ok svg "")
                      "error" (if ok "" svg) "generation" drawn-generation}))
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
        (try (refresh) ([e] (eprintf "watch: %s" e)))
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
