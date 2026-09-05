(import ../visualize/json)
(import ../visualize/term/client :as term)
(import ../visualize/term/host :as term-host)
(import ./harness :as check)

(def- root (os/realpath (string (dyn :current-file) "/../../..")))
(def- socket (string (string/trimr (or (os/getenv "TMPDIR") "/tmp") "/") "/visualize-test.sock"))

(def client
  (term/make-client
    socket [(string root "/external-src/janet/janet")
            (string root "/src/visualize/core.janet")
            "--supervise" socket]))

(defn- start [& args] (:start client ;args))
(defn- stop [] (:stop client))
(defn- send [& args] (:send client ;args))
(defn- poll [& args] (:poll client ;args))
(defn- state [] (:state client))
(defn- since [at] (:since client at))
(defn- resize [rows cols] (:resize client rows cols))
(defn- shutdown [] (:shutdown client))
(defn- stats [] {"server-asks" (:stats client) "supervisor" (:remote-stats client)})

(defn- wait-for

  [ready? &opt tries]
  (default tries 40)
  (var seen "")
  (var found false)
  (var n 0)
  (while (and (not found) (< n tries))
    (++ n)
    (ev/sleep 0.05)
    (def [text _] (since 0))
    (set seen text)
    (when (ready? text) (set found true)))
  [found seen])

(check/test "a session starts, reports itself, and stops"
  (def started (start ["/bin/sh" "-c" "echo READY; sleep 5"] (os/cwd) 24 80))
  (check/ok (started :running))
  (check/is= ["/bin/sh" "-c" "echo READY; sleep 5"] (started :argv))
  (def [found _] (wait-for |(string/find "READY" $)))
  (check/ok found "output reaches the backlog")
  (stop)
  (check/ok (not ((state) :running)) "and stopping really stops it"))

(check/test "since replays for a reload and returns only new output after that"

  (start ["/bin/sh" "-c" "echo ONE; sleep 5"] (os/cwd) 24 80)
  (wait-for |(string/find "ONE" $))
  (def [text at] (since 0))
  (check/ok (string/find "ONE" text) "a fresh page gets the whole session")
  (def [again _] (since at))
  (check/is= "" again "and a live page gets nothing it has already seen")
  (stop))

(check/test "typing reaches the program"
  (start ["/bin/sh" "-i"] (os/cwd) 24 80)
  (ev/sleep 0.3)
  (send "echo TYPED-THROUGH\n")

  (def [found _] (wait-for |(string/find "\nTYPED-THROUGH" $)))
  (check/ok found)
  (stop))

(check/test "resize reaches the program"
  (start ["/bin/sh" "-i"] (os/cwd) 24 80)
  (ev/sleep 0.3)
  (resize 40 120)
  (ev/sleep 0.2)
  (send "stty size\n")
  (def [found _] (wait-for |(string/find "40 120" $)))
  (check/ok found "the harness sees the new window size")
  (stop))

(check/test "a waiting poll parks until output arrives"

  (start ["/bin/sh" "-c" "echo FIRST; sleep 1; echo LATER; sleep 5"]
                 (os/cwd) 24 80)
  (wait-for |(string/find "FIRST" $))
  (def head (poll 0))
  (def caught-up (head "at"))
  (def gen (head "generation"))

  (def t0 (os/clock :monotonic))
  (def woken (poll caught-up gen 8000))
  (def elapsed (- (os/clock :monotonic) t0))
  (check/ok (string/find "LATER" (woken "text")) "the park returns the output that woke it")
  (check/ok (woken "waited") "and says it parked")
  (check/ok (< elapsed 7) "woken by output, not the deadline")
  (check/ok (> elapsed 0.3) "genuinely parked rather than answering empty")

  (def t1 (os/clock :monotonic))
  (def quiet (poll (woken "at") gen 400))
  (check/is= "" (quiet "text"))
  (check/ok (quiet "waited"))
  (check/ok (> (- (os/clock :monotonic) t1) 0.3) "held until the deadline")

  (def t2 (os/clock :monotonic))
  (def pending (poll 0 gen 8000))
  (check/ok (string/find "FIRST" (pending "text")))
  (check/ok (< (- (os/clock :monotonic) t2) 1) "pending output never waits")
  (stop))

(check/test "input to a program that never reads cannot freeze the supervisor"

  (start ["/bin/sh" "-c" "exec sleep 5"] (os/cwd) 24 80)
  (ev/sleep 0.3)
  (def flood (string/repeat "x" 65536))
  (def t0 (os/clock :monotonic))
  (send flood)
  (def state (state))
  (def elapsed (- (os/clock :monotonic) t0))
  (check/ok (< elapsed 2) "a flooded pty queues instead of blocking the event loop")
  (check/ok (state :running) "and the supervisor still answers")
  (stop))

