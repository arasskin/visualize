(import ../json)
(import ../trace)

(defn- talk

  [connection message &opt deadline]

  (default deadline 10)
  (:write connection (string (json/encode message) "\n") 10)
  (def reply @"")
  (var line nil)
  (var reading true)
  (while reading
    (if-let [at (string/find "\n" (string reply))]
      (do (set line (string/slice (string reply) 0 at))
          (set reading false))
      (if-let [chunk (:read connection 65536 nil deadline)]
        (buffer/push-string reply chunk)
        (set reading false))))

  (unless line (error "incomplete reply -- connection unusable"))

  line)

(defn- checked [reply]
  (unless reply (error "terminal supervisor unreachable"))
  (when-let [message (get reply "error")] (error message))
  reply)

(defn- client-state

  [reply]
  {:running (truthy? (get reply "running"))
   :generation (or (get reply "generation") 0)
   :argv (or (get reply "argv") [])
   :chunks (or (get reply "chunks") 0)})

(defn make-client

  [path argv]

  (var pinned nil)
  (def turn @{:busy false :waiting @[]})

  (defn take-turn []
    (if (turn :busy)
      (let [ticket (ev/chan 1)]
        (array/push (turn :waiting) ticket)
        (ev/take ticket))
      (put turn :busy true)))

  (defn give-turn []
    (if (empty? (turn :waiting))
      (put turn :busy false)
      (let [ticket (get (turn :waiting) 0)]
        (array/remove (turn :waiting) 0)
        (ev/give ticket true))))

  (defn drop-pinned []
    (when pinned
      (try (:close pinned) ([_] nil))
      (set pinned nil)))

  (defn connect []
    (when (and path (os/stat path :mode))
      (try (net/connect :unix path) ([_] nil))))

  (var parked-conn nil)
  (var parked-busy false)

  (defn park-talk [message deadline]
    (if parked-busy
      (when-let [conn (connect)]
        (defer (:close conn)
          (try (talk conn message deadline) ([_] nil))))
      (do
        (set parked-busy true)
        (defer (set parked-busy false)
          (when (nil? parked-conn) (set parked-conn (connect)))
          (when parked-conn
            (def reply (try (talk parked-conn message deadline) ([_] nil)))
            (unless reply
              (try (:close parked-conn) ([_] nil))
              (set parked-conn nil))
            reply)))))

  (defn spawn-detached []
    (def errlog (or (os/getenv "VISUALIZE_SUPERVISOR_LOG") "/dev/null"))
    (os/execute ["/bin/sh" "-c"
      ``supervisor_log=$1
shift
(
  for supervisor_fd in /dev/fd/*; do
    supervisor_fd=${supervisor_fd##*/}
    case "$supervisor_fd" in
      0|1|2|*[!0-9]*) ;;
      *) eval "exec $supervisor_fd>&-" ;;
    esac
  done
  exec "$@"
) </dev/null >/dev/null 2>"$supervisor_log" &``
      "visualize-supervisor" errlog ;argv] :p))

  (defn ensure []
    (or (connect)
        (do
          (when (os/stat path :mode) (try (os/rm path) ([_] nil)))
          (spawn-detached)

          (var found nil)
          (for _ 0 30
            (unless found
              (ev/sleep 0.02)
              (set found (connect))))
          found)))

  (def ask-stats @{})
  (defn- note-ask [op turn talk]
    (def entry (or (get ask-stats op)
                   (let [fresh @{:count 0 :worst-turn 0 :worst-talk 0 :slow @[]}]
                     (put ask-stats op fresh)
                     fresh)))
    (put entry :count (inc (entry :count)))
    (when (> turn (entry :worst-turn)) (put entry :worst-turn turn))
    (when (> talk (entry :worst-talk)) (put entry :worst-talk talk))
    (when (> (+ turn talk) 0.5)
      (array/push (entry :slow) {:turn turn :talk talk :at (os/time)})
      (when (> (length (entry :slow)) 8) (array/remove (entry :slow) 0))))

  (defn ask [message &opt start?]
    (def asked (os/clock :monotonic))
    (trace/measure "client-queue" (take-turn))
    (def turned (os/clock :monotonic))
    (defer (do (give-turn)
               (note-ask (string (get message "op" "?"))
                         (- turned asked) (- (os/clock :monotonic) turned)))
      (when (nil? pinned)
        (set pinned (if start? (ensure) (connect))))
      (when pinned
        (def reply (try (trace/measure "client-talk" (talk pinned message)) ([_] nil)))
        (if reply
          reply
          (do
            (drop-pinned)
            (unless (= (get message "op") "input")
              (set pinned (if start? (ensure) (connect))))
            (when pinned
              (def again (try (trace/measure "client-talk" (talk pinned message)) ([_] nil)))
              (unless again (drop-pinned))
              again))))))

  (defn asked [message &opt start?]
    (when-let [line (ask message start?)] (json/decode line)))

  (defn fetch-poll [at &opt generation wait limit encoding]
    (def message @{"op" "since" "at" at})
    (when generation (put message "generation" generation))
    (when limit (put message "limit" limit))
    (when encoding (put message "encoding" encoding))
    (if (and wait (pos? wait))

      (let [quick (ask message)]

        (if (or (nil? quick)
                (not (string/find `"text":""` quick))
                (not (string/find `"running":true` quick)))
          quick
          (do
            (put message "wait" wait)
            (or (park-talk message (+ 10 (/ wait 1000))) quick))))
      (ask message)))

  {
   :request (fn [_ message]
     (def line (park-talk message 35))
     (checked (when line (json/decode line))))
   :disconnect (fn [_]
     (drop-pinned)
     (when parked-conn (try (:close parked-conn) ([_] nil)) (set parked-conn nil)))
   :stats (fn [_] ask-stats)
   :remote-stats (fn [_] (asked {"op" "stats"}))

   :start
   (fn [_ run-argv root &opt rows cols theme environment]
     (default rows 24)
     (default cols 100)
     (when environment
       (unless (get (checked (asked {"op" "state"} true)) "launchEnvironment")
         (error "This pane uses an older supervisor. Close and recreate it to apply launch settings.")))
     (client-state (checked (asked {"op" "start" "argv" run-argv "root" root
                         "rows" rows "cols" cols "theme" theme "environment" environment}
                        true))))

   :start-once
   (fn [_ run-argv root rows cols &opt environment theme]
     (def connection (or (ensure) (error "terminal supervisor unreachable")))
     (defer (:close connection)
       (when environment
         (unless (get (checked (json/decode (talk connection {"op" "state"}))) "launchEnvironment")
           (error "This pane uses an older supervisor. Close and recreate it to apply launch settings.")))
       (client-state (checked (json/decode (talk connection
         {"op" "start" "argv" run-argv "root" root "rows" rows "cols" cols "environment" environment "theme" theme}))))))

   :stop
   (fn [_] (client-state (asked {"op" "stop"})))

   :raw-send
   (fn [_ text &opt at quiet generation]
     (def message @{"op" "input" "text" text})
     (when trace/enabled (put message "_trace" true))
     (when at (put message "at" at))
     (when quiet (put message "quiet" true))
     (when generation (put message "generation" generation))
     (or (ask message) "null"))

   :send
   (fn [_ text &opt at quiet]
     (def message @{"op" "input" "text" text})
     (when trace/enabled (put message "_trace" true))
     (when at (put message "at" at))
     (when quiet (put message "quiet" true))
     (def reply (asked message))
     (when (and reply (get reply "text"))
       {"text" (get reply "text")
        "at" (or (get reply "at") at)
        "from" (or (get reply "from") -1)
        "running" (truthy? (get reply "running"))
        "generation" (or (get reply "generation") 0)}))

   :resize
   (fn [_ rows cols &opt width height]
     (checked (asked {"op" "resize" "rows" rows "cols" cols "cellWidth" width "cellHeight" height}))
     nil)

   :redraw
   (fn [_]
     (checked (asked {"op" "redraw"}))
     nil)

   :state
   (fn [_] (client-state (asked {"op" "state"})))

   :since
   (fn [_ at]
     (def reply (asked {"op" "since" "at" at}))
     (if reply
       [(or (get reply "text") "") (or (get reply "at") at)]
       ["" at]))

   :raw-screen
   (fn [_ at &opt generation wait]
     (def message {"op" "screen" "at" at "generation" (or generation 0) "wait" (or wait 0)})
     (def line (if (and wait (pos? wait)) (park-talk message (+ 12 (/ wait 1000))) (ask message)))
     (if (and line (string/find "unknown op" line))
       (json/encode {"error" "This pane uses the old terminal engine. Close and recreate it to use libvterm."})
       (or line (json/encode {"reachable" false "absent" (nil? (and path (os/stat path :mode))) }))))

   :theme (fn [_ theme] (json/encode (checked (asked {"op" "theme" "theme" theme}))))

   :capture (fn [_] (asked {"op" "capture"}))

   :raw-poll
   (fn [self at &opt generation wait limit encoding]
     (def line (fetch-poll at generation wait limit encoding))
     (if line
       line

       (json/encode
         {"text" "" "at" at "from" -1 "running" false "generation" 0
          "rows" 24 "cols" 80 "trimmed" false "waited" false
          "stamp" "" "program" "" "reachable" false
          "absent" (if (and path (os/stat path :mode))
                     (if-let [probe (try (net/connect :unix path) ([_] nil))]
                       (do (try (:close probe) ([_] nil)) false)
                       true)
                     true)})))

   :poll
   (fn [_ at &opt generation wait]
     (def line (fetch-poll at generation wait))
     (if line
       (merge (json/decode line) {"reachable" true})

       {"text" "" "at" at "running" false "generation" 0 "rows" 24 "cols" 80
        "reachable" false
        "absent" (if (and path (os/stat path :mode))
                   (if-let [probe (try (net/connect :unix path) ([_] nil))]
                     (do (try (:close probe) ([_] nil)) false)
                     true)
                   true)}))

   :shutdown
   (fn [_]
     (ask {"op" "shutdown"})

     (drop-pinned)
     (when parked-conn
       (try (:close parked-conn) ([_] nil))
       (set parked-conn nil))
     nil)})

