# Talking to the process that owns the terminal.
#
# THE API HERE IS THE SAME ONE IT ALWAYS WAS -- `start`, `stop`, `send`,
# `resize`, `since`, `state` -- and the HTTP routes that call it did not change
# when the pty moved out of this process. That is the seam working: the routes
# in visualize.janet ask for the same things and get the same shapes back.
#
# WHAT IS ACTUALLY HERE NOW. The pty, the pump thread and the backlog live in
# src/supervisor.janet, in a process that outlives this one. Each function
# below opens a unix socket, writes a line of JSON and reads a line back. The
# server can therefore be killed and rebuilt as often as a file watcher likes,
# and the agent running in the terminal never notices.
#
# WHY OUTLIVING MATTERS. A pty's master fd belongs to the process that called
# `forkpty` and cannot be passed to a later one, so "restart the server, keep
# the session" is only possible if the server was never holding the fd.

(import ./json)

# Where the supervisor listens, and what to run to get one. Both are set once
# at startup by `configure` rather than recomputed here: this module has no way
# to know where the project root or the janet binary are, and guessing either
# is how you end up with two supervisors for one project.
(var- socket-path nil)
(var- spawn-argv nil)

# ONE CONNECTION, KEPT OPEN -- not one per request.
#
# The per-request version opened and closed a unix socket for every poll,
# several times a second, and each of those briefly owned the process's lowest
# free fd -- the same number every new browser connection was about to be
# handed. That churn is what tickled a runtime fd/reuse race on macOS: under a
# real browser's concurrency, an occasional net/write blew up with EBADF on a
# connection whose fd had been closed behind its back, the page declared
# itself disconnected, and the terminal froze. Slowing the fibers down with
# logging made it vanish, which is the signature of exactly this kind of race.
#
# A pinned connection removes the churn (and, incidentally, four syscalls per
# poll). The turn-lock matters as much as the pinning: several fibers ask at
# once -- a poll races a resize races an input -- and interleaved writes on one
# socket would pair replies with the wrong requests.
(var- pinned nil)
(def- turn @{:busy false :waiting @[]})

(defn- take-turn []
  (if (turn :busy)
    (let [ticket (ev/chan 1)]
      (array/push (turn :waiting) ticket)
      (ev/take ticket))
    (put turn :busy true)))

(defn- give-turn []
  (if (empty? (turn :waiting))
    (put turn :busy false)
    (let [ticket (get (turn :waiting) 0)]
      (array/remove (turn :waiting) 0)
      (ev/give ticket true))))

(defn- drop-pinned []
  (when pinned
    (try (:close pinned) ([_] nil))
    (set pinned nil)))

(defn configure
  ``Where the supervisor is, and how to start one if it is not running.

  `path` is keyed to the project root by the caller, so two copies of
  visualize pointed at different directories do not share a terminal.``
  [path argv]
  (set socket-path path)
  (set spawn-argv argv)
  # A connection pinned to the OLD socket must not answer for the new one.
  (drop-pinned))

(defn- connect
  ``A connection to the supervisor, or nil if nothing is listening.

  The stat comes first because it is free: a `net/connect` that fails still
  burns a file descriptor at the kernel for a moment, and during supervisor
  boot this used to be called in a tight retry loop -- a storm of short-lived
  fds churning the exact numbers the browser's connections were being handed,
  which fed the EBADF race. No socket file, no syscall.``
  []
  (when (and socket-path (os/stat socket-path :mode))
    (try (net/connect :unix socket-path) ([_] nil))))