(check/test "concurrent polls and inputs never trip over the drain"

  (start ["/bin/sh" "-i"] (os/cwd) 24 80)
  (ev/sleep 0.3)
  (def worst @[0])
  (def note (fn [took] (when (> took (worst 0)) (put worst 0 took))))
  (def halt (ev/chan 1))
  (ev/go (fn []
           (while (zero? (ev/count halt))
             (def t0 (os/clock :monotonic))
             (poll 999999 0 200)
             (note (- (os/clock :monotonic) t0)))))
  (for _ 0 300
    (def t0 (os/clock :monotonic))
    (send "x" nil true)
    (note (- (os/clock :monotonic) t0)))
  (ev/give halt true)
  (check/ok (< (worst 0) 2)
            (string "no operation stalled (worst " (worst 0) "s)"))
  (stop))

(check/test "poll reports which code the supervisor runs"

  (shutdown)
  (ev/sleep 0.3)
  (start ["/bin/sh" "-c" "sleep 3"] (os/cwd) 24 80)
  (def reply (poll 0))
  (def reported (reply "stamp"))
  (check/ok (peg/match ~(* (repeat 8 :d) "-" (repeat 6 :d) -1) reported)
            (string "the supervisor reports a stamp of its own: " reported))

  (stop))

(check/test "an incomplete reply poisons its connection instead of shifting answers"

  (def dead (string socket ".halfline"))
  (def listener (net/server :unix dead))

  (ev/go (fn []
           (when-let [conn (try (:accept listener) ([_] nil))]
             (try (:read conn 4096 nil 2) ([_] nil))
             (try (:write conn "{\"partial\": tr") ([_] nil))
             (ev/sleep 0.2)
             (try (:close conn) ([_] nil)))))
  (def broken (term/make-client dead ["/bin/sh" "-c" "true"]))
  (def answer (:state broken))
  (check/ok (not (answer :running))
            "a half-line reply is a failure, not a value")
  (try (:close listener) ([_] nil))
  (try (os/rm dead) ([_] nil)))

(check/test "a quiet input skips the echo wait"

  (start ["/bin/sh" "-c" "stty -echo; sleep 5"] (os/cwd) 24 80)
  (ev/sleep 0.4)
  (def head (poll 0))
  (def t0 (os/clock :monotonic))
  (send "x" (head "at"))
  (def loud (- (os/clock :monotonic) t0))
  (def t1 (os/clock :monotonic))
  (send "x" (head "at") true)
  (def quick (- (os/clock :monotonic) t1))
  (check/ok (> loud 0.04) "a plain input against a silent program holds the echo wait")
  (check/ok (< quick 0.03) "a quiet one returns without it")
  (stop))

(check/test "op timings are kept on both sides of the wire"

  (start ["/bin/sh" "-c" "sleep 3"] (os/cwd) 24 80)
  (poll 0)
  (def all (stats))
  (def asks (all "server-asks"))
  (check/ok (pos? (get-in asks ["since" :count] 0))
            "the server counted its since asks")
  (def sup (all "supervisor"))
  (check/ok (pos? (get-in sup ["ops" "since" "count"] 0))
            "the supervisor counted handling them")
  (check/ok (get sup "stamp") "and the stats reply carries the stamp")
  (stop))

(check/test "starting again replaces the session and bumps the generation"

  (def first (start ["/bin/sh" "-c" "sleep 5"] (os/cwd) 24 80))
  (def second (start ["/bin/sh" "-c" "sleep 5"] (os/cwd) 24 80))
  (check/ok (> (second :generation) (first :generation)))
  (check/is= 0 (second :chunks) "the backlog starts empty for a new session")
  (stop))

(check/test "a program that exits is reported as not running"
  (start ["/bin/sh" "-c" "echo BYE"] (os/cwd) 24 80)
  (wait-for |(string/find "BYE" $))

  (var still true)
  (for i 0 40
    (when still
      (ev/sleep 0.05)
      (since 0)
      (set still ((state) :running))))
  (check/ok (not still) "the session reports itself finished")
  (stop))

(check/test "sending to a stopped session is harmless"

  (stop)
  (check/is= nil (send "nothing is listening\n"))
  (check/is= nil (resize 10 10)))

(check/test "a session outlives the process that started it"

  (start ["/bin/sh" "-c" "echo SURVIVOR; sleep 5"] (os/cwd) 24 80)
  (wait-for |(string/find "SURVIVOR" $))
  (def restarted
    (term/make-client
      socket [(string root "/external-src/janet/janet")
            (string root "/src/visualize/core.janet")
              "--supervise" socket]))
  (def now (:state restarted))
  (check/ok (now :running) "the session is still running for a new client")

  (def [text _] (:since restarted 0))
  (check/ok (string/find "SURVIVOR" text) "and its output replays in full")
  (stop))

