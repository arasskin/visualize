# The pane client: talking to the host that owns a pane's live session.
#
# THIS FILE IS THE SERVER PROCESS. It speaks to a pane host over a unix
# socket, one line of JSON each way, and knows how to start one that outlives
# it. The session it talks about -- the pty, the pump thread, the backlog --
# is owned by ./pane-host.janet in another process entirely. ("Supervisor"
# survives in prose throughout this file and its neighbours: it is still the
# right English word for a process that owns and outlives a session, and
# --supervise is still the flag that starts one. Only the files changed
# names, to say which side of the wire each one is.)
#
# ONE CLIENT PER PANE, AND NO DEFAULT. This module used to expose both
# `make-client` and a module-level singleton with wrappers -- so core drove
# the agent pane through (harness/poll ...) and the repl pane through
# (:poll repl-client ...), the same operation written two ways, and adding
# a third pane meant choosing which. Clients are values now; core makes one
# per pane and hands it to the routes. `register` names them for the repl,
# which is the one caller that cannot hold a client of its own.
#
# THE WIRE IS THE CONTRACT, and it is the ONLY thing shared: this file does
# not import that one and cannot call into it. The op names and reply shapes
# below have to agree with `handle` there, and nothing but the protocol tests
# will tell you when they stop agreeing -- see the note there before adding
# an op.
#
# The HTTP routes in src/core.janet only ever see the API at the bottom:
# configure, start, stop, send, resize, redraw, state, since, poll, shutdown.

(import ./json)

# -- the client --------------------------------------------------------------

(defn- talk
  ``One request and its reply over an open connection, or nil on EOF.

  Reads to the newline the supervisor terminates every reply with: a `since`
  reply routinely exceeds one chunk, and a single :read would hand json/decode
  a truncated object. Throws if the connection is dead, which `ask` treats as
  "drop it and try a fresh one".``
  [connection message &opt deadline]
  # TEN-SECOND DEADLINES on both directions, by default. Without them, a
  # supervisor that accepts and then wedges -- which one did, when a pty open
  # failed before its reply was sent -- hangs this read forever, and the HTTP
  # request above it, and the page above that. The longest honest ordinary
  # operation is a start under heavy load; ten seconds is far beyond it, and
  # a timeout lands in `ask`'s retry path like any other dead connection.
  # A parked `since` (see the wait handling in session/handle) is the one
  # caller that legitimately holds longer, and it says so.
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
  # NO LINE MEANS THIS CONNECTION IS POISONED, and saying so is the whole
  # difference between a failed request and a corrupted stream. The request
  # was already written; if the reply did not arrive whole, the host may
  # still send it -- into the next exchange on this connection, which then
  # reads the PREVIOUS answer to the PREVIOUS question. Answers shift by one
  # and never recover. That is not theoretical: it put a raw `since` REQUEST
  # into an HTTP response body, which is what a browser (or ./pane) sees as
  # "BadStatusLine: {"op":"since"}". Callers close on error, so throwing is
  # what makes reuse impossible; returning nil would let a standing
  # connection carry the damage forward.
  (unless line (error "incomplete reply -- connection unusable"))
  (json/decode line))

(defn- client-state
  ``A `state` reply as this side's callers expect it: keyword keys, and a
  value for every field even when the supervisor is gone.

  ONE PLACE FOR THE KEYS because `start`, `stop` and `state` all answer with
  the same shape, and the routes hand it straight to `json/encode` -- a
  keyword encodes as its bare name, so `:running` reaches the browser as
  "running" and the page cannot tell which of the three it asked.``
  [reply]
  {:running (truthy? (get reply "running"))
   :generation (or (get reply "generation") 0)
   :argv (or (get reply "argv") [])
   :chunks (or (get reply "chunks") 0)})

