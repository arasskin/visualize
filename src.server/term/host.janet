(import ./pty)
(import ./vterm)
(import ../json)
(import ../websocket)
(import ../trace)
(import ../errors)

(def- born-stamp
  (let [root (os/realpath (string (dyn :current-file) "/../.."))]
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
(var- emulator nil)
(var- emulator-fault nil)
(var- error-log nil)
(var- pane-name "")

(defn- emulator-error [e]
  (set emulator-fault (string e))
  (when error-log
    (try (:write error-log {"pane" pane-name "phase" "native-emulator" "message" emulator-fault})
      ([_] nil)))
  (eprintf "supervisor emulator: %s" emulator-fault))
(var- unsent @"")
(var- output nil)
(var- backlog @[])
(var- backlog-bytes 0)

(var- base 0)
(var- generation 0)
(var- session-root nil)
(var- session-owner nil)

(var- pty-rows 24)
(var- pty-cols 80)
(var- exited false)
(var- starting false)
(var- lifecycle 0)

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
      (var drained 0)
      (while (and (pos? (ev/count output)) (< drained 262144))
        (def value (ev/take output))
        (if (= value :eof)
          (do (set exited true) (when emulator (:release-output emulator)))
          (do (array/push backlog value)
              (+= backlog-bytes (length value))
              (+= drained (length value))
              (when (and emulator (nil? emulator-fault))
                (try
                  (do (:write emulator value)
                      (def replies (:replies emulator))
                      (when (> (+ (length unsent) (length replies)) 1048576)
                        (error "terminal response queue full"))
                      (buffer/push-string unsent replies))
                  ([e] (emulator-error e))))
              (while (or (> (length backlog) backlog-limit) (> backlog-bytes 8388608))
                (-= backlog-bytes (length (backlog 0)))
                (array/remove backlog 0)
                (++ base))))))))

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
        (try (drain) ([e] (emulator-error e)))

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

  [&opt want-program settled]
  (default want-program true)
  {"running" (truthy? (if settled (or starting (and session (not exited) (pty/alive? session))) (running?)))
   "error" emulator-fault
   "controlVersion" 1
   "launchEnvironment" true
   "paneOwnership" true
   "promptInput" true
   "owner" session-owner
   "generation" generation
   "cwd" session-root
   "argv" (if session (session :argv) [])

   "program" (if want-program (or (foreground) "") "")
   "chunks" (+ base (length backlog))
   "rows" pty-rows
   "trimmed" (pos? base)

   "unsent" (length unsent)

   "stamp" born-stamp
   "cols" pty-cols})

