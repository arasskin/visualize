#!/usr/bin/env janet
#
# The process that owns the terminal, so the server can be restarted.
#
#     janet src/supervisor.janet <socket-path>
#
# WHY THIS EXISTS. A pty's master fd lives in the fd table of the process that
# called `forkpty`, and an fd cannot outlive its process. So as long as the
# server owned the terminal, editing a line of Janet meant killing the agent:
# restart the server and the running session went with it. Moving the fd one
# process outward is what makes `--watch` possible at all -- the server becomes
# disposable, and the agent stops caring how many times it is rebuilt.
#
# NOT A DAEMON. The supervisor's life is bounded by the session that started
# it: the server spawns it on the first `start` and tells it to `shutdown` on
# ctrl-c, which kills the agent exactly as closing the old single process did.
# There are no idle timeouts and no orphan sweeps, because there is nothing to
# sweep -- a supervisor without a server is a crash, not a state to manage.
#
# WHAT MOVED. `backlog`, `drain`, `since`, `start`, `stop`, `send`, `resize`
# and `state` are the bodies that used to be src/harness.janet, unchanged in
# substance. That file is now the client stub that talks to this one, and the
# HTTP routes above it never learned the difference.

(import ./pty)
(import ./json)

# What the harness has printed, oldest first, as chunks. Capped so a session
# that runs for hours does not grow without bound -- the browser only ever
# needs enough to redraw its screen, and the emulator's own scrollback holds
# the rest on the client side.
(def- backlog-limit 4000)

(var- session nil)      # the live pty, or nil
(var- output nil)       # channel the pump thread writes into
(var- backlog @[])      # chunks, for a page that reloads or arrives late
(var- generation 0)     # bumped per start, so a stale client can tell
(var- exited false)

(defn- drain
  ``Move whatever the pump thread has produced into the backlog.

  MUST NOT BLOCK. `ev/take` on an empty channel suspends until something
  arrives, which would hang the request that called it -- so `ev/count` says
  how many items are actually waiting and only that many are taken.``
  []
  (when output
    (repeat (ev/count output)
      (def value (ev/take output))
      (if (= value :eof)
        (set exited true)
        (do (array/push backlog value)
            (when (> (length backlog) backlog-limit)
              (array/remove backlog 0)))))))

# THE TERMINAL USED TO HANG HERE, and the mechanism is worth stating because
# nothing about it looks like a bug at the call site.
#
# `ev/give` BLOCKS when a thread channel is full. The pump thread gives one
# item per read, and `drain` above used to run only when a request arrived --
# so an agent that produced more than the channel's capacity between two polls
# filled it, and the pump blocked forever on the give.
#
# A blocked pump stops calling read() on the pty master. The kernel's buffer
# fills, the agent blocks writing into it, and the whole session freezes --
# while the browser keeps polling happily and the cursor keeps blinking,
# because that blink is a CSS animation with no connection to the process at
# all. Measured: with a 1024-slot channel the backlog stopped at exactly 1025
# chunks and the program never reached its last line.
#
# So draining is now on a timer as well as on request. The channel is a
# HANDOFF, not a buffer -- the backlog is the buffer, it lives in this process
# where it can be capped by discarding the OLDEST output rather than by
# stalling the producer, and dropping scrollback nobody asked for is the right
# thing to lose under pressure.
(defn- keep-draining
  ``Empty the pump's channel continuously, whether or not anyone is polling.

  20ms is far below the rate at which a person notices latency and far above
  the cost of an `ev/count` on an empty channel, which is what this does the
  overwhelming majority of the time.``
  []
  (ev/go
    (fn []
      (forever
        (ev/sleep 0.02)
        (try (drain) ([_] nil))))))

(defn- running?
  "Is a harness alive right now?"
  []
  (drain)
  (and session (not exited) (pty/alive? session)))

(defn- state
  "What the page needs to know about the session, without its output."
  []
  {"running" (truthy? (running?))
   "generation" generation
   "argv" (if session (session :argv) [])
   "chunks" (length backlog)})

(defn- start
  ``Start `argv` on a pty, replacing any session already running.

  `rows` and `cols` come from the browser, which is the only thing that knows
  how big the panel is.``
  [argv root rows cols]
  (when session (try (pty/close session) ([_] nil)))
  (set backlog @[])
  (set exited false)
  (++ generation)

  # Generous, but the capacity is no longer what keeps the pump running --
  # `keep-draining` is. This is only headroom for a burst that lands between
  # two ticks of that loop, so the producer never even approaches the wall.
  (def channel (ev/thread-chan 8192))
  (def ready (ev/thread-chan 2))
  # The pty is opened ON THE THREAD, not here, because the thread is where it
  # will be read: an ffi-signature cannot cross a thread boundary, so the
  # session must be created on the side that uses it.
  (ev/thread
    (fn [[reply out command directory lines columns]]
      (def opened (pty/open command lines columns
                            (let [environment (os/environ)]
                              (put environment "PWD" directory)
                              environment)))
      (ev/give reply opened)
      (pty/pump opened (fn [chunk] (ev/give out chunk)))
      (ev/give out :eof)
      :done)
    [ready channel argv root rows cols]
    :nt (ev/thread-chan 2))

  (set session (ev/take ready))
  (set output channel)
  (state))

