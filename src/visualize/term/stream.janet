(import ../json)

(defn pane-id? [id]
  (and (string? id) (<= (length id) 64)
       (peg/match ~(* (some (+ (range "az") (range "09") "-")) -1) id)))

(defn open [send pane-for operate]
  (var alive true)
  (def streams @{})
  (def actors @{})
  (defn reply [id raw]
    (when alive (send (string "{\"type\":\"reply\",\"id\":" (json/encode id) ",\"body\":" raw "}"))))
  (defn unsubscribe [id]
    (when-let [sub (streams id)]
      (put sub :alive false)
      (ev/chan-close (sub :credit))
      (put streams id nil)))
  (defn subscribe [id at generation subscription]
    (unsubscribe id)
    (def sub @{:alive true :credit (ev/chan 1) :subscription subscription})
    (put streams id sub)
    (ev/give (sub :credit) [at generation])
    (ev/go (fn []
      (try
        (let [client (pane-for id)]
          (while (and alive (sub :alive))
            (if-let [[at generation] (ev/take (sub :credit))]
              (let [raw (:raw-poll client at generation 1000 65536 "base64")]
                (when (and alive (sub :alive))
                  (send (string "{\"type\":\"output\",\"subscription\":" (json/encode subscription) ",\"pane\":" (json/encode id)
                                ",\"body\":" raw "}"))))
              (put sub :alive false))))
        ([e]
          (when (and alive (sub :alive))
            (try (send (json/encode {"type" "output" "pane" id "subscription" subscription
                                     "body" {"reachable" false "error" (string e)}})) ([_] nil))))))))
  (defn actor [pane]
    (or (actors pane)
      (do
        (when (>= (length actors) 64) (error "too many terminal panes"))
        (def state @{:queue (ev/chan 128) :bytes 0 :alive true})
        (put actors pane state)
        (ev/go (fn []
          (while (and alive (state :alive))
            (when-let [[id op body size] (ev/take (state :queue))]
              (-= (state :bytes) size)
              (def raw (try (operate pane op body)
                            ([e] (json/encode {"error" (string e)}))))
              (try (reply id raw) ([_] nil))
              (when (= op "shutdown")
                (put state :alive false)
                (put actors pane nil)
                (unsubscribe pane)
                (while (pos? (ev/count (state :queue)))
                  (def queued (ev/take (state :queue)))
                  (try (reply (queued 0) (json/encode {"error" "terminal closed"})) ([_] nil)))
                (ev/chan-close (state :queue)))))))
        state)))
  {:message (fn [text]
    (def message (json/decode text))
    (def kind (get message "type"))
    (def pane (get message "pane"))
    (unless (pane-id? pane) (error "invalid terminal pane"))
    (case kind
      "subscribe"
      (do
        (when (>= (length streams) 64) (error "too many terminal subscriptions"))
        (subscribe pane (math/floor (or (get message "at") 0))
                        (math/floor (or (get message "generation") 0)) (get message "subscription")))
      "unsubscribe" (unsubscribe pane)
      "credit"
      (when-let [sub (streams pane)]
        (when (and (= (get message "subscription") (sub :subscription)) (zero? (ev/count (sub :credit))))
          (ev/give (sub :credit) [(math/floor (or (get message "at") 0))
                                  (math/floor (or (get message "generation") 0))])))
      "request"
      (let [id (get message "id")
            op (get message "op")
            body (or (get message "body") {})]
        (unless (and (number? id) (>= id 0)
                     (index-of op ["input" "start" "stop" "shutdown" "resize" "redraw" "poll" "diagnostics"]))
          (error "invalid terminal operation"))
        (def body (case op
                    "input" (merge body {"quiet" true "at" nil})
                    "poll" (merge body {"limit" 65536 "encoding" "base64" "wait" 0})
                    body))
        (def state (actor pane))
        (def size (length text))
        (if (or (>= (ev/count (state :queue)) 128) (> (+ size (state :bytes)) 262144))
          (reply id (json/encode {"error" "terminal input queue full"}))
          (do (+= (state :bytes) size)
              (ev/give (state :queue) [id op body size]))))
      (error "invalid terminal message")))
   :close (fn []
     (set alive false)
     (each id (keys streams) (unsubscribe id))
     (each state (values actors) (ev/chan-close (state :queue))))})
