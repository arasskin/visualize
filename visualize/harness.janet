# The harness: owning a live session, and talking to whoever owns it.
#
# TWO HALVES, TWO PROCESSES, ONE FILE. The first half OWNS a session -- the
# pty, the pump thread, the backlog -- and runs in the supervisor process,
# which `visualize.janet --supervise` starts and which outlives the server. A
# pty's master fd belongs to the process that called forkpty and cannot be
# passed to a later one, so "restart the server, keep the agent" is only
# possible if the server never holds the fd. The second half is the CLIENT the
# server runs: it speaks to the owner over a unix socket, one line of JSON
# each way.
#
# They share this file on purpose. The wire between them -- newline-framed
# JSON, the op names, the reply shapes -- is the contract both sides must
# agree on, and both sides of it reading from the same screen is what keeps
# them agreeing. The framing bugs this project has already paid for (a reply
# truncated at one read, a request split across chunks) were exactly the kind
# that creep in when the two ends live far apart.
#
# The HTTP routes in visualize.janet only ever see the client API at the
# bottom: configure, start, stop, send, resize, redraw, state, since, poll,
# shutdown. The session half's names carry a `session-` prefix so the two
# vocabularies cannot collide.

(import ./pty)
(import ./json)

# -- owning a session --------------------------------------------------------
# Everything from here to the wire section runs in the SUPERVISOR process.

(def- backlog-limit
  (or (scan-number (or (os/getenv "VISUALIZE_BACKLOG") "")) 4000))

(var- session nil)      # the live pty, or nil
(var- output nil)       # channel the pump thread writes into
(var- backlog @[])      # chunks, for a page that reloads or arrives late
# How many chunks have ever been trimmed off the front. Chunk numbers the
# clients hold are ABSOLUTE -- base + position -- because the cap shifts every
# array position when it trims. Numbering by position stalled every long
# session: once length pinned at the cap, a client whose `at` equalled it got
# an empty reply from then on, forever, while reloads (which start at zero)
# happily saw everything. Live output stopping while reloads work is exactly
# that bug's face.
(var- base 0)
(var- generation 0)     # bumped per start, so a stale client can tell
# The pty's current size, remembered because a RECORDING is meaningless
# without it: the backlog is bytes the program drew for a specific geometry,
# and a page that reattaches must replay them into a grid of that size or
# absolute cursor positions land in the wrong cells. Updated by start and
# resize, reported in state.
(var- pty-rows 24)
(var- pty-cols 80)
(var- exited false)

# DA1 IS ANSWERED HERE, because nowhere else can do it correctly. The
# emulator lives in the browser, but a page can attach late, reload -- which
# replays the whole backlog -- or not be open at all. A replayed query must
# not be answered a second time, and a program waiting with no page open must
# not wait forever: claude sends ESC [ c at startup and a terminal that stays
# silent freezes it. The supervisor is the one place the stream passes
# exactly once, in real time, next to the pty the reply belongs in.
#
# The reply claims VT102 -- the classic minimal answer. Programs that ask are
# overwhelmingly waiting for AN answer, and claiming a richer terminal would
# invite features the emulator does not draw.
(def- da1-reply "\e[?6c")

# A read() splits the stream wherever it likes, so a query can arrive half in
# one chunk and half in the next. The unfinished tail is carried into the
# next scan; it never matched as a whole query, so completing it there
# answers it exactly once.
(var- da1-carry "")

(defn da1-queries
  ``How many DA1 queries (ESC [ c, ESC [ 0 c) finish in `carry` + `chunk`,
  and the unfinished tail to carry into the next scan. Pure, for the tests:
  returns [count next-carry].``
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
  "Reply to any device query the program just asked, straight into the pty."
  [chunk]
  (def [hits carry] (da1-queries da1-carry chunk))
  (set da1-carry carry)
  (when (and (pos? hits) session (not exited))
    (repeat hits (try (pty/write-input session da1-reply) ([_] nil)))))

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
            (answer-queries value)
            (when (> (length backlog) backlog-limit)
              (array/remove backlog 0)
              (++ base)))))))

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

