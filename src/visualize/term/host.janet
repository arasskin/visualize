(import ./pty)
(import ../json)
(import ../websocket)
(import ../trace)

(def- born-stamp
  (let [root (string (os/cwd) "/src")]
    (var newest 0)
    (defn walk [dir]
      (each name (try (os/dir dir) ([_] []))
        (def full (string dir "/" name))
        (case (os/stat full :mode)
          :directory (walk full)
          :file (when (string/has-suffix? ".janet" full)
                  (def m (get (os/stat full) :modified 0))
                  (when (> m newest) (set newest m))))))
    (walk root)

    (def d (os/date (math/floor newest)))
    (string/format "%d%02d%02d-%02d%02d%02d"
                   (d :year) (inc (d :month)) (inc (d :month-day))
                   (d :hours) (d :minutes) (d :seconds))))

(def- backlog-limit
  (or (scan-number (or (os/getenv "VISUALIZE_BACKLOG") "")) 4000))

(var- session nil)
(var- output nil)
(var- backlog @[])

(var- base 0)
(var- generation 0)

(var- pty-rows 24)
(var- pty-cols 80)
(var- exited false)
(var- starting false)
(var- lifecycle 0)

(def- da1-reply "\e[?6c")

(var- da1-carry "")

(defn da1-queries

  [carry chunk]
  (def text (string carry chunk))
  (def next-carry
    (cond
      (string/has-suffix? "\e[0" text) "\e[0"
      (string/has-suffix? "\e[" text) "\e["
      (string/has-suffix? "\e" text) "\e"
      ""))
  [(+ (length (string/find-all "\e[c" text))
      (length (string/find-all "\e[0c" text)))
   next-carry])

(defn- answer-queries

  [chunk]
  (def [hits carry] (da1-queries da1-carry chunk))
  (set da1-carry carry)
  (when (and (pos? hits) session (not exited))
    (repeat hits (try (pty/write-input session da1-reply) ([_] nil)))))

(var- install-dir nil)

(defn tools-at

  [dir]
  (set install-dir dir))

(var- draining false)
(defn- drain

  []
  (when (and output (not draining))
    (set draining true)
    (defer (set draining false)
      (while (pos? (ev/count output))
        (def value (ev/take output))
        (if (= value :eof)
          (set exited true)
          (do (array/push backlog value)
              (answer-queries value)
              (when (> (length backlog) backlog-limit)
                (array/remove backlog 0)
                (++ base))))))))

(var- unsent @"")

(defn- flush-unsent

  []
  (while (and session (not exited) (pos? (length unsent)))
    (def head (string/slice unsent 0 (min 2048 (length unsent))))
    (def wrote (try (pty/write-input session head) ([_] 0)))
    (if (pos? wrote)
      (let [rest (buffer/slice unsent wrote)]
        (buffer/clear unsent)
        (buffer/push-string unsent rest))
      (break))))

(defn- keep-draining

  []
  (ev/go
    (fn []
      (forever
        (ev/sleep 0.02)
        (try (drain) ([_] nil))

        (try (flush-unsent) ([_] nil))))))

(defn- running?

  []
  (drain)
  (or starting (and session (not exited) (pty/alive? session))))

(var- foreground-cache nil)
(var- foreground-at 0)

(defn- foreground-fresh

  []
  (when-let [device (and session (session :device))
             short (when (string/has-prefix? "/dev/" device)
                     (string/slice device 5))]
    (try
      (let [proc (os/spawn ["ps" "-t" short "-o" "stat=,command="] :px {:out :pipe})
            text (or (:read (proc :out) :all) "")]
        (os/proc-wait proc)
        (var found nil)
        (each raw (string/split "\n" (string text))
          (def line (string/trim raw))
          (unless (empty? line)

            (def parts (filter |(not (empty? $)) (string/split " " line)))
            (def stat (first parts))

            (when (and stat (string/find "+" stat) (> (length parts) 1))

              (def leaf (last (string/split "/" (string/trim (get parts 1) "-"))))
              (unless (or (empty? leaf) (string/has-prefix? "<" leaf))
                (set found leaf)))))
        found)
      ([_] nil))))

(defn- foreground

  []
  (def now (os/clock :monotonic))

  (when (>= (- now foreground-at) 1)
    (set foreground-at now)
    (ev/go (fn [] (set foreground-cache (foreground-fresh)))))
  foreground-cache)

(defn- session-state

  [&opt want-program]
  (default want-program true)
  {"running" (truthy? (running?))
   "generation" generation
   "argv" (if session (session :argv) [])

   "program" (if want-program (or (foreground) "") "")
   "chunks" (+ base (length backlog))
   "rows" pty-rows
   "trimmed" (pos? base)

   "unsent" (length unsent)

   "stamp" born-stamp
   "cols" pty-cols})