(def panes @{})

(defn register

  [name client]
  (put panes name client)
  client)

(defn- named

  [name]
  (or (get panes name)
      (if (and (nil? name) (= 1 (length panes)))
        (first (values panes))
        (errorf "no pane named %v -- try one of %j" name (keys panes)))))

(defn stats

  [&opt name]
  (def client (named name))
  (print "server asks (op: count, worst turn-wait, worst talk):")
  (eachp [op entry] (:stats client)
    (printf "  %-12s %6d  %6.3fs  %6.3fs" op (entry :count)
            (entry :worst-turn) (entry :worst-talk))
    (each slow (entry :slow)
      (printf "      slow: turn %.2fs talk %.2fs" (slow :turn) (slow :talk))))
  (def host (:remote-stats client))
  (if-not host
    (print "pane host: unreachable (or predates the stats op)")
    (do
      (printf "pane host (stamp %s, up %.0fs, unsent %d, chunks %d):"
              (get host "stamp" "?") (get host "uptime" 0)
              (get host "unsent" 0) (get host "chunks" 0))
      (eachp [op entry] (get host "ops" {})
        (printf "  %-12s %6d  %6.3fs worst" op (get entry "count" 0)
                (get entry "worst" 0))
        (each slow (get entry "slow" [])
          (printf "      slow: %.2fs" (get slow "took" 0))))))
  nil)

(defn dump [&opt name path]
  (def client (named name))
  (default path (string "/tmp/visualize-screen-" (os/time) ".txt"))
  (def capture (checked (:capture client)))
  (def text (get capture "text" ""))
  (spit path text)
  (printf "%d bytes -> %s (screen %dx%d)" (length text) path
          (get capture "rows" 24) (get capture "cols" 80))
  path)

(def equipment
  (string "panes:    (term/stats \"harness\") op timings both sides\n"
          "          (term/dump \"harness\") capture the screen · term/panes\n"))
