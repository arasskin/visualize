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

(defn configure
  ``Where the supervisor is, and how to start one if it is not running.

  `path` is keyed to the project root by the caller, so two copies of
  visualize pointed at different directories do not share a terminal.``
  [path argv]
  (set socket-path path)
  (set spawn-argv argv))

(defn- connect
  "A connection to the supervisor, or nil if nothing is listening."
  []
  (when socket-path
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

(defn- ask
  ``Send one request and read the reply, or nil if the supervisor is gone.

  Every failure lands here as nil rather than an error: the supervisor dying
  should degrade the terminal panel, not take down the request that noticed.``
  [message &opt start?]
  (def connection (if start? (ensure) (connect)))
  (when connection
    (defer (:close connection)
      (try
        (do
          (:write connection (string (json/encode message) "\n"))
          # READ UNTIL THE NEWLINE. A `since` reply carries everything the
          # agent printed since the last poll, which routinely exceeds one
          # chunk -- and a single `:read` would hand `json/decode` a truncated
          # object. The supervisor terminates every reply with \n so there is
          # a definite end to look for.
          (def reply @"")
          (var reading true)
          (while reading
            (if (string/find "\n" (string reply))
              (set reading false)
              (if-let [chunk (:read connection 65536)]
                (buffer/push-string reply chunk)
                (set reading false))))
          (when (> (length reply) 0)
            (json/decode (string reply))))
        ([_] nil)))))

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
     "generation" (or (get reply "generation") 0)}
    {"text" "" "at" at "running" false "generation" 0}))

(defn shutdown
  ``End the supervisor, killing the agent with it.

  CALLED ON CTRL-C AND NOWHERE ELSE. Quitting visualize takes the terminal
  down exactly as it did when one process owned everything; a server that is
  merely restarting because a file changed must NOT call this -- it closes the
  socket and says nothing, which is what leaves the agent running.``
  []
  (ask {"op" "shutdown"})
  nil)
