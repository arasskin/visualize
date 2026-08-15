# The harness session: a pty, a pump thread, and the backlog a page reads.
#
# Driven with /bin/sh rather than a real agent, for the same reasons the pty
# tests are: no API calls, no network, and the code path is identical -- the
# module takes argv and never asks what it is running.
#
# THROUGH THE SOCKET, NOT AROUND IT. Every call below crosses into a real
# supervisor process -- spawned by the first `start`, exactly as the server
# spawns one. Testing the session-owning functions directly would be
# easier and would check the half that never breaks: the interesting failures
# are spawning, framing and reconnection, and all three live on the wire
# between the two processes.

(import ../visualize/harness)
(import ../visualize/stamp)
(import ./harness :as check)

# A socket of this suite's own, so running the tests never adopts (or kills)
# the supervisor belonging to a visualize the user has open.
(def- root (os/realpath (string (dyn :current-file) "/../..")))
(def- socket (string (string/trimr (or (os/getenv "TMPDIR") "/tmp") "/") "/visualize-test.sock"))
(harness/configure socket [(string root "/bin/janet") (string root "/visualize.janet") "--supervise" socket])

(defn- wait-for
  ``Poll until `ready?` passes or the patience runs out.

  A pty splits its output wherever it likes, so a fixed sleep is a race that
  passes on an idle machine. Returns whatever the last read produced.``
  [ready? &opt tries]
  (default tries 40)
  (var seen "")
  (var found false)
  (var n 0)
  (while (and (not found) (< n tries))
    (++ n)
    (ev/sleep 0.05)
    (def [text _] (harness/since 0))
    (set seen text)
    (when (ready? text) (set found true)))
  [found seen])

(check/test "a session starts, reports itself, and stops"
  (def started (harness/start ["/bin/sh" "-c" "echo READY; sleep 5"] (os/cwd) 24 80))
  (check/ok (started :running))
  (check/is= ["/bin/sh" "-c" "echo READY; sleep 5"] (started :argv))
  (def [found _] (wait-for |(string/find "READY" $)))
  (check/ok found "output reaches the backlog")
  (harness/stop)
  (check/ok (not ((harness/state) :running)) "and stopping really stops it"))

(check/test "since replays for a reload and returns only new output after that"
  # The property a page reload depends on: everything from 0, nothing twice.
  (harness/start ["/bin/sh" "-c" "echo ONE; sleep 5"] (os/cwd) 24 80)
  (wait-for |(string/find "ONE" $))
  (def [text at] (harness/since 0))
  (check/ok (string/find "ONE" text) "a fresh page gets the whole session")
  (def [again _] (harness/since at))
  (check/is= "" again "and a live page gets nothing it has already seen")
  (harness/stop))

(check/test "typing reaches the program"
  (harness/start ["/bin/sh" "-i"] (os/cwd) 24 80)
  (ev/sleep 0.3)
  (harness/send "echo TYPED-THROUGH\n")
  # The echoed command contains the word too, so wait for it on a line of its
  # own -- which is the output rather than the echo.
  (def [found _] (wait-for |(string/find "\nTYPED-THROUGH" $)))
  (check/ok found)
  (harness/stop))

(check/test "resize reaches the program"
  (harness/start ["/bin/sh" "-i"] (os/cwd) 24 80)
  (ev/sleep 0.3)
  (harness/resize 40 120)
  (ev/sleep 0.2)
  (harness/send "stty size\n")
  (def [found _] (wait-for |(string/find "40 120" $)))
  (check/ok found "the harness sees the new window size")
  (harness/stop))