(defn- session-state
  "What the page needs to know about the session, without its output."
  []
  {"running" (truthy? (running?))
   "generation" generation
   "argv" (if session (session :argv) [])
   "chunks" (+ base (length backlog))
   "rows" pty-rows
   "trimmed" (pos? base)
   "cols" pty-cols})

(defn- session-start
  ``Start `argv` on a pty, replacing any session already running.

  `rows` and `cols` come from the browser, which is the only thing that knows
  how big the panel is.``
  [argv root rows cols]
  (when session (try (pty/close session) ([_] nil)))
  (set backlog @[])
  (set base 0)
  (set exited false)
  (set da1-carry "")
  (set pty-rows rows)
  (set pty-cols cols)
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
      # The give happens WHATEVER pty/open does. A forkpty or exec that fails
      # under resource pressure used to throw before the give, and the start
      # op then blocked forever in ev/take -- wedging the supervisor for every
      # later request, and with it the client, which had no deadline either.
      (def opened (try (pty/open command lines columns
                                 (let [environment (os/environ)]
                                   (put environment "PWD" directory)
                                   environment))
                    ([e] {:error (string e)})))
      (ev/give reply opened)
      (unless (opened :error)
        (pty/pump opened (fn [chunk] (ev/give out chunk)))
        (ev/give out :eof))
      :done)
    [ready channel argv root rows cols]
    :nt (ev/thread-chan 2))

  (def opened (ev/take ready))
  (if (opened :error)
    (do (set session nil)
        (set output nil)
        (set exited true)
        (merge (session-state) {"error" (opened :error)}))
    (do (set session opened)
        (set output channel)
        (session-state))))

(defn- session-stop
  ``Stop the harness, if one is running.

  Kills the agent but NOT this process: the next `start` reuses the supervisor
  rather than paying to spawn another. Only `shutdown` ends the process.``
  []
  (when session
    (try (pty/close session) ([_] nil))
    (set session nil)
    (set output nil)
    (set exited true))
  (session-state))

(defn- session-send
  "Type at the harness."
  [text]
  (when (and session (not exited))
    (try (pty/write-input session text) ([_] nil)))
  nil)

(defn- session-resize
  "Tell the harness its window changed size."
  [rows cols]
  (set pty-rows rows)
  (set pty-cols cols)
  (when session
    (try (pty/resize session rows cols) ([_] nil)))
  nil)

(defn- session-redraw
  ``Ask the program to repaint its whole screen, by the only universal means
  a terminal has: the window changed size.

  A reattaching page cannot reconstruct a perfect screen from the byte
  history -- the recording may start mid-frame after the backlog cap trimmed
  it, and it may span geometries. A full-screen program repaints cleanly on
  SIGWINCH, so the size is nudged one column down and back. A line-oriented
  program ignores both signals, which is also right: its replayed output was
  already fine.``
  []
  (when session
    (try (pty/resize session pty-rows (max 1 (dec pty-cols))) ([_] nil))
    (ev/sleep 0.05)
    (try (pty/resize session pty-rows pty-cols) ([_] nil)))
  nil)

(defn- session-since
  ``Everything the harness has printed since chunk `at`.

  Returns [text next]. The client sends back the `next` it was given, so a
  reload replays from the beginning and a live page only gets what is new.``
  [at]
  (drain)
  (def total (+ base (length backlog)))
  # Clamped to what still exists: a client older than the trim gets
  # everything retained, and one from the future (a restarted session it has
  # not noticed) gets clamped to the end -- the generation check is what
  # handles that case properly.
  (def from (max base (min at total)))
  [(string/join (slice backlog (- from base)) "") total])

# -- the protocol -------------------------------------------------------------
#
# One request per connection, a line of JSON each way. The same shape as the
# HTTP server above it (see visualize/http.janet): a connection carries one message
# and the client opens another when it wants one, which is simpler than
# getting framing and reuse subtly right for a caller that makes a handful of
# requests a second.
#
# NO TOKEN HERE, deliberately. The HTTP endpoints need one because a browser
# will POST to 127.0.0.1 from any origin that asks -- see `permitted?` in
# visualize.janet. A unix socket has no origin and no port to guess: reaching
# it means having filesystem access to the path, which is the boundary.

