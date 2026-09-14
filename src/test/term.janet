(import ../../src.server/json)
(import ../../src.server/term/client :as term)
(import ./harness :as check)

(def- root (os/realpath (string (dyn :current-file) "/../../..")))
(def- socket (string (string/trimr (or (os/getenv "TMPDIR") "/tmp") "/") "/visualize-test.sock"))

(def client
  (term/make-client
    socket [(string root "/external-src/janet/janet")
            (string root "/src.server/core.janet")
            "--supervise" socket]))

(defn- start [& args] (:start client ;args))
(defn- stop [] (:stop client))
(defn- send [text] (json/decode (:raw-send client text)))
(defn- screen [& args] (merge (json/decode (:raw-screen client ;args)) {"text" (get (:capture client) "text" "")}))
(defn- state [] (:state client))

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
    (def text (get (:capture client) "text" ""))
    (set seen text)
    (when (ready? text) (set found true)))
  [found seen])

(check/test "a session starts, reports itself, and stops"
  (def started (start ["/bin/sh" "-c" "echo READY; sleep 5"] (os/cwd) 24 80))
  (check/ok (started :running))
  (check/is= ["/bin/sh" "-c" "echo READY; sleep 5"] (started :argv))
  (def [found _] (wait-for |(string/find "READY" $)))
  (check/ok found "output reaches the emulator")
  (stop)
  (check/ok (not ((state) :running)) "and stopping really stops it"))