(check/test "a waiting poll parks until output arrives"
  # The streaming transport: a poll carrying `wait` PARKS at the supervisor
  # and answers the moment there is something to say. Three properties, each
  # against the real socket: quiet-then-output answers early with the output;
  # quiet-throughout answers empty at the deadline, marked `waited` so the
  # page knows parking is supported; already-pending output answers at once.
  (harness/start ["/bin/sh" "-c" "echo FIRST; sleep 1; echo LATER; sleep 5"]
                 (os/cwd) 24 80)
  (wait-for |(string/find "FIRST" $))
  (def head (harness/poll 0))
  (def caught-up (head "at"))
  (def gen (head "generation"))
  # Parked, then woken by LATER: back well before the 8s deadline, and not
  # instantly -- instant-and-empty is exactly the spin this exists to kill.
  (def t0 (os/clock :monotonic))
  (def woken (harness/poll caught-up gen 8000))
  (def elapsed (- (os/clock :monotonic) t0))
  (check/ok (string/find "LATER" (woken "text")) "the park returns the output that woke it")
  (check/ok (woken "waited") "and says it parked")
  (check/ok (< elapsed 7) "woken by output, not the deadline")
  (check/ok (> elapsed 0.3) "genuinely parked rather than answering empty")
  # Quiet throughout: the deadline answers, empty but marked.
  (def t1 (os/clock :monotonic))
  (def quiet (harness/poll (woken "at") gen 400))
  (check/is= "" (quiet "text"))
  (check/ok (quiet "waited"))
  (check/ok (> (- (os/clock :monotonic) t1) 0.3) "held until the deadline")
  # Output already pending answers immediately, no park.
  (def t2 (os/clock :monotonic))
  (def pending (harness/poll 0 gen 8000))
  (check/ok (string/find "FIRST" (pending "text")))
  (check/ok (< (- (os/clock :monotonic) t2) 1) "pending output never waits")
  (harness/stop))

(check/test "input to a program that never reads cannot freeze the supervisor"
  # `sleep` never reads stdin, so the pty's ~1KB input buffer fills and
  # stays full. A blocking write there froze the supervisor's whole event
  # loop -- an FFI call blocks the thread, not a fiber -- for as long as
  # the program took to drain, which for a scroll flood was ~10 seconds of
  # every request timing out. Writes are gated on writability now, with
  # the surplus queued; the send must come back at once and the supervisor
  # must still be answering.
  (harness/start ["/bin/sh" "-c" "exec sleep 5"] (os/cwd) 24 80)
  (ev/sleep 0.3)
  (def flood (string/repeat "x" 65536))
  (def t0 (os/clock :monotonic))
  (harness/send flood)
  (def state (harness/state))
  (def elapsed (- (os/clock :monotonic) t0))
  (check/ok (< elapsed 2) "a flooded pty queues instead of blocking the event loop")
  (check/ok (state :running) "and the supervisor still answers")
  (harness/stop))

(check/test "concurrent polls and inputs never trip over the drain"
  # THE DRAIN RACE: drain used to read the channel's count once and take
  # that many -- correct from one fiber, a trap from several. A parked
  # poll's 10ms loop racing the timer and an input's echo-wait could both
  # read N and both take N, and the loser's takes suspended on the emptied
  # channel until the pump refilled it: 4-10 second freezes of whichever
  # request was unlucky, and interleaved pushes scrambling backlog order.
  # Reproduced at ~2 stalls per 8,000 browser-paced inputs; the guard makes
  # a second drainer impossible. This runs the same collision pattern hot.
  (harness/start ["/bin/sh" "-i"] (os/cwd) 24 80)
  (ev/sleep 0.3)
  (def worst @[0])
  (def note (fn [took] (when (> took (worst 0)) (put worst 0 took))))
  (def stop (ev/chan 1))
  (ev/go (fn []
           (while (zero? (ev/count stop))
             (def t0 (os/clock :monotonic))
             (harness/poll 999999 0 200)
             (note (- (os/clock :monotonic) t0)))))
  (for _ 0 300
    (def t0 (os/clock :monotonic))
    (harness/send "x" nil true)
    (note (- (os/clock :monotonic) t0)))
  (ev/give stop true)
  (check/ok (< (worst 0) 2)
            (string "no operation stalled (worst " (worst 0) "s)"))
  (harness/stop))