# -- the wire ----------------------------------------------------------------
# The protocol, both sides.

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
    [(session-start (map string (get message "argv" []))
            (string (get message "root" "."))
            (number-at "rows" 24)
            (number-at "cols" 100))
     false]

    (= op "stop") [(session-stop) false]

    # INPUT ANSWERS WITH THE ECHO, which is what makes typing feel immediate.
    #
    # Polling to discover the effect of your own keystroke is the wrong shape:
    # even with no delay at all it costs a second round trip, because the page
    # has to wait for the input request to come back before it can ask what
    # happened. Answering here collapses that into one.
    #
    # The wait is short and bounded. A terminal in its normal (cooked, echoing)
    # mode turns a keystroke around in well under a millisecond, so this
    # returns almost immediately; a program that echoes nothing -- a password
    # prompt, an agent mid-thought -- costs the timeout once and the ordinary
    # poll picks up whatever comes later. Nothing is lost either way: the
    # backlog is the record, and this reply is only an early look at it.
    (= op "input")
    (let [at (number-at "at" -1)
          before (length backlog)]
      (session-send (string (get message "text" "")))
      # Wait for the pump to produce something, checking often. `drain` is what
      # moves the pty's output into the backlog, and the timer in
      # `keep-draining` is doing it too -- this just gets there sooner.
      (var waited 0)
      (while (and (< waited 24) (= (length backlog) before))
        (++ waited)
        (ev/sleep 0.002)
        (drain))
      (if (neg? at)
        # An older page that does not send `at` gets the old answer.
        [{"ok" true} false]
        (let [[text next] (session-since at)
              now (session-state)]
          [{"ok" true
            "text" text
            "at" next
            "running" (now "running")
            "generation" (now "generation")}
           false])))

    (= op "redraw")
    (do (session-redraw) [{"ok" true} false])

    (= op "resize")
    (do (session-resize (number-at "rows" 24) (number-at "cols" 100))
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
          now (session-state)
          stale (and (>= asked 0) (not= asked (now "generation")))
          [text next] (session-since (if stale 0 (number-at "at" 0)))]
      [{"text" text
        "at" next
        "running" (now "running")
        "generation" (now "generation")
        "rows" (now "rows")
        "cols" (now "cols")
        "trimmed" (now "trimmed")}
       false])

    (= op "state") [(session-state) false]

    # The server says this on ctrl-c, and only then. Killing the agent here is
    # what preserves the behaviour of the single-process version: quitting
    # visualize takes the harness with it. A server that is merely restarting
    # -- because a file changed -- just closes the socket and says nothing.
    (= op "shutdown") [(do (session-stop) {"ok" true}) true]

    [{"error" (string "unknown op '" op "'")} false]))