(defn make-client
  ``A handle on ONE supervisor: the socket it listens on, and the argv that
  starts one when nothing is there.

  A handle rather than module state, because there are two supervisors now --
  the agent's, shared per project root, and the repl window's. Each handle
  owns its own pinned connection and its own turn-lock: two supervisors'
  replies interleaved over shared state would pair answers with the wrong
  questions exactly as two fibers' would.

  Returns a table of closures, called method-style: (:poll client at). The
  module-level functions below drive a default handle set by `configure`, so
  the routes and the tests that predate the second supervisor read unchanged.

  `path` is keyed to the project root by the caller, so two copies of
  visualize pointed at different directories do not share a terminal.``
  [path argv]
  # ONE CONNECTION, KEPT OPEN -- not one per request.
  #
  # The per-request version opened and closed a unix socket for every poll,
  # several times a second, and each of those briefly owned the process's
  # lowest free fd -- the same number every new browser connection was about
  # to be handed. That churn is what tickled a runtime fd/reuse race on
  # macOS: under a real browser's concurrency, an occasional net/write blew
  # up with EBADF on a connection whose fd had been closed behind its back,
  # the page declared itself disconnected, and the terminal froze. Slowing
  # the fibers down with logging made it vanish, which is the signature of
  # exactly this kind of race.
  #
  # A pinned connection removes the churn (and, incidentally, four syscalls
  # per poll). The turn-lock matters as much as the pinning: several fibers
  # ask at once -- a poll races a resize races an input -- and interleaved
  # writes on one socket would pair replies with the wrong requests.
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


  # A connection to the supervisor, or nil if nothing is listening.
  #
  # The stat comes first because it is free: a `net/connect` that fails still
  # burns a file descriptor at the kernel for a moment, and during supervisor
  # boot this used to be called in a tight retry loop -- a storm of
  # short-lived fds churning the exact numbers the browser's connections were
  # being handed, which fed the EBADF race. No socket file, no syscall.
  (defn connect []
    (when (and path (os/stat path :mode))
      (try (net/connect :unix path) ([_] nil))))

  # THE PARK CONNECTION, standing like the pinned one and for the same
  # reason. Wait-polls used to open a fresh unix socket per park, and during
  # a scroll the parked poll wakes and re-parks tens of times a second --
  # tens of connections a second churning the process's lowest fd numbers,
  # which is precisely the regime that tickles the macOS fd-reuse race the
  # pinned connection was built to end (see the note above it). Every reply
  # that race dropped knocked the page out of its streaming chain into
  # retry cadence: the intermittent multi-second hangs that survived four
  # redesigns of wheel pacing, because they were never about the wheel.
  # One page parks one poll at a time, so one standing connection serves;
  # a second concurrent park -- another tab -- falls back to a fresh
  # connection rather than queueing 20 seconds behind the first.
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

  # Start the supervisor so that it outlives this process.
  #
  # VIA `sh -c '... &'`, NOT `os/spawn` WITH `:d`. Janet's `:d` flag does not
  # mean what the name suggests here: the runtime still tracks the child for
  # reaping, and the spawning process WEDGES rather than continuing --
  # measured, not assumed. `os/spawn`'s own documentation is explicit that
  # the caller must wait on the process, which is precisely what a supervisor
  # outliving us cannot allow.
  #
  # So the shell forks and exits, orphaning the supervisor onto init. Nothing
  # waits on it and nothing needs to: it is ended by the `shutdown` op on
  # ctrl-c, not by a signal that happens to reach it.
  #
  # Output goes to /dev/null because there is no terminal to write to -- the
  # supervisor's errors are its own, and a stray write to a closed stdout
  # from an orphan is a way to die confusingly.
  (defn spawn-detached []
    (def quoted (string/join (map |(string "'" (string/replace-all "'" "'\\''" $) "'")
                                  argv)
                             " "))
    # The descriptor closes matter as much as the redirects. A forked child
    # inherits every open fd, INCLUDING THE SERVER'S LISTENING SOCKET -- and
    # a supervisor holding that fd keeps the port undead after the server
    # exits: the kernel still accepts connections into the backlog of a
    # socket nobody will ever read, so clients hang instead of being refused,
    # and the next server's is-it-free probe reads "taken". Ports 3-9 cover
    # everything the server has open at first-start time; the supervisor
    # opens its own fds after exec.
    # The supervisor's stderr normally goes nowhere -- it is an orphan with
    # no terminal. VISUALIZE_SUPERVISOR_LOG names a file to keep it instead,
    # which is how the drain race was finally caught in the act.
    (def errlog (or (os/getenv "VISUALIZE_SUPERVISOR_LOG") "/dev/null"))
    (os/execute ["/bin/sh" "-c"
                 (string quoted " >/dev/null 2>" errlog
                         " 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &")]
                :p))

  # A connection to a running supervisor, starting one if there is none.
  #
  # THREE CASES, and the third is the one that bites. A live socket connects.
  # No socket file at all means nothing has run yet. A socket file that
  # REFUSES the connection is the leftover of a crashed supervisor -- closing
  # a unix socket leaves its file on disk, and binding over one fails rather
  # than replacing it, so the file has to go before a new supervisor can
  # start.
  (defn ensure []
    (or (connect)
        (do
          (when (os/stat path :mode) (try (os/rm path) ([_] nil)))
          (spawn-detached)
          # Spawn is not listen: the child has to get as far as binding
          # before a connection can land. Retried on a short timer rather
          # than slept on once, so the common case costs a few milliseconds
          # and a slow start still succeeds.
          (var found nil)
          (for _ 0 100
            (unless found
              (ev/sleep 0.02)
              (set found (connect))))
          found)))

  # Send one request and read the reply, or nil if the supervisor is gone.
  #
  # Every failure lands here as nil rather than an error: the supervisor
  # dying should degrade the terminal panel, not take down the request that
  # noticed.
  #
  # A dead pinned connection gets ONE retry on a fresh one -- the supervisor
  # may simply have restarted between requests -- and a failure after that
  # answers nil like any other.
  # The server-side halves of every exchange's timing: how long the turn
  # was waited for, how long the supervisor took to answer. The SPLIT is
  # the diagnostic -- during the hang hunt, "turn-wait=10.00 talk=0.00"
  # against "turn-wait=0.00 talk=10.00" was what separated "queued behind
  # a wedged exchange" from "the wedged exchange itself".
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
    (take-turn)
    (def turned (os/clock :monotonic))
    (defer (do (give-turn)
               (note-ask (string (get message "op" "?"))
                         (- turned asked) (- (os/clock :monotonic) turned)))
      (when (nil? pinned)
        (set pinned (if start? (ensure) (connect))))
      (when pinned
        (def reply (try (talk pinned message) ([_] nil)))
        (if reply
          reply
          (do
            (drop-pinned)
            (set pinned (if start? (ensure) (connect)))
            (when pinned
              (def again (try (talk pinned message) ([_] nil)))
              (unless again (drop-pinned))
              again))))))

  # `start` is the only op that may bring a supervisor into being. Everything
  # else talks to one that is already there -- polling a terminal nobody
  # started should answer "not running", not silently spawn a process.
  {# This side's ask timings, and the supervisor's own table over the wire.
   :stats (fn [_] ask-stats)
   :remote-stats (fn [_] (ask {"op" "stats"}))

   :start
   (fn [_ run-argv root &opt rows cols]
     (default rows 24)
     (default cols 100)
     (client-state (ask {"op" "start" "argv" run-argv "root" root
                         "rows" rows "cols" cols}
                        true)))

   :stop
   (fn [_] (client-state (ask {"op" "stop"})))

   # With `at`, the reply carries the ECHO -- everything the program printed
   # in response, in the same round trip. That is what makes typing feel
   # immediate: polling for the effect of your own keystroke costs a second
   # round trip even when the delay between polls is zero, because the page
   # has to wait for this request to return before it can ask what happened.
   # Without `at` it answers nil as it always did.
   :send
   (fn [_ text &opt at quiet]
     (def message @{"op" "input" "text" text})
     (when at (put message "at" at))
     (when quiet (put message "quiet" true))
     (def reply (ask message))
     (when (and reply (get reply "text"))
       {"text" (get reply "text")
        "at" (or (get reply "at") at)
        "from" (or (get reply "from") -1)
        "running" (truthy? (get reply "running"))
        "generation" (or (get reply "generation") 0)}))

   :resize
   (fn [_ rows cols]
     (ask {"op" "resize" "rows" rows "cols" cols})
     nil)

   :redraw
   (fn [_]
     (ask {"op" "redraw"})
     nil)

   :state
   (fn [_] (client-state (ask {"op" "state"})))

   # Everything printed since chunk `at`, as [text next]. With no supervisor
   # running this is ["" at] -- nothing new rather than an error, which is
   # exactly what a page polling an unstarted terminal should see.
   :since
   (fn [_ at]
     (def reply (ask {"op" "since" "at" at}))
     (if reply
       [(or (get reply "text") "") (or (get reply "at") at)]
       ["" at]))

   # The whole answer to one poll, in a single round trip. Kept as one call
   # rather than `since` plus `state` because it is the hot path -- the page
   # asks several times a second -- and two round trips per poll is twice the
   # syscalls for one answer.
   #
   # `generation` is the session the page's `at` belongs to. The supervisor
   # replays from the beginning when it does not match the running session,
   # which is what stops a page from sitting blank in front of a restarted
   # agent.
   :poll
   (fn [_ at &opt generation wait]
     (def message @{"op" "since" "at" at})
     (when generation (put message "generation" generation))
     (def reply
       (if (and wait (pos? wait))
         # A waiting poll must not hold the pinned connection's turn: input
         # and resize share it, and a keystroke queued behind a 20-second
         # park is a frozen keyboard. So ask the cheap question over the
         # pinned path first -- during a streaming burst there is already
         # output, and this answers without opening anything -- and only a
         # quiet session parks, on a PRIVATE connection whose lifetime is
         # the park. That keeps connection churn to one per quiet period
         # rather than the one-per-poll that used to feed the macOS fd race.
         (let [quick (ask message)]
           # Park only on a quiet, LIVE session: text in hand answers now,
           # and a dead session's "exited" must reach the page promptly, not
           # after a park that can learn nothing.
           (if (or (nil? quick)
                   (not (empty? (get quick "text" "")))
                   (not (truthy? (get quick "running"))))
             quick
             (do
               (put message "wait" wait)
               (or (park-talk message (+ 10 (/ wait 1000))) quick))))
         (ask message)))
     (if reply
       {"text" (or (get reply "text") "")
        "at" (or (get reply "at") at)
        # Where the reply's text actually starts. -1 from a supervisor that
        # predates tear reporting; the page then skips tear detection.
        "from" (or (get reply "from") -1)
        "running" (truthy? (get reply "running"))
        "generation" (or (get reply "generation") 0)
        # The geometry the recording was made for. A reattaching page replays
        # into a grid of THIS size, not the panel's -- see the attach path.
        "rows" (or (get reply "rows") 24)
        "cols" (or (get reply "cols") 80)
        "trimmed" (truthy? (get reply "trimmed"))
        # Whether the supervisor understood `wait` -- the page's signal that
        # it may chain polls with no timer instead of pacing them.
        "waited" (truthy? (get reply "waited"))
        "stamp" (or (get reply "stamp") "")
        "reachable" true}
       # UNREACHABLE IS NOT DEAD. This fallback used to say running=false,
       # generation=0 -- and the page, taking it as truth, blanked its screen
       # for the generation change, showed "exited", and stopped polling. All
       # of that for one supervisor blip: a deadline expiring while the
       # machine woke from sleep. The flag lets the page treat this as the
       # failed request it is, and keep both its screen and its session.
       # `absent` separates "safe to start a fresh session" from "wait, one
       # is coming back". No socket file: nothing ever started, or a clean
       # shutdown -- start away. File present: probe it. A unix connect with
       # no listener is REFUSED instantly, which means the supervisor is dead
       # and the file is a corpse a crash left behind -- also safe, since
       # ensure clears it. Only accepted-but-unresponsive is a genuine blip
       # (a machine mid-wake), where starting would shoot the session about
       # to return.
       {"text" "" "at" at "running" false "generation" 0 "rows" 24 "cols" 80
        "reachable" false
        "absent" (if (and path (os/stat path :mode))
                   (if-let [probe (try (net/connect :unix path) ([_] nil))]
                     (do (try (:close probe) ([_] nil)) false)
                     true)
                   true)}))

   # End the supervisor, killing its session with it. CALLED ON CTRL-C AND
   # NOWHERE ELSE. Quitting visualize takes the terminal down exactly as it
   # did when one process owned everything; a server that is merely
   # restarting because a file changed must NOT call this -- it closes the
   # socket and says nothing, which is what leaves the agent running.
   :shutdown
   (fn [_]
     (ask {"op" "shutdown"})
     # The supervisor is gone; a conn pinned to it would cost the next caller
     # a dead-connection retry for nothing. The park connection likewise.
     (drop-pinned)
     (when parked-conn
       (try (:close parked-conn) ([_] nil))
       (set parked-conn nil))
     nil)})