(check/test "poll reports which code the supervisor runs"
  # The handshake's supervisor half: a fresh supervisor was born from the
  # sources on disk, so its stamp matches ours. A long-lived one after an
  # edit would not -- which is the page's cue to say "supervisor outdated"
  # instead of letting fixes be debugged that were never running.
  (harness/start ["/bin/sh" "-c" "sleep 3"] (os/cwd) 24 80)
  (def reply (harness/poll 0))
  (check/is= stamp/born (reply "stamp"))
  (harness/stop))

(check/test "a quiet input skips the echo wait"
  # Mouse reports ride input requests but need no echo riding back -- the
  # parked poll carries the repaint. Against a program that echoes NOTHING,
  # a plain input holds the full echo wait (~48ms) and a quiet one returns
  # at once; the difference is what kept a scroll gesture's report queue
  # draining long after the fingers stopped.
  (harness/start ["/bin/sh" "-c" "stty -echo; sleep 5"] (os/cwd) 24 80)
  (ev/sleep 0.4)
  (def head (harness/poll 0))
  (def t0 (os/clock :monotonic))
  (harness/send "x" (head "at"))
  (def loud (- (os/clock :monotonic) t0))
  (def t1 (os/clock :monotonic))
  (harness/send "x" (head "at") true)
  (def quick (- (os/clock :monotonic) t1))
  (check/ok (> loud 0.04) "a plain input against a silent program holds the echo wait")
  (check/ok (< quick 0.03) "a quiet one returns without it")
  (harness/stop))

(check/test "starting again replaces the session and bumps the generation"
  # The page watches this number: a change means its screen belongs to a dead
  # session and has to be thrown away rather than appended to.
  (def first (harness/start ["/bin/sh" "-c" "sleep 5"] (os/cwd) 24 80))
  (def second (harness/start ["/bin/sh" "-c" "sleep 5"] (os/cwd) 24 80))
  (check/ok (> (second :generation) (first :generation)))
  (check/is= 0 (second :chunks) "the backlog starts empty for a new session")
  (harness/stop))

(check/test "a program that exits is reported as not running"
  (harness/start ["/bin/sh" "-c" "echo BYE"] (os/cwd) 24 80)
  (wait-for |(string/find "BYE" $))
  # `since` drains the channel, which is where the end-of-file arrives.
  (var still true)
  (for i 0 40
    (when still
      (ev/sleep 0.05)
      (harness/since 0)
      (set still ((harness/state) :running))))
  (check/ok (not still) "the session reports itself finished")
  (harness/stop))

(check/test "sending to a stopped session is harmless"
  # The page can always race the program's exit, and a crash there would take
  # the whole server down with it.
  (harness/stop)
  (check/is= nil (harness/send "nothing is listening\n"))
  (check/is= nil (harness/resize 10 10)))

(check/test "a session outlives the process that started it"
  # THE WHOLE POINT OF THE SPLIT. A second client, with its own module state,
  # finds the session the first one started and reads the backlog it never
  # saw. `configure` is called again to make that concrete: this stands in for
  # the restarted server, which comes up knowing nothing but the socket path.
  (harness/start ["/bin/sh" "-c" "echo SURVIVOR; sleep 5"] (os/cwd) 24 80)
  (wait-for |(string/find "SURVIVOR" $))
  (harness/configure socket
                     [(string root "/bin/janet") (string root "/visualize.janet") "--supervise" socket])
  (def now (harness/state))
  (check/ok (now :running) "the session is still running for a new client")
  # From 0, because a fresh page has seen nothing -- this is the reload path.
  (def [text _] (harness/since 0))
  (check/ok (string/find "SURVIVOR" text) "and its output replays in full")
  (harness/stop))