(check/test "heavy output does not wedge the terminal"

  (start ["/bin/sh" "-c" "for i in $(seq 1 4000); do echo line-$i; done; echo FLOOD-END"]
                 (os/cwd) 24 80)
  (def [found _] (wait-for |(string/find "FLOOD-END" $) 120))
  (check/ok found "the program runs to completion with nobody polling")
  (stop))

(check/test "typing still lands while the agent is flooding output"

  (start ["/bin/sh" "-i"] (os/cwd) 24 80)
  (ev/sleep 0.4)
  (send "for i in $(seq 1 3000); do echo noise-$i; done\n")
  (ev/sleep 1.5)
  (send "echo STILL-ACCEPTING-INPUT\n")
  (def [found _] (wait-for |(string/find "\nSTILL-ACCEPTING-INPUT" $) 120))
  (check/ok found "a keystroke sent mid-flood is executed")
  (stop))

(check/test "a reply larger than one read arrives whole"

  (start ["/bin/sh" "-c" "for i in $(seq 1 2000); do echo padding-line-$i; done"]
                 (os/cwd) 24 80)
  (def [found text] (wait-for |(string/find "padding-line-2000" $) 120))
  (check/ok found "the last line of a large reply survives the round trip")

  (check/ok (string/find "padding-line-1" text)
            "the beginning is there too, so nothing was cut short")
  (stop))

(check/test "a page holding a stale position sees the new session at once"

  (start ["/bin/sh" "-c" "echo FIRST-RUN; sleep 5"] (os/cwd) 24 80)
  (wait-for |(string/find "FIRST-RUN" $))
  (def before (poll 0))
  (def stale-at (get before "at"))
  (def stale-generation (get before "generation"))

  (start ["/bin/sh" "-c" "echo SECOND-RUN; sleep 5"] (os/cwd) 24 80)

  (var text "")
  (for _ 0 60
    (when (empty? text)
      (ev/sleep 0.05)
      (def reply (poll stale-at stale-generation))
      (set text (get reply "text" ""))))
  (check/ok (string/find "SECOND-RUN" text)
            "the mismatch replays the new session rather than answering empty")
  (stop))

(check/test "a running session is there to be attached to, not restarted"

  (start ["/bin/sh" "-c" "echo ALIVE-ALREADY; sleep 5"] (os/cwd) 24 80)
  (wait-for |(string/find "ALIVE-ALREADY" $))
  (def before ((state) :generation))

  (def seen (poll 0 0))
  (check/ok (get seen "running")
            "the page can see that a session is already running")
  (check/ok (string/find "ALIVE-ALREADY" (get seen "text" ""))
            "and gets its output without restarting it")
  (check/is= before ((state) :generation)
             "asking must not bump the generation -- that would mean a restart")
  (stop))

(check/test "typing answers with its own echo, in one round trip"

  (start ["/bin/sh" "-i"] (os/cwd) 24 80)
  (ev/sleep 0.4)
  (def [_ at] (since 0))
  (def echoed (send "Q" at))
  (check/ok echoed "input answers with a body rather than just ok")
  (check/ok (string/find "Q" (get echoed "text" ""))
            "and the body carries the character the terminal echoed")
  (check/ok (> (get echoed "at" 0) at)
            "the position advances, so the next poll does not repeat it")
  (stop))

(check/test "typing without a position still works"

  (start ["/bin/sh" "-i"] (os/cwd) 24 80)
  (ev/sleep 0.4)
  (check/is= nil (send "echo NO-POSITION\n"))
  (def [found _] (wait-for |(string/find "\nNO-POSITION" $)))
  (check/ok found "the keystroke still reached the program")
  (stop))

(check/test "the DA1 scanner counts queries and carries a split one"

  (check/is= [1 ""] (term-host/da1-queries "" "\e[c"))
  (check/is= [1 ""] (term-host/da1-queries "" "before \e[0c after"))
  (check/is= [2 ""] (term-host/da1-queries "" "\e[c\e[c"))
  (check/is= [0 "\e["] (term-host/da1-queries "" "output ends \e["))
  (check/is= [1 ""] (term-host/da1-queries "\e[" "c and more"))
  (check/is= [0 "\e[0"] (term-host/da1-queries "\e[" "0"))
  (check/is= [1 ""] (term-host/da1-queries "\e[0" "c"))
  (check/is= [0 ""] (term-host/da1-queries "" "\e[0m is a colour, not a query"))
  (check/is= [0 ""] (term-host/da1-queries "\e[" "2J is a clear, not a query")))