(defn- spawn-detached
  ``Start the supervisor so that it outlives this process.

  VIA `sh -c '... &'`, NOT `os/spawn` WITH `:d`. Janet's `:d` flag does not
  mean what the name suggests here: the runtime still tracks the child for
  reaping, and the spawning process WEDGES rather than continuing -- measured,
  not assumed. `os/spawn`'s own documentation is explicit that the caller must
  wait on the process, which is precisely what a supervisor outliving us
  cannot allow.

  So the shell forks and exits, orphaning the supervisor onto init. Nothing
  waits on it and nothing needs to: it is ended by the `shutdown` op on
  ctrl-c, not by a signal that happens to reach it.

  Output goes to /dev/null because there is no terminal to write to -- the
  supervisor's errors are its own, and a stray write to a closed stdout from
  an orphan is a way to die confusingly.``
  []
  (def quoted (string/join (map |(string "'" (string/replace-all "'" "'\\''" $) "'")
                                spawn-argv)
                           " "))
  (os/execute ["/bin/sh" "-c" (string quoted " >/dev/null 2>&1 &")] :p))

(defn- ensure
  ``A connection to a running supervisor, starting one if there is none.

  THREE CASES, and the third is the one that bites. A live socket connects.
  No socket file at all means nothing has run yet. A socket file that REFUSES
  the connection is the leftover of a crashed supervisor -- closing a unix
  socket leaves its file on disk, and binding over one fails rather than
  replacing it, so the file has to go before a new supervisor can start.``
  []
  (or (connect)
      (do
        (when (os/stat socket-path :mode) (try (os/rm socket-path) ([_] nil)))
        (spawn-detached)
        # Spawn is not listen: the child has to get as far as binding before a
        # connection can land. Retried on a short timer rather than slept on
        # once, so the common case costs a few milliseconds and a slow start
        # still succeeds.
        (var found nil)
        (for _ 0 100
          (unless found
            (ev/sleep 0.02)
            (set found (connect))))
        found)))

(defn- talk
  ``One request and its reply over an open connection, or nil on EOF.

  Reads to the newline the supervisor terminates every reply with: a `since`
  reply routinely exceeds one chunk, and a single :read would hand json/decode
  a truncated object. Throws if the connection is dead, which `ask` treats as
  "drop it and try a fresh one".``
  [connection message]
  # TEN-SECOND DEADLINES on both directions. Without them, a supervisor that
  # accepts and then wedges -- which one did, when a pty open failed before
  # its reply was sent -- hangs this read forever, and the HTTP request above
  # it, and the page above that. The longest honest operation here is a start
  # under heavy load; ten seconds is far beyond it, and a timeout lands in
  # `ask`'s retry path like any other dead connection.
  (:write connection (string (json/encode message) "\n") 10)
  (def reply @"")
  (var line nil)
  (var reading true)
  (while reading
    (if-let [at (string/find "\n" (string reply))]
      (do (set line (string/slice (string reply) 0 at))
          (set reading false))
      (if-let [chunk (:read connection 65536 nil 10)]
        (buffer/push-string reply chunk)
        (set reading false))))
  (when line (json/decode line)))