(check/test "heavy output does not wedge the terminal"
  # THE HANG THIS EXISTS FOR. `ev/give` blocks on a full thread channel, and
  # the pump gives one item per read. Draining only when a request arrived
  # meant an agent that outran the polls filled the channel, the pump blocked
  # forever on the give, and it stopped calling read() on the pty. The kernel
  # buffer filled, the agent blocked writing, and the session froze -- while
  # the browser kept polling and the cursor kept blinking, because that blink
  # is a CSS animation with no connection to the process.
  #
  # 4000 lines is comfortably past the old 1024-slot channel; the symptom was
  # a backlog that stopped at exactly 1025 chunks and never reached the end.
  (harness/start ["/bin/sh" "-c" "for i in $(seq 1 4000); do echo line-$i; done; echo FLOOD-END"]
                 (os/cwd) 24 80)
  (def [found _] (wait-for |(string/find "FLOOD-END" $) 120))
  (check/ok found "the program runs to completion with nobody polling")
  (harness/stop))

(check/test "typing still lands while the agent is flooding output"
  # The user-visible half of the same bug: the terminal looked alive and would
  # not accept input. What matters is not just that the keystroke is delivered
  # but that it REACHES THE PROGRAM, so this waits for the effect.
  (harness/start ["/bin/sh" "-i"] (os/cwd) 24 80)
  (ev/sleep 0.4)
  (harness/send "for i in $(seq 1 3000); do echo noise-$i; done\n")
  (ev/sleep 1.5)
  (harness/send "echo STILL-ACCEPTING-INPUT\n")
  (def [found _] (wait-for |(string/find "\nSTILL-ACCEPTING-INPUT" $) 120))
  (check/ok found "a keystroke sent mid-flood is executed")
  (harness/stop))

(check/test "a reply larger than one read arrives whole"
  # The second bug the flood turned up: both sides framed messages with a
  # single `:read`, which returns one chunk rather than one message. A `since`
  # reply carrying more than that was truncated JSON, and decoding it failed
  # -- so a busy terminal broke the very poll that would have drained it.
  (harness/start ["/bin/sh" "-c" "for i in $(seq 1 2000); do echo padding-line-$i; done"]
                 (os/cwd) 24 80)
  (def [found text] (wait-for |(string/find "padding-line-2000" $) 120))
  (check/ok found "the last line of a large reply survives the round trip")
  # Not a size assertion: how much survives depends on the backlog cap and on
  # how the pty happened to split its writes, so pinning a byte count would be
  # a test of the machine's timing. What matters is that BOTH ENDS of a reply
  # spanning many chunks arrive -- a truncated one loses the tail.
  (check/ok (string/find "padding-line-1" text)
            "the beginning is there too, so nothing was cut short")
  (harness/stop))

(check/test "a page holding a stale position sees the new session at once"
  # THE OTHER BLANK-TERMINAL BUG. A client's `at` counts chunks within one
  # session; restarting empties the backlog, so a page still holding the old
  # position asks about chunks that no longer exist and `since` -- which
  # clamps to the end -- answers with nothing. The agent runs, the page stays
  # empty, and the cursor blinks.
  (harness/start ["/bin/sh" "-c" "echo FIRST-RUN; sleep 5"] (os/cwd) 24 80)
  (wait-for |(string/find "FIRST-RUN" $))
  (def before (harness/poll 0))
  (def stale-at (get before "at"))
  (def stale-generation (get before "generation"))

  (harness/start ["/bin/sh" "-c" "echo SECOND-RUN; sleep 5"] (os/cwd) 24 80)
  # Poll exactly as a page that has not noticed the restart would.
  (var text "")
  (for _ 0 60
    (when (empty? text)
      (ev/sleep 0.05)
      (def reply (harness/poll stale-at stale-generation))
      (set text (get reply "text" ""))))
  (check/ok (string/find "SECOND-RUN" text)
            "the mismatch replays the new session rather than answering empty")
  (harness/stop))