(defn- session-start

  [argv root rows cols &opt theme environment owner]
  (def next-emulator (vterm/create rows cols))
  (try (when theme (:theme next-emulator theme))
    ([e] (:close next-emulator) (error e)))
  (++ lifecycle)
  (def version lifecycle)
  (when emulator (:close emulator))
  (set emulator next-emulator)
  (set emulator-fault nil)
  (set starting true)
  (when session (try (pty/close session) ([_] nil)))
  (when output (ev/chan-close output))
  (set session nil)
  (set output nil)
  (set backlog @[])
  (set backlog-bytes 0)
  (set base 0)
  (set exited false)
  (buffer/clear unsent)
  (set pty-rows rows)
  (set pty-cols cols)
  (++ generation)
  (set session-root root)
  (set session-owner owner)

  (def tools-dir install-dir)
  (def channel (ev/thread-chan 64))
  (def ready (ev/thread-chan 2))

  (ev/thread
    (fn [[reply out command directory lines columns tools-dir overrides]]

      (def opened (try (pty/open command lines columns
                                 (let [environment (merge (os/environ) (or overrides {}))]
                                   (put environment "PWD" directory)

                                   (when tools-dir
                                     (put environment "PATH"
                                          (string tools-dir ":"
                                                  (or (environment "PATH") "")))
                                     (put environment "VISUALIZE_ROOT" directory)

                                     (put environment "VISUALIZE_TOOLS"
                                          "vz file | vz list_agents|spawn_agent|read_agent|send_message|close_agent [JSON arguments]"))
                                   environment)

                                 directory)
                    ([e] {:error (string e)})))
      (ev/give reply opened)
      (unless (opened :error)
        (pty/pump opened (fn [chunk] (ev/give out chunk)))
        (ev/give out :eof))
      :done)
    [ready channel argv root rows cols tools-dir environment]
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
  (drain)
  (when emulator (:release-output emulator))
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
  (drain)
  (when emulator (:resize emulator rows cols))
  (set pty-rows rows)
  (set pty-cols cols)
  (when session
    (try (pty/resize session rows cols) ([_] nil)))
  nil)

(defn- session-redraw []
  (when emulator (:resize emulator pty-rows pty-cols))
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
  (when (and (= op "input") (get message "paste")) (drain))
  (def paste? (and (= op "input") (get message "paste") emulator (:bracketed-paste? emulator)))
  (def input-text (if (and (= op "input") (get message "paste"))
    (string (if paste? "\x1b[200~" "") (get message "text" "")
            (if paste? "\x1b[201~" "") (if (get message "submit") "\r" ""))
    (get message "text" "")))
  (def started (os/clock :monotonic))
  (def out (cond
    (and (not= op "start") (get message "owner") (not= (get message "owner") session-owner))
    [{"error" "Worker controls only apply to sessions created through the worker API"} false]

    (and (get message "generation")
         (index-of op ["input" "stop" "shutdown" "resize" "redraw" "theme" "capture" "state"])
         (not= (get message "generation") generation))
    [{"error" "terminal session changed"} false]

    (= op "start")
    [(session-start (map string (get message "argv" []))
            (string (get message "root" "."))
            (number-at "rows" 24)
            (number-at "cols" 100)
            (get message "theme") (get message "environment") (get message "owner"))
     false]

    (= op "stop") [(session-stop) false]

    (and (= op "input") (get message "paste")
         (not (get (session-state false true) "running")))
    [{"error" "worker session is not running"} false]

    (and (= op "input") (get message "paste") (not paste?)
         (some |(index-of $ [10 13 9]) (get message "text" "")))
    [{"error" "terminal has not enabled bracketed paste; inspect it before sending a multiline prompt"} false]

    (and (= op "input") (> (+ (length unsent) (length input-text)) 1048576))
    [{"error" "terminal input buffer full"} false]

    (= op "input")
    (let [at (number-at "at" -1)
          before (+ base (length backlog))]
      (trace/measure "pty-send"
        (session-send (string input-text)))

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

    (= op "theme")
    (do (when emulator (:theme emulator (get message "theme" {}))) [{"ok" true} false])

    (= op "resize")
    (do (when emulator (:geometry emulator (number-at "cellWidth" 8) (number-at "cellHeight" 17)))
        (session-resize (number-at "rows" 24) (number-at "cols" 100))
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

    (= op "screen")
    (let [asked (number-at "generation" -1)
          at (if (= asked generation) (number-at "at" 0) 0)
          deadline (+ (os/clock :monotonic) (/ (min 25000 (max 0 (number-at "wait" 0))) 1000))]
      (drain)
      (while (and emulator (= asked generation)
                  (or (:synchronized? emulator)
                      (and (= at (:revision emulator)) (running?) (< (os/clock :monotonic) deadline))))
        (ev/sleep 0.001)
        (drain)
        (flush-unsent))
      (when (and emulator (:synchronized? emulator))
        (while (:synchronized? emulator) (ev/sleep 0.001) (drain) (flush-unsent)))
      (def now (session-state true true))
      (def screen (when emulator (:snapshot emulator (if (= asked generation) at 0))))
      [(merge now {"screen" screen "at" (if screen (screen "revision") 0)
                   "reachable" true "waited" (pos? (number-at "wait" 0))}) false])

    (= op "capture")
    (do (drain)
        [{"text" (if emulator (:capture emulator) "")
          "generation" generation "rows" pty-rows "cols" pty-cols
          "revision" (if emulator (:revision emulator) 0)
          "running" (get (session-state false true) "running")
          "bracketedPaste" (and emulator (:bracketed-paste? emulator))
          "synchronized" (and emulator (:synchronized? emulator))
          "error" emulator-fault} false])

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

  (set pane-name (last (string/split "/" path)))
  (set error-log (errors/logger (or (os/getenv "VISUALIZE_ERROR_LOG_DIR") (string (os/cwd) "/.logs"))))
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
                (def [reply finished] (trace/measure "host-handle"
                  (try (handle parsed)
                    ([e]
                      (when error-log
                        (try (:write error-log {"pane" pane-name "phase" "supervisor-request" "message" (string e)}) ([_] nil)))
                      [{"error" (string e)} false]))))
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