# -- the debugging equipment ---------------------------------------------------
# The hang hunt's tools, kept where the next investigator -- human or model --
# will find them: at the repl, named in its connection banner (see
# `equipment` below, which core.janet hands to dev/serve).
#
# THESE LIVE HERE, NOT IN dev.janet, because their subject is the session and
# dev.janet is about the repl -- a socket, an evaluator, a debugger, hot
# reload, none of it terminal-specific. The repl reaches these the way it
# reaches everything else: it evaluates in an env whose proto is the server's
# own, so `(pane-client/stats)` needs no import and dev.janet stays liftable
# into a program that has no terminal at all.

(def- here (os/realpath (string (dyn :current-file) "/../..")))

# The panes this server made, by name, so the repl can ask about one without
# the caller having to hold its client. Registered by core as it builds them;
# a plain table because a person at a prompt should be able to see what is
# there with (keys pane-client/panes).
(def panes @{})

(defn register
  ``Give a client a name the repl can use: (stats "harness"), (dump "repl").
  Returns the client, so a caller can register and bind in one expression.``
  [name client]
  (put panes name client)
  client)

(defn- named
  "The client called `name`, or the only one when there is just one."
  [name]
  (or (get panes name)
      (if (and (nil? name) (= 1 (length panes)))
        (first (values panes))
        (errorf "no pane named %v -- try one of %j" name (keys panes)))))