(check/test "screen snapshots recover a reload and send only changed rows afterward"
  (def started (start ["/bin/sh" "-c" "echo ONE; sleep 5"] (os/cwd) 24 80))
  (wait-for |(string/find "ONE" $))
  (def first (screen 0 (started :generation)))
  (check/is= 24 (length (get-in first ["screen" "lines"])))
  (def next (screen (first "at") (started :generation)))
  (check/is= [] (get-in next ["screen" "lines"]))
  (check/is= 24 (length (get-in (screen 0 (started :generation)) ["screen" "lines"])))
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

(check/test "a rejected resize keeps the supervisor and emulator dimensions"
  (start ["/bin/sh" "-i"] (os/cwd) 24 80)
  (defer (stop)
    (def failure (try (resize 1001 120) ([e] (string e))))
    (check/ok (string/find "between 1 and 1000" failure))
    (def current (screen 0))
    (check/is= 24 (current "rows"))
    (check/is= 80 (current "cols"))
    (check/is= 24 (get-in current ["screen" "rows"]))
    (check/is= 80 (get-in current ["screen" "cols"]))
    (resize 30 90)
    (check/is= 90 (get-in (screen 0) ["screen" "cols"]))))

(check/test "a waiting screen request parks until output arrives"

  (start ["/bin/sh" "-c" "echo FIRST; sleep 1; echo LATER; sleep 5"]
                 (os/cwd) 24 80)
  (wait-for |(string/find "FIRST" $))
  (def head (screen 0))
  (def caught-up (head "at"))
  (def gen (head "generation"))

  (def t0 (os/clock :monotonic))
  (def woken (screen caught-up gen 8000))
  (def elapsed (- (os/clock :monotonic) t0))
  (check/ok (string/find "LATER" (woken "text")) "the park returns the output that woke it")
  (check/ok (woken "waited") "and says it parked")
  (check/ok (< elapsed 7) "woken by output, not the deadline")
  (check/ok (> elapsed 0.3) "genuinely parked rather than answering empty")

  (def t1 (os/clock :monotonic))
  (def quiet (screen (woken "at") gen 400))
  (check/is= [] (get-in quiet ["screen" "lines"]))
  (check/ok (quiet "waited"))
  (check/ok (> (- (os/clock :monotonic) t1) 0.3) "held until the deadline")

  (def t2 (os/clock :monotonic))
  (def pending (screen 0 gen 8000))
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

(check/test "concurrent screen requests and inputs never trip over the drain"

  (start ["/bin/sh" "-i"] (os/cwd) 24 80)
  (ev/sleep 0.3)
  (def worst @[0])
  (def note (fn [took] (when (> took (worst 0)) (put worst 0 took))))
  (def halt (ev/chan 1))
  (ev/go (fn []
           (while (zero? (ev/count halt))
             (def t0 (os/clock :monotonic))
             (screen 999999 0 200)
             (note (- (os/clock :monotonic) t0)))))
  (for _ 0 300
    (def t0 (os/clock :monotonic))
    (send "x")
    (note (- (os/clock :monotonic) t0)))
  (ev/give halt true)
  (check/ok (< (worst 0) 2)
            (string "no operation stalled (worst " (worst 0) "s)"))
  (stop))

(check/test "screen replies report which code the supervisor runs"

  (shutdown)
  (ev/sleep 0.3)
  (start ["/bin/sh" "-c" "sleep 3"] (os/cwd) 24 80)
  (def reply (screen 0))
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

(check/test "input returns immediately without waiting for an echo"
  (start ["/bin/sh" "-c" "stty -echo; sleep 5"] (os/cwd) 24 80)
  (ev/sleep 0.4)
  (def began (os/clock :monotonic))
  (check/ok (get (send "x") "ok"))
  (check/ok (< (- (os/clock :monotonic) began) 0.1))
  (stop))

(check/test "op timings are kept on both sides of the wire"

  (start ["/bin/sh" "-c" "sleep 3"] (os/cwd) 24 80)
  (screen 0)
  (def all (stats))
  (def asks (all "server-asks"))
  (check/ok (pos? (get-in asks ["screen" :count] 0))
            "the server counted its screen asks")
  (def sup (all "supervisor"))
  (check/ok (pos? (get-in sup ["ops" "screen" "count"] 0))
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
      (:capture client)
      (set still ((state) :running))))
  (check/ok (not still) "the session reports itself finished")
  (stop))

(check/test "sending to a stopped session is harmless"

  (stop)
  (check/ok (get (send "nothing is listening\n") "ok"))
  (check/is= nil (resize 10 10)))

(check/test "a session outlives the process that started it"

  (start ["/bin/sh" "-c" "echo SURVIVOR; sleep 5"] (os/cwd) 24 80)
  (wait-for |(string/find "SURVIVOR" $))
  (def restarted
    (term/make-client
      socket [(string root "/external-src/janet/janet")
            (string root "/src.server/core.janet")
              "--supervise" socket]))
  (def now (:state restarted))
  (check/ok (now :running) "the session is still running for a new client")

  (def text (get (:capture restarted) "text" ""))
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

  (def raw (:raw-screen client 0))
  (def snapshot (json/decode raw))
  (check/ok (> (length raw) 65536) "the screen reply spans multiple socket reads")
  (check/ok (> (get-in snapshot ["screen" "history" "count"]) 1900)
            "earlier lines survive in emulator history")
  (stop))

(check/test "a page holding a stale position sees the new session at once"

  (start ["/bin/sh" "-c" "echo FIRST-RUN; sleep 5"] (os/cwd) 24 80)
  (wait-for |(string/find "FIRST-RUN" $))
  (def before (screen 0))
  (def stale-at (get before "at"))
  (def stale-generation (get before "generation"))

  (start ["/bin/sh" "-c" "echo SECOND-RUN; sleep 5"] (os/cwd) 24 80)

  (var text "")
  (for _ 0 60
    (when (empty? text)
      (ev/sleep 0.05)
      (def reply (screen stale-at stale-generation))
      (set text (get reply "text" ""))))
  (check/ok (string/find "SECOND-RUN" text)
            "the mismatch replays the new session rather than answering empty")
  (stop))

(check/test "a running session is there to be attached to, not restarted"

  (start ["/bin/sh" "-c" "echo ALIVE-ALREADY; sleep 5"] (os/cwd) 24 80)
  (wait-for |(string/find "ALIVE-ALREADY" $))
  (def before ((state) :generation))

  (def seen (screen 0 0))
  (check/ok (get seen "running")
            "the page can see that a session is already running")
  (check/ok (string/find "ALIVE-ALREADY" (get seen "text" ""))
            "and gets its output without restarting it")
  (check/is= before ((state) :generation)
             "asking must not bump the generation -- that would mean a restart")
  (stop))



(check/test "typing without a position still works"

  (start ["/bin/sh" "-i"] (os/cwd) 24 80)
  (ev/sleep 0.4)
  (check/ok (get (send "echo NO-POSITION\n") "ok"))
  (def [found _] (wait-for |(string/find "\nNO-POSITION" $)))
  (check/ok found "the keystroke still reached the program")
  (stop))

(check/test "a DA1 query is answered, page or no page"

  (start ["/bin/sh" "-c"
                  "stty raw -echo; printf '\\033[c'; head -c 5 >/dev/null; echo ANSWERED"]
                 (os/cwd) 24 80)
  (def [found _] (wait-for |(string/find "ANSWERED" $)))
  (check/ok found "the reply reached the waiting program")
  (stop))







(check/test "screen publication waits for synchronized output to finish"
  (def started (start ["/bin/sh" "-c"
    "printf '\\033[?2026hPARTIAL'; sleep 0.3; printf ' COMPLETE\\033[?2026l'; sleep 5"] (os/cwd) 4 40))
  (def [found _] (wait-for |(string/find "PARTIAL" $)))
  (check/ok found)
  (def screen (json/decode (:raw-screen client 0 (started :generation) 0)))
  (check/is= 1 (get-in screen ["screen" "version"]))
  (check/ok (string/find "PARTIAL COMPLETE" (get (:capture client) "text"))
            "an immediately requested screen must not expose the partial frame")
  (check/is= 4 (length (get-in screen ["screen" "lines"])))
  (def delta (json/decode (:raw-screen client (screen "at") (started :generation) 0)))
  (check/is= [] (get-in delta ["screen" "lines"]))
  (stop))

(check/test "native replies reach the PTY without a browser during synchronized output"
  (start ["/bin/sh" "-c"
    "stty raw -echo; printf '\\033[?2026h\\033[6n'; head -c 6 >/dev/null; printf 'ANSWERED\\033[?2026l'; sleep 5"] (os/cwd) 4 40)
  (def [found _] (wait-for |(string/find "ANSWERED" $)))
  (check/ok found)
  (check/ok (string/has-prefix? "ANSWERED" (get (:capture client) "text")))
  (stop))

(check/test "screen readers get a full snapshot after a supervisor session replacement"
  (def initial (start ["/bin/cat"] (os/cwd) 4 40))
  (def screen (json/decode (:raw-screen client 0 (initial :generation))))
  (def delivered (ev/chan 1))
  (ev/go (fn [] (ev/give delivered (:raw-screen client (screen "at") (initial :generation) 1000))))
  (ev/sleep 0.02)
  (def next (start ["/bin/cat"] (os/cwd) 6 50))
  (def replacement (json/decode (ev/take delivered)))
  (check/is= (next :generation) (replacement "generation"))
  (check/is= 6 (length (get-in replacement ["screen" "lines"])))
  (check/is= 50 (get-in replacement ["screen" "cols"]))
  (def rejected (json/decode (:raw-send client "BAD" (initial :generation))))
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