(defn- ask
  ``Send one request and read the reply, or nil if the supervisor is gone.

  Every failure lands here as nil rather than an error: the supervisor dying
  should degrade the terminal panel, not take down the request that noticed.

  A dead pinned connection gets ONE retry on a fresh one -- the supervisor may
  simply have restarted between requests -- and a failure after that answers
  nil like any other.``
  [message &opt start?]
  (take-turn)
  (defer (give-turn)
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

(defn- session-state
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

# `start` is the only op that may bring a supervisor into being. Everything
# else talks to one that is already there -- polling a terminal nobody started
# should answer "not running", not silently spawn a process.
(defn start
  "Start `argv` on the supervisor's pty, replacing any session running."
  [argv root &opt rows cols]
  (default rows 24)
  (default cols 100)
  (session-state (ask {"op" "start" "argv" argv "root" root "rows" rows "cols" cols} true)))

(defn stop
  "Stop the harness, leaving the supervisor up for the next start."
  []
  (session-state (ask {"op" "stop"})))

(defn send
  ``Type at the harness.

  With `at`, the reply carries the ECHO -- everything the program printed in
  response, in the same round trip. That is what makes typing feel immediate:
  polling for the effect of your own keystroke costs a second round trip even
  when the delay between polls is zero, because the page has to wait for this
  request to return before it can ask what happened.

  Without `at` it answers {"ok" true} as it always did.``
  [text &opt at]
  (def reply (ask (if at
                    {"op" "input" "text" text "at" at}
                    {"op" "input" "text" text})))
  (when (and reply (get reply "text"))
    {"text" (get reply "text")
     "at" (or (get reply "at") at)
     "running" (truthy? (get reply "running"))
     "generation" (or (get reply "generation") 0)}))

(defn resize
  "Tell the harness its window changed size."
  [rows cols]
  (ask {"op" "resize" "rows" rows "cols" cols})
  nil)

(defn redraw
  ``Ask the program to repaint its screen -- what a reattaching page needs,
  since a byte-history replay cannot reconstruct a trimmed or resized frame.``
  []
  (ask {"op" "redraw"})
  nil)

(defn state
  "What the page needs to know about the session, without its output."
  []
  (session-state (ask {"op" "state"})))

(defn since
  ``Everything the harness has printed since chunk `at`. Returns [text next].

  With no supervisor running this is ["" at] -- nothing new rather than an
  error, which is exactly what a page polling an unstarted terminal should
  see.``
  [at]
  (def reply (ask {"op" "since" "at" at}))
  (if reply
    [(or (get reply "text") "") (or (get reply "at") at)]
    ["" at]))

(defn poll
  ``The whole answer to one `/harness/poll`, in a single round trip.

  Kept as one call rather than `since` plus `state` because it is the hot path
  -- the page asks several times a second -- and two connections per poll is
  twice the syscalls for one answer.

  `generation` is the session the page's `at` belongs to. The supervisor
  replays from the beginning when it does not match the running session, which
  is what stops a page from sitting blank in front of a restarted agent.``
  [at &opt generation]
  (def reply (ask (if generation
                    {"op" "since" "at" at "generation" generation}
                    {"op" "since" "at" at})))
  (if reply
    {"text" (or (get reply "text") "")
     "at" (or (get reply "at") at)
     "running" (truthy? (get reply "running"))
     "generation" (or (get reply "generation") 0)
     # The geometry the recording was made for. A reattaching page replays
     # into a grid of THIS size, not the panel's -- see the attach path.
     "rows" (or (get reply "rows") 24)
     "cols" (or (get reply "cols") 80)
     "reachable" true}
    # UNREACHABLE IS NOT DEAD. This fallback used to say running=false,
    # generation=0 -- and the page, taking it as truth, blanked its screen
    # for the generation change, showed "exited", and stopped polling. All of
    # that for one supervisor blip: a deadline expiring while the machine
    # woke from sleep. The flag lets the page treat this as the failed
    # request it is, and keep both its screen and its session.
    # `absent` separates "safe to start a fresh session" from "wait, one is
    # coming back". No socket file: nothing ever started, or a clean
    # shutdown -- start away. File present: probe it. A unix connect with no
    # listener is REFUSED instantly, which means the supervisor is dead and
    # the file is a corpse a crash left behind -- also safe, since ensure
    # clears it. Only accepted-but-unresponsive is a genuine blip (a machine
    # mid-wake), where starting would shoot the session about to return.
    {"text" "" "at" at "running" false "generation" 0 "rows" 24 "cols" 80
     "reachable" false
     "absent" (if (and socket-path (os/stat socket-path :mode))
                (if-let [probe (try (net/connect :unix socket-path) ([_] nil))]
                  (do (try (:close probe) ([_] nil)) false)
                  true)
                true)}))

(defn shutdown
  ``End the supervisor, killing the agent with it.

  CALLED ON CTRL-C AND NOWHERE ELSE. Quitting visualize takes the terminal
  down exactly as it did when one process owned everything; a server that is
  merely restarting because a file changed must NOT call this -- it closes the
  socket and says nothing, which is what leaves the agent running.``
  []
  (ask {"op" "shutdown"})
  # The supervisor is gone; a conn pinned to it would cost the next caller a
  # dead-connection retry for nothing.
  (drop-pinned)
  nil)