(defn supervise
  ``Answer requests on `path` until a shutdown arrives.

  The socket file is removed on the way out so the next run binds cleanly:
  closing a unix socket leaves its file behind, and binding over one fails
  with "address already in use" rather than replacing it.``
  [path]
  # A crashed predecessor leaves its socket file behind, and binding over one
  # fails. The client only spawns this role after finding nothing alive on
  # the path, so anything still here is dead by definition.
  (when (os/stat path :mode) (try (os/rm path) ([_] nil)))
  (def server (net/server :unix path))
  (def done (ev/chan 1))
  # Before any connection is answered: the pump must never wait on a poll.
  (keep-draining)
  # AN UNREACHABLE SUPERVISOR MUST DIE ON ITS OWN. Clients find this process
  # through the socket file and nothing else, so a supervisor whose file is
  # gone can never again be spoken to -- including the `shutdown` that is its
  # only exit. That state is reachable: two spawns can race during a busy
  # start, the loser's bind unlinks or loses the file, and the orphan then
  # sits forever holding a pty nobody can see. Checked on a slow timer; the
  # file vanishing is not a transient.
  (ev/go
    (fn []
      (forever
        (ev/sleep 2)
        (unless (os/stat path :mode)
          (try (session-stop) ([_] nil))
          (os/exit 0)))))
  (defn answer [connection]
    # MANY REQUESTS PER CONNECTION, until the client hangs up. The client
    # keeps one connection pinned and asks everything over it -- opening a
    # fresh socket per poll churned the server's lowest fd numbers several
    # times a second, which is what tickled the EBADF race under a real
    # browser's concurrency. One line of JSON each way per request, and the
    # newline is the frame: a single :read returns whatever one chunk happens
    # to carry, so reads accumulate until the newline arrives, and anything
    # after it is kept for the next request.
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
                (def [reply finished] (handle parsed))
                (try (:write connection (string (json/encode reply) "\n"))
                  ([_] (set serving false)))
                (when finished
                  (ev/give done true)
                  (set serving false)))
              # Garbage on the wire: this client is confused, hang up on it.
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
  (try (session-stop) ([_] nil))          # the agent goes with us
  (try (:close server) ([_] nil))
  (try (os/rm path) ([_] nil))
  # EXIT EXPLICITLY. Returning from here is not enough: `keep-draining` and the
  # accept loop are `forever` fibers, and Janet keeps running while any task is
  # scheduled -- so the process outlived its own shutdown, printing "stopping
  # the harness" while the supervisor stayed up. The next run then found a live
  # socket, connected to the OLD supervisor, and the errors began.
  #
  # There is nothing left to unwind at this point: the socket is closed, its
  # file is gone, and the pty has been killed.
  (os/exit 0))

# -- the client --------------------------------------------------------------
# Everything below runs in the SERVER process.

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
    (os/execute ["/bin/sh" "-c" (string quoted " >/dev/null 2>&1 &")] :p))

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
  (defn ask [message &opt start?]
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

  # `start` is the only op that may bring a supervisor into being. Everything
  # else talks to one that is already there -- polling a terminal nobody
  # started should answer "not running", not silently spawn a process.
  {:start
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
   (fn [_ text &opt at]
     (def reply (ask (if at
                       {"op" "input" "text" text "at" at}
                       {"op" "input" "text" text})))
     (when (and reply (get reply "text"))
       {"text" (get reply "text")
        "at" (or (get reply "at") at)
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
   (fn [_ at &opt generation]
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
        "trimmed" (truthy? (get reply "trimmed"))
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
     # a dead-connection retry for nothing.
     (drop-pinned)
     nil)})

# -- the default client -------------------------------------------------------
# The agent harness's supervisor, which every module-level function below
# drives. One implicit handle rather than one threaded through every HTTP
# route, because the routes predate `make-client` and there is nothing for
# them to choose between: the server has exactly one agent terminal.

(var- default-client nil)

(defn configure
  ``Where the agent's supervisor is, and how to start one if it is not
  running. Replaces the default client whole, so a connection pinned to the
  OLD socket can never answer for the new one.``
  [path argv]
  (set default-client (make-client path argv)))

(defn start
  "Start `argv` on the supervisor's pty, replacing any session running."
  [argv root &opt rows cols]
  (:start default-client argv root rows cols))

(defn stop
  "Stop the harness, leaving the supervisor up for the next start."
  []
  (:stop default-client))

(defn send
  ``Type at the harness.

  With `at`, the reply carries the ECHO -- everything the program printed in
  response, in the same round trip; without it, nil. See :send in
  `make-client`.``
  [text &opt at]
  (:send default-client text at))

(defn resize
  "Tell the harness its window changed size."
  [rows cols]
  (:resize default-client rows cols))

(defn redraw
  ``Ask the program to repaint its screen -- what a reattaching page needs,
  since a byte-history replay cannot reconstruct a trimmed or resized frame.``
  []
  (:redraw default-client))

(defn state
  "What the page needs to know about the session, without its output."
  []
  (:state default-client))

(defn since
  "Everything the harness has printed since chunk `at`. Returns [text next]."
  [at]
  (:since default-client at))

(defn poll
  "The whole answer to one `/harness/poll`, in a single round trip."
  [at &opt generation]
  (:poll default-client at generation))

(defn shutdown
  "End the supervisor, killing the agent with it. Called on ctrl-c only."
  []
  (:shutdown default-client))