(defn- session-start

  [argv root rows cols]
  (++ lifecycle)
  (def version lifecycle)
  (set starting true)
  (when session (try (pty/close session) ([_] nil)))
  (when output (ev/chan-close output))
  (set session nil)
  (set output nil)
  (set backlog @[])
  (set base 0)
  (set exited false)
  (set da1-carry "")
  (buffer/clear unsent)
  (set pty-rows rows)
  (set pty-cols cols)
  (++ generation)

  (def tools-dir install-dir)
  (def channel (ev/thread-chan 8192))
  (def ready (ev/thread-chan 2))

  (ev/thread
    (fn [[reply out command directory lines columns tools-dir]]

      (def opened (try (pty/open command lines columns
                                 (let [environment (os/environ)]
                                   (put environment "PWD" directory)

                                   (when tools-dir
                                     (put environment "PATH"
                                          (string tools-dir ":"
                                                  (or (environment "PATH") "")))
                                     (put environment "VISUALIZE_ROOT" directory)

                                     (put environment "VISUALIZE_TOOLS"
                                          "vz: scan|faults|eval|pane|state|where"))
                                   environment)

                                 directory)
                    ([e] {:error (string e)})))
      (ev/give reply opened)
      (unless (opened :error)
        (pty/pump opened (fn [chunk] (ev/give out chunk)))
        (ev/give out :eof))
      :done)
    [ready channel argv root rows cols tools-dir]
    :nt (ev/thread-chan 2))

  (def opened (ev/take ready))
  (when (not= version lifecycle)
    (unless (opened :error) (try (pty/close opened) ([_] nil)))
    (ev/chan-close channel)
    (break (session-state)))
  (set starting false)
  (if (opened :error)
    (do (set session nil)
        (set output nil)
        (set exited true)
        (merge (session-state) {"error" (opened :error)}))
    (do (set session opened)
        (set output channel)
        (session-state))))

(defn- session-stop

  []
  (++ lifecycle)
  (set starting false)
  (when output (ev/chan-close output))
  (when session
    (try (pty/close session) ([_] nil))
    (set session nil)
    (set output nil)
    (set exited true))
  (session-state))

(defn- session-send

  [text]
  (when (and session (not exited))
    (buffer/push-string unsent text)
    (flush-unsent))
  nil)

(defn- session-resize

  [rows cols]
  (set pty-rows rows)
  (set pty-cols cols)
  (when session
    (try (pty/resize session rows cols) ([_] nil)))
  nil)

(defn- session-redraw

  []
  (when session
    (try (pty/resize session pty-rows (max 1 (dec pty-cols))) ([_] nil))
    (ev/sleep 0.05)
    (try (pty/resize session pty-rows pty-cols) ([_] nil)))
  nil)

(defn- session-since [at &opt limit]
  (drain)
  (def total (+ base (length backlog)))
  (def from (max base (min at total)))
  (if (and limit (pos? limit))
    (let [chunks @[]]
      (var bytes 0)
      (var next from)
      (while (and (< next total) (< bytes limit))
        (def chunk (backlog (- next base)))
        (array/push chunks chunk)
        (+= bytes (length chunk))
        (++ next))
      [(string/join chunks "") next from])
    [(string/join (slice backlog (- from base)) "") total from]))

(def- op-stats @{})
(def- born-clock (os/clock :monotonic))

(defn- note-op [op took]
  (def entry (or (get op-stats op)
                 (let [fresh @{:count 0 :worst 0 :slow @[]}]
                   (put op-stats op fresh)
                   fresh)))
  (put entry :count (inc (entry :count)))
  (when (> took (entry :worst)) (put entry :worst took))
  (when (> took 0.5)
    (array/push (entry :slow) {:took took :at (os/time)})
    (when (> (length (entry :slow)) 8) (array/remove (entry :slow) 0))))