(check/test "a running session is there to be attached to, not restarted"
  # THE FIRST-KEYSTROKE BUG. Opening the terminal panel used to call `start`
  # whenever the PAGE's generation was 0 -- which is true of every freshly
  # loaded page, including a reload of one whose session is still running. So
  # a reload shot the agent and replaced it, and the first keystroke went to a
  # shell that had just been killed. It read as lag; it was a dead session.
  #
  # What the page needs is exactly this: ask, and only start when nothing is
  # running.
  # `sleep 5`, not `sleep 30`: the check below takes a moment and the session
  # has to outlive it, but a child still running when this file finishes
  # loading disturbs the next module's reads.
  (harness/start ["/bin/sh" "-c" "echo ALIVE-ALREADY; sleep 5"] (os/cwd) 24 80)
  (wait-for |(string/find "ALIVE-ALREADY" $))
  (def before ((harness/state) :generation))

  # What a reloaded page now does: poll first, and believe the answer.
  (def seen (harness/poll 0 0))
  (check/ok (get seen "running")
            "the page can see that a session is already running")
  (check/ok (string/find "ALIVE-ALREADY" (get seen "text" ""))
            "and gets its output without restarting it")
  (check/is= before ((harness/state) :generation)
             "asking must not bump the generation -- that would mean a restart")
  (harness/stop))

(check/test "typing answers with its own echo, in one round trip"
  # THE FIRST-KEYSTROKE LAG. Polling to discover the effect of your own
  # keystroke costs a SECOND round trip even when the delay between polls is
  # zero: the page cannot start that request until the input request has come
  # back, and by then the scheduler has usually armed the idle timer -- 250ms
  # before the character appears. Answering here collapses it into one trip.
  (harness/start ["/bin/sh" "-i"] (os/cwd) 24 80)
  (ev/sleep 0.4)
  (def [_ at] (harness/since 0))
  (def echoed (harness/send "Q" at))
  (check/ok echoed "input answers with a body rather than just ok")
  (check/ok (string/find "Q" (get echoed "text" ""))
            "and the body carries the character the terminal echoed")
  (check/ok (> (get echoed "at" 0) at)
            "the position advances, so the next poll does not repeat it")
  (harness/stop))

(check/test "typing without a position still works"
  # An older page does not send `at`, and must not break -- the reply is the
  # bare acknowledgement it expects, and its polling loop picks the echo up.
  (harness/start ["/bin/sh" "-i"] (os/cwd) 24 80)
  (ev/sleep 0.4)
  (check/is= nil (harness/send "echo NO-POSITION\n"))
  (def [found _] (wait-for |(string/find "\nNO-POSITION" $)))
  (check/ok found "the keystroke still reached the program")
  (harness/stop))

(check/test "the DA1 scanner counts queries and carries a split one"
  # Pure half of the fix: a read() splits the stream wherever it likes, so
  # the scanner must find a query that arrives half in one chunk and half in
  # the next -- and find it exactly once.
  (check/is= [1 ""] (harness/da1-queries "" "\e[c"))
  (check/is= [1 ""] (harness/da1-queries "" "before \e[0c after"))
  (check/is= [2 ""] (harness/da1-queries "" "\e[c\e[c"))
  (check/is= [0 "\e["] (harness/da1-queries "" "output ends \e["))
  (check/is= [1 ""] (harness/da1-queries "\e[" "c and more"))
  (check/is= [0 "\e[0"] (harness/da1-queries "\e[" "0"))
  (check/is= [1 ""] (harness/da1-queries "\e[0" "c"))
  (check/is= [0 ""] (harness/da1-queries "" "\e[0m is a colour, not a query"))
  (check/is= [0 ""] (harness/da1-queries "\e[" "2J is a clear, not a query")))