(defn- stop
  ``Stop the harness, if one is running.

  Kills the agent but NOT this process: the next `start` reuses the supervisor
  rather than paying to spawn another. Only `shutdown` ends the process.``
  []
  (when session
    (try (pty/close session) ([_] nil))
    (set session nil)
    (set output nil)
    (set exited true))
  (state))

(defn- send
  "Type at the harness."
  [text]
  (when (and session (not exited))
    (try (pty/write-input session text) ([_] nil)))
  nil)

(defn- resize
  "Tell the harness its window changed size."
  [rows cols]
  (when session
    (try (pty/resize session rows cols) ([_] nil)))
  nil)

(defn- since
  ``Everything the harness has printed since chunk `at`.

  Returns [text next]. The client sends back the `next` it was given, so a
  reload replays from the beginning and a live page only gets what is new.``
  [at]
  (drain)
  (def from (max 0 (min at (length backlog))))
  [(string/join (slice backlog from) "") (length backlog)])

# -- the protocol -------------------------------------------------------------
#
# One request per connection, a line of JSON each way. The same shape as the
# HTTP server above it (see src/http.janet): a connection carries one message
# and the client opens another when it wants one, which is simpler than
# getting framing and reuse subtly right for a caller that makes a handful of
# requests a second.
#
# NO TOKEN HERE, deliberately. The HTTP endpoints need one because a browser
# will POST to 127.0.0.1 from any origin that asks -- see `permitted?` in
# visualize.janet. A unix socket has no origin and no port to guess: reaching
# it means having filesystem access to the path, which is the boundary.

(defn handle
  ``Answer one decoded request. Returns [reply done?].

  `done?` is true only for `shutdown`, which is the single op that ends the
  process. Split out from the socket loop so the whole protocol is testable
  without binding anything.``
  [message]
  (def op (string (get message "op" "")))
  (defn number-at [key fallback]
    (math/floor (or (get message key) fallback)))
  (cond
    (= op "start")
    [(start (map string (get message "argv" []))
            (string (get message "root" "."))
            (number-at "rows" 24)
            (number-at "cols" 100))
     false]

    (= op "stop") [(stop) false]

    (= op "input") (do (send (string (get message "text" ""))) [{"ok" true} false])

    (= op "resize")
    (do (resize (number-at "rows" 24) (number-at "cols" 100))
        [{"ok" true} false])

    (= op "since")
    # A CLIENT'S `at` ONLY MEANS ANYTHING WITHIN ONE SESSION. Restarting
    # empties the backlog, so a page still holding a position from the old one
    # is asking about chunks that no longer exist -- `since` clamps that to the
    # end and returns nothing, and the page sits blank in front of a running
    # agent.
    #
    # So the page sends the generation its position belongs to, and a mismatch
    # replays from the beginning. Answered here rather than by asking the page
    # to notice and re-poll, because that costs a round trip during which the
    # screen is empty, and because the supervisor is the only side that knows
    # what a generation means.
    (let [asked (number-at "generation" -1)
          now (state)
          stale (and (>= asked 0) (not= asked (now "generation")))
          [text next] (since (if stale 0 (number-at "at" 0)))]
      [{"text" text
        "at" next
        "running" (now "running")
        "generation" (now "generation")}
       false])

    (= op "state") [(state) false]

    # The server says this on ctrl-c, and only then. Killing the agent here is
    # what preserves the behaviour of the single-process version: quitting
    # visualize takes the harness with it. A server that is merely restarting
    # -- because a file changed -- just closes the socket and says nothing.
    (= op "shutdown") [(do (stop) {"ok" true}) true]

    [{"error" (string "unknown op '" op "'")} false]))

(defn- serve
  ``Answer requests on `path` until a shutdown arrives.

  The socket file is removed on the way out so the next run binds cleanly:
  closing a unix socket leaves its file behind, and binding over one fails
  with "address already in use" rather than replacing it.``
  [path]
  (def server (net/server :unix path))
  (def done (ev/chan 1))
  # Before any connection is answered: the pump must never wait on a poll.
  (keep-draining)
  (defn answer [connection]
    (defer (:close connection)
      # READ UNTIL THE NEWLINE, not once. A single `:read` returns whatever
      # one chunk happened to carry, and a request longer than that -- a paste
      # into the terminal is the everyday case -- arrives as truncated JSON
      # that fails to parse. The client terminates every message with \n for
      # exactly this reason.
      (def request @"")
      (var reading true)
      (while reading
        (if (string/find "\n" (string request))
          (set reading false)
          (if-let [chunk (:read connection 65536)]
            (buffer/push-string request chunk)
            (set reading false))))
      (when (> (length request) 0)
        (def [reply finished] (handle (json/decode (string request))))
        (try (:write connection (string (json/encode reply) "\n")) ([_] nil))
        (when finished (ev/give done true)))))
  (ev/go
    (fn []
      (forever
        (def connection (try (:accept server) ([_] nil)))
        (unless connection (break))
        (ev/go (fn [] (try (answer connection) ([err] (eprintf "supervisor: %s" (string err)))))))))
  (ev/take done)
  (try (:close server) ([_] nil))
  (try (os/rm path) ([_] nil)))

(defn main [& args]
  (def path (get args 1))
  (unless path (error "usage: supervisor.janet <socket-path>"))
  # A crashed predecessor leaves its socket file behind, and binding over one
  # fails. The client only spawns us after finding nothing alive on that path,
  # so anything still here is dead by definition.
  (when (os/stat path :mode) (try (os/rm path) ([_] nil)))
  (serve path))