(check/test "a DA1 query is answered, page or no page"

  (start ["/bin/sh" "-c"
                  "stty raw -echo; printf '\\033[c'; head -c 5 >/dev/null; echo ANSWERED"]
                 (os/cwd) 24 80)
  (def [found _] (wait-for |(string/find "ANSWERED" $)))
  (check/ok found "the reply reached the waiting program")
  (stop))

(check/test "live reading continues past the backlog cap"

  (os/setenv "VISUALIZE_BACKLOG" "40")
  (shutdown)
  (ev/sleep 0.3)
  (start ["/bin/sh" "-c"
                  "i=0; while [ $i -lt 300 ]; do echo tick-$i; i=$((i+1)); sleep 0.005; done; echo CAP-DONE"]
                 (os/cwd) 24 80)

  (var at 0)
  (var seen @"")
  (var tries 0)
  (while (and (< tries 600) (not (string/find "CAP-DONE" (string seen))))
    (++ tries)
    (ev/sleep 0.03)
    (def reply (poll at 0))
    (buffer/push-string seen (get reply "text" ""))
    (set at (get reply "at" at)))
  (check/ok (string/find "CAP-DONE" (string seen))
            "incremental polling reaches the end of a session larger than the cap")
  (check/ok (string/find "tick-299" (string seen))
            "and the late output arrived live, not only on reload")
  (def now (poll at 0))
  (check/ok (get now "trimmed")
            "the session reports its history as trimmed, so a reattach knows not to replay it")

  (def gen (get now "generation"))
  (def torn (poll 1 gen))
  (check/ok (> (get torn "from") 1)
            "a reply past a trimmed position reports where it really starts")
  (def intact (poll at gen))
  (check/is= at (get intact "from")
             "an untrimmed position reports exactly itself")
  (stop)
  (shutdown)
  (os/setenv "VISUALIZE_BACKLOG" nil)
  (ev/sleep 0.3))

(check/test "a poll reply carries the supervisor's own line, for relaying"

  (start ["/bin/sh" "-c" "echo RELAY_MARK; sleep 30"] ".")
  (var text "")
  (var tries 0)
  (while (and (< tries 60) (not (string/find "RELAY_MARK" text)))
    (ev/sleep 0.05)
    (++ tries)
    (set text (get (poll 0) "text" "")))
  (check/ok (string/find "RELAY_MARK" text) "the program's output arrived")

  (def raw (:raw-poll client 0))
  (check/ok (string? raw) "the reply comes back as a line, ready to send")
  (check/ok (string/has-prefix? "{" raw) "which is a JSON object")
  (check/ok (string/find "RELAY_MARK" raw) "carrying the output")

  (def decoded (json/decode raw))
  (each k ["text" "at" "from" "running" "generation" "rows" "cols"
           "trimmed" "waited" "stamp" "program" "reachable"]
    (check/ok (has-key? decoded k) (string "the line carries " k)))
  (stop))

(check/test "stream readers survive a session replacement and reject stale input"
  (def initial (start ["/bin/cat"] (os/cwd) 24 80))
  (def delivered (ev/chan 1))
  (ev/go (fn [] (ev/give delivered (:raw-poll client 0 (initial :generation) 1000 65536 "base64"))))
  (ev/sleep 0.02)
  (def next (start ["/bin/sh" "-c" "printf STREAM_READY; sleep 5"] (os/cwd) 24 80))
  (def parked (json/decode (ev/take delivered)))
  (check/ok (get parked "running") "a reader must not see the replaced session's EOF")
  (check/is= (next :generation) (get parked "generation"))
  (def [found _] (wait-for |(string/find "STREAM_READY" $)))
  (check/ok found)
  (def bytes (json/decode (:raw-poll client 0 (next :generation) nil 65536 "base64")))
  (check/is= "base64" (get bytes "encoding"))
  (check/is= "U1RSRUFNX1JFQURZ" (get bytes "text"))
  (def rejected (json/decode (:raw-send client "BAD" nil true (initial :generation))))
  (check/is= "terminal session changed" (get rejected "error"))
  (stop))

(check/test "shutdown ends the supervisor and takes the socket with it"

  (start ["/bin/sh" "-c" "sleep 30"] (os/cwd) 24 80)
  (shutdown)
  (var gone false)
  (for _ 0 40
    (unless gone
      (ev/sleep 0.05)
      (set gone (not (os/stat socket :mode)))))
  (check/ok gone "the socket file is cleaned up, so the next run binds")
  (check/ok (not ((state) :running)) "and nothing answers on it"))