(defn stats
  ``Print both sides' op timings for one pane: the server's asks (turn-wait
  vs talk -- the split that separates "queued behind a wedged exchange" from
  "the wedged exchange itself") and the host's handle table, plus its queue
  depths. Numbers survive since each process started.``
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

(defn dump
  ``Write one pane's whole backlog -- the recording of everything the program
  drew -- to `path`, and say how to replay it. This is the capture half of
  the forensic loop that convicted the wrap and alternate-screen bugs;
  `replay` is the other half.``
  [&opt name path]
  (def client (named name))
  (default path (string "/tmp/visualize-dump-" (os/time) ".bin"))
  (def now (:poll client 0))
  (def text (get now "text" ""))
  (spit path text)
  (def rows (get now "rows" 24))
  (def cols (get now "cols" 80))
  (printf "%d bytes -> %s (recorded at %dx%d)" (length text) path rows cols)
  (printf "replay: (pane-client/replay nil %v) or: node %s/tools/replay.mjs %s --rows %d --cols %d"
          path here path rows cols)
  path)

(defn replay
  ``Run a capture through the emulator headlessly and report suspects --
  escape-like text on the final screen, the signature of a torn stream or a
  parser gap. Geometry defaults to the named pane's, since a recording
  replayed at the wrong size scatters absolute cursor positions.``
  [name path &opt rows cols]
  # `state`, not `poll`: the geometry is two integers, and poll would drag
  # the entire backlog over the socket to deliver them.
  (unless (and rows cols)
    (def now (:state (named name)))
    (default rows (get now :rows 24))
    (default cols (get now :cols 80)))
  # Spawned with a pipe rather than executed: the child's stdout is the
  # PROCESS's stdout -- the server's log -- while the repl reader is on the
  # other end of a socket. Read and re-print, so the verdict lands where the
  # question was asked.
  (def proc (os/spawn ["node" (string here "/tools/replay.mjs") path
                       "--rows" (string rows) "--cols" (string cols)]
                      :p {:out :pipe :err :pipe}))
  (def said (:read (proc :out) :all))
  (def complained (:read (proc :err) :all))
  (os/proc-wait proc)
  (when said (prin said))
  (when (and complained (pos? (length complained))) (prin complained))
  nil)

(def equipment
  ``The banner lines describing the above, handed to dev/serve by core.janet
  so the repl advertises the terminal's tools without knowing what they are.``
  (string "panes:    (pane-client/stats \"harness\") op timings both sides\n"
          "          (pane-client/dump \"harness\") capture it · (pane-client/replay\n"
          "          \"harness\" path) re-render a capture · pane-client/panes\n"))