(defn handle

  [message]
  (def op (string (get message "op" "")))
  (defn number-at [key fallback]
    (math/floor (or (get message key) fallback)))
  (def started (os/clock :monotonic))
  (def out (cond
    (= op "start")
    [(session-start (map string (get message "argv" []))
            (string (get message "root" "."))
            (number-at "rows" 24)
            (number-at "cols" 100))
     false]

    (= op "stop") [(session-stop) false]

    (and (= op "input") (get message "generation")
         (not= (get message "generation") generation))
    [{"error" "terminal session changed"} false]

    (and (= op "input") (> (+ (length unsent) (length (get message "text" ""))) 1048576))
    [{"error" "terminal input buffer full"} false]

    (= op "input")
    (let [at (number-at "at" -1)
          before (+ base (length backlog))]
      (trace/measure "pty-send"
        (session-send (string (get message "text" ""))))

      (def wait-start (os/clock :monotonic))
      (unless (truthy? (get message "quiet"))
        (while (and (= (+ base (length backlog)) before)
                    (< (- (os/clock :monotonic) wait-start) 0.048))
          (drain)
          (when (= (+ base (length backlog)) before)
            (ev/sleep (if (< (- (os/clock :monotonic) wait-start) 0.004)
                        0.0002
                        0.002)))))
      (trace/record "echo-wait" (* 1000 (- (os/clock :monotonic) wait-start)))
      (if (neg? at)

        [{"ok" true} false]

        (let [[text next from] (session-since at)
              now (session-state false)]
          [{"ok" true
            "text" text
            "at" next
            "from" from
            "running" (now "running")
            "generation" (now "generation")}
           false])))

    (= op "redraw")
    (do (session-redraw) [{"ok" true} false])

    (= op "resize")
    (do (session-resize (number-at "rows" 24) (number-at "cols" 100))
        [{"ok" true} false])

    (= op "since")

    (let [asked (number-at "generation" -1)
          wait (min 25000 (number-at "wait" 0))]
      (when (pos? wait)

        (def entry (session-state false))
        (def from (number-at "at" 0))
        (def deadline (+ (os/clock :monotonic) (/ wait 1000)))
        (var parked true)
        (while parked
          (drain)
          (def now (session-state false))
          (def total (+ base (length backlog)))
          (cond

            (and (>= asked 0) (not= asked (now "generation"))) (set parked false)

            (> total (max base (min from total))) (set parked false)

            (not= (now "running") (entry "running")) (set parked false)
            (>= (os/clock :monotonic) deadline) (set parked false)

            (ev/sleep 0.001))))
      (let [now (session-state)
            stale (and (>= asked 0) (not= asked (now "generation")))
            [text next from] (session-since (if stale 0 (number-at "at" 0)) (number-at "limit" 0))]
        [{"text" (if (= (get message "encoding") "base64") (websocket/base64 text) text)
          "encoding" (get message "encoding" "utf8")
          "at" next
          "from" from
          "running" (now "running")
          "generation" (now "generation")
          "rows" (now "rows")
          "cols" (now "cols")
          "trimmed" (now "trimmed")
          "stamp" (now "stamp")

          "program" (now "program")
          "waited" (pos? wait)

          "reachable" true}
         false]))

    (= op "state") [(session-state) false]

    (= op "shutdown") [(do (session-stop) {"ok" true}) true]

    (= op "stats")
    [{"latency" (when trace/enabled (trace/snapshot))
      "ops" op-stats
      "unsent" (length unsent)
      "chunks" (+ base (length backlog))
      "stamp" born-stamp
      "uptime" (- (os/clock :monotonic) born-clock)}
     false]

    [{"error" (string "unknown op '" op "'")} false]))
  (note-op (if (and (= op "since") (pos? (number-at "wait" 0))) "since+wait" op)
           (- (os/clock :monotonic) started))
  out)

(defn host

  [path]

  (os/sigaction :int (fn [] nil))
  (os/sigaction :hup (fn [] nil))

  (when (os/stat path :mode) (try (os/rm path) ([_] nil)))
  (def server (net/server :unix path))
  (def done (ev/chan 1))

  (trace/heartbeat)
  (keep-draining)

  (ev/go
    (fn []
      (forever
        (ev/sleep 2)
        (unless (os/stat path :mode)
          (try (session-stop) ([_] nil))
          (os/exit 0)))))
  (defn answer [connection]

    (defer (:close connection)
      (def pending @"")
      (var serving true)
      (while serving
        (if-let [at (string/find "\n" (string pending))]
          (let [line (string/slice (string pending) 0 at)
                rest (string/slice (string pending) (inc at))]
            (buffer/clear pending)
            (buffer/push-string pending rest)
            (def parsed (try (json/decode line) ([_] nil)))
            (if parsed
              (do
                (when trace/enabled (setdyn :latency @{}))
                (def [reply finished] (trace/measure "host-handle" (handle parsed)))
                (def sent (if (and trace/enabled (get parsed "_trace"))
                            (merge reply {"_trace" (dyn :latency)}) reply))
                (def encoded (trace/measure "host-encode" (json/encode sent)))
                (try (trace/measure "host-write" (:write connection (string encoded "\n")))
                  ([_] (set serving false)))
                (when finished
                  (ev/give done true)
                  (set serving false)))

              (set serving false)))
          (if-let [chunk (:read connection 65536)]
            (buffer/push-string pending chunk)
            (set serving false))))))
  (ev/go
    (fn []
      (forever
        (def connection (try (:accept server) ([_] nil)))
        (unless connection (break))
        (ev/go (fn [] (try (answer connection) ([err] (eprintf "supervisor: %s" (string err)))))))))
  (ev/take done)
  (try (session-stop) ([_] nil))
  (try (:close server) ([_] nil))
  (try (os/rm path) ([_] nil))

  (os/exit 0))