(check/test "a DA1 query is answered, page or no page"
  # THE STARTUP FREEZE. claude sends ESC [ c and waits for the terminal to
  # say what it is; a terminal that stays silent freezes it in exactly the
  # reported shape. The emulator that could answer lives in a browser page
  # that may not even be open -- so the supervisor answers, and this test
  # runs with no page polling at all, which is the point. `head -c 5`
  # consumes exactly the VT102 reply (ESC [ ? 6 c), so ANSWERED printing
  # proves the bytes reached the program's stdin.
  (harness/start ["/bin/sh" "-c"
                  "stty raw -echo; printf '\\033[c'; head -c 5 >/dev/null; echo ANSWERED"]
                 (os/cwd) 24 80)
  (def [found _] (wait-for |(string/find "ANSWERED" $)))
  (check/ok found "the reply reached the waiting program")
  (harness/stop))

(check/test "live reading continues past the backlog cap"
  # THE LONG-SESSION STALL. Chunk numbers used to be positions in the backlog
  # array, and the cap trims that array from the front -- so once a session
  # produced more chunks than the cap, the length pinned there, a client
  # whose `at` had reached it got an empty reply, and got one forever after.
  # Live output stopped while a reload (which starts from zero) showed
  # everything: exactly the reported shape. Numbers are absolute now.
  #
  # The cap is shrunk via the env knob so this runs in seconds; each printf
  # is followed by a drip of sleep so the pty delivers many small chunks
  # rather than one big one.
  (os/setenv "VISUALIZE_BACKLOG" "40")
  (harness/shutdown)   # the running supervisor has the old cap
  (ev/sleep 0.3)
  (harness/start ["/bin/sh" "-c"
                  "i=0; while [ $i -lt 300 ]; do echo tick-$i; i=$((i+1)); sleep 0.005; done; echo CAP-DONE"]
                 (os/cwd) 24 80)
  # Follow INCREMENTALLY, as the page does -- never from zero.
  (var at 0)
  (var seen @"")
  (var tries 0)
  (while (and (< tries 600) (not (string/find "CAP-DONE" (string seen))))
    (++ tries)
    (ev/sleep 0.03)
    (def reply (harness/poll at 0))
    (buffer/push-string seen (get reply "text" ""))
    (set at (get reply "at" at)))
  (check/ok (string/find "CAP-DONE" (string seen))
            "incremental polling reaches the end of a session larger than the cap")
  (check/ok (string/find "tick-299" (string seen))
            "and the late output arrived live, not only on reload")
  (def now (harness/poll at 0))
  (check/ok (get now "trimmed")
            "the session reports its history as trimmed, so a reattach knows not to replay it")
  # THE TEAR IS REPORTED. A client whose position the trim passed receives a
  # stream starting beyond what it asked for, and `from` says so -- which is
  # how the page knows to reset and ask for a repaint instead of painting a
  # stream that begins mid-escape-sequence.
  (def gen (get now "generation"))
  (def torn (harness/poll 1 gen))
  (check/ok (> (get torn "from") 1)
            "a reply past a trimmed position reports where it really starts")
  (def intact (harness/poll at gen))
  (check/is= at (get intact "from")
             "an untrimmed position reports exactly itself")
  (harness/stop)
  (harness/shutdown)   # do not leave a small-cap supervisor for later tests
  (os/setenv "VISUALIZE_BACKLOG" nil)
  (ev/sleep 0.3))

(check/test "shutdown ends the supervisor and takes the socket with it"
  # What ctrl-c does. Also this suite's teardown: leaving a supervisor behind
  # would make the next run adopt a session it did not start, and the tests
  # that count generations would start failing for reasons of their own.
  (harness/start ["/bin/sh" "-c" "sleep 30"] (os/cwd) 24 80)
  (harness/shutdown)
  (var gone false)
  (for _ 0 40
    (unless gone
      (ev/sleep 0.05)
      (set gone (not (os/stat socket :mode)))))
  (check/ok gone "the socket file is cleaned up, so the next run binds")
  (check/ok (not ((harness/state) :running)) "and nothing answers on it"))
