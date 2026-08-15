# The pane host: owning a live pty, and answering for it over a socket.
#
# THIS FILE IS A WHOLE PROCESS -- one per terminal pane in the page, holding
# the pty that pane displays. `visualize --supervise` starts it and it
# outlives every server that talks to it, which is the point and the reason
# the session cannot simply live in the server.
#
# HOST, NOT PANE. The pane is the browser's: a <pre> in the page that dies
# with the tab. This process hosts the session behind one, and the two are
# deliberately different words -- see the note on /pane/ routes in app.js
# for what happens when one word covers three layers.
#
# The `--supervise` FLAG KEEPS ITS NAME though this file changed its own.
# The flag is a process contract, not an internal one: it appears in live
# command lines, in pgrep patterns (the test suite's leak check greps for
# it), and in whatever a person has in scrollback right now. Renaming it
# would break those for a word. A pty's master fd belongs to the process that
# called forkpty and cannot be passed to a later one, so "restart the server,
# keep the agent" is only possible if the server never holds the fd. Nothing
# here ever runs in the server; the client that speaks to it lives in
# ./client.janet, and speaks to it ONLY over the wire -- that file does not
# import this one. The single in-process caller is src/core.janet's
# `--supervise` branch, which calls `host` below: this process's entry point.
#
# THE WIRE IS THE CONTRACT, and it is written down twice on purpose -- the op
# names and reply shapes below have to agree with the client's, and the two
# ends drifting apart is exactly how the framing bugs this project already
# paid for (a reply truncated at one read, a request split across chunks) get
# back in. `handle` is the whole vocabulary in one function, and the protocol
# tests drive it directly without binding a socket. When you add an op, add it
# here and in the client's API together, and add a test that crosses both.
#
# The client API the HTTP routes actually call -- configure, start, stop,
# send, resize, redraw, state, since, poll, shutdown -- is in ./client.janet.
# The names here carry a `session-` prefix so the two vocabularies cannot
# collide when both files are open.

(import ./pty)
(import ../stamp)
(import ../watchdog)
(import ../json)

# -- owning a session --------------------------------------------------------
# The pty and everything that accumulates around it.

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

# (The DA1 reply above writes directly: it is a dozen bytes answering a
# startup probe, sent while the program is reading. If it ever meets a full
# buffer the write returns short and the loss is one probe answer, not a
# frozen event loop.)

(var- draining false)
(defn- drain
  ``Move whatever the pump thread has produced into the backlog.

  MUST NOT BLOCK, AND ONE AT A TIME. `ev/take` on an empty channel suspends
  until something arrives, so only as many items are taken as are actually
  there -- and the count must hold for THIS taker. The old form read the
  count once and took that many, which was correct from one fiber and a trap
  from several: two drains racing -- the timer against a parked poll's 10ms
  loop, hundreds of chances a second under a scroll flood -- both read N,
  both took N, and the loser's takes SUSPENDED on the emptied channel until
  the pump produced enough new chunks to pay the debt. That suspension froze
  whichever request had called drain for 4-10 seconds (however long the
  flood took to refill the channel), and the two drainers' interleaved
  pushes scrambled backlog order, which the page then faithfully painted as
  corruption. One bug, both of the last symptoms. The guard makes the race
  impossible; the count-per-take makes over-taking impossible even alone.``
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
# Input the pty has not yet accepted. A program that stops reading stdin
# while it paints fills the pty's ~1KB input buffer, and writing past that
# point blocks -- an FFI write blocks the supervisor's whole event loop, so
# every request froze for the ~10 seconds claude took to drain its stdin
# after a hard scroll. Writes are now gated on writability (see
# pty/writable?) and whatever the pty will not take yet waits here, flushed
# by every later send and by the drain timer's tick.
(var- unsent @"")

(defn- flush-unsent
  "Move queued input into the pty, exactly as much as it will take."
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
  ``Empty the pump's channel continuously, whether or not anyone is polling.

  20ms is far below the rate at which a person notices latency and far above
  the cost of an `ev/count` on an empty channel, which is what this does the
  overwhelming majority of the time.``
  []
  (ev/go
    (fn []
      (forever
        (ev/sleep 0.02)
        (try (drain) ([_] nil))
        # Input the pty refused earlier goes as soon as the program reads
        # again -- this tick is what turns a full-buffer stall into a queue.
        (try (flush-unsent) ([_] nil))))))

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
   # Input accepted from the page but not yet taken by the pty. A number
   # that grows and sticks is a program that has stopped reading stdin --
   # the observable that separates "our pipeline stalled" from "the
   # program did".
   "unsent" (length unsent)
   # The code THIS process was born running. The page compares it against
   # the server's with every poll and names a mismatch in its state line,
   # because two debugging rounds were once spent on fixes that sat on
   # disk while every process kept running its birth code.
   "stamp" stamp/born
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
  (buffer/clear unsent)
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
  "Type at the harness. QUEUED, never blocking: order is the queue's."
  [text]
  (when (and session (not exited))
    (buffer/push-string unsent text)
    (flush-unsent))
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
  # `from` rides along: a caller whose position was trimmed away receives a
  # stream that STARTS PAST what it asked for, and cannot know unless told --
  # the text alone looks like any other update while actually beginning
  # mid-escape-sequence. (Seen in the field as a literal "[7C" on screen and
  # frames smeared over stale rows: the torn stream's ESC went missing.)
  [(string/join (slice backlog (- from base)) "") total from])

# -- the protocol -------------------------------------------------------------
#
# One request per connection, a line of JSON each way. The same shape as the
# HTTP server (see src/http.janet): a connection carries one message
# and the client opens another when it wants one, which is simpler than
# getting framing and reuse subtly right for a caller that makes a handful of
# requests a second.
#
# NO TOKEN HERE, deliberately. The HTTP endpoints need one because a browser
# will POST to 127.0.0.1 from any origin that asks -- see `permitted?` in
# src/core.janet. A unix socket has no origin and no port to guess: reaching
# it means having filesystem access to the path, which is the boundary.

# -- the wire ----------------------------------------------------------------
# This side of the protocol. The other side is in ./client.janet.

# Every op's timing, kept always: count, worst, and the last few slow calls.
# The cost is a table update per request; the payoff, when something stalls,
# is that the first bug report arrives with its measurements attached --
# during the hang hunt this exact table had to be bolted on with TEMP
# eprintfs, twice. Parked waits are their own row ("since+wait"): a park
# holding twenty seconds is the feature working, and averaging it into
# "since" would bury the row that matters.
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
  ``Answer one decoded request. Returns [reply done?].

  `done?` is true only for `shutdown`, which is the single op that ends the
  process. Split out from the socket loop so the whole protocol is testable
  without binding anything.``
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
      #
      # UNLESS THE SENDER SAYS `quiet`. The wait exists for typing, where the
      # echo riding home on this reply is the difference between instant and
      # laggy. Mouse reports are the opposite case: the program often answers
      # them with NOTHING (a transcript already at its top), the full wait
      # then costs ~48ms per batch against a 16ms send cadence, and a long
      # scroll banked seconds of stale reports for every later keystroke to
      # queue behind. A quiet input returns at once; whatever repaint it
      # provokes reaches the page on the parked poll, which is faster than
      # this wait ever was.
      (var waited (if (truthy? (get message "quiet")) 24 0))
      (while (and (< waited 24) (= (length backlog) before))
        (++ waited)
        (ev/sleep 0.002)
        (drain))
      (if (neg? at)
        # An older page that does not send `at` gets the old answer.
        [{"ok" true} false]
        (let [[text next from] (session-since at)
              now (session-state)]
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
    #
    # WITH `wait`, THE REQUEST PARKS until there is something to say. This is
    # what turned the transport from polling into streaming: instead of the
    # page asking four times a second and output waiting up to 250ms for the
    # next ask, the ask is already here when the output arrives and leaves
    # ~10ms later. Parking is safe because every connection is answered in
    # its own fiber -- a held since blocks nobody -- and bounded because a
    # deadline is not optional on localhost either: the page's fetch has its
    # own timeout, and a park that outlived it would answer a closed socket.
    # The park ends early when the generation changes (a restart mid-park
    # must replay NOW, not at the deadline) or the session dies (the page
    # should hear "exited" promptly). The reply carries `waited` whenever
    # wait was asked for, honoured or not: the page uses it to tell a
    # supervisor that streams from an old one that ignores the key, and
    # falls back to its timer cadence rather than spinning.
    (let [asked (number-at "generation" -1)
          wait (min 25000 (number-at "wait" 0))]
      (when (pos? wait)
        (def entry (session-state))
        (def from (number-at "at" 0))
        (def deadline (+ (os/clock :monotonic) (/ wait 1000)))
        (var parked true)
        (while parked
          (drain)
          (def now (session-state))
          (def total (+ base (length backlog)))
          (cond
            # A generation mismatch replays from zero: answer now.
            (and (>= asked 0) (not= asked (now "generation"))) (set parked false)
            # Output beyond the caller's position: answer now.
            (> total (max base (min from total))) (set parked false)
            # The session's liveness flipped mid-park: answer now.
            (not= (now "running") (entry "running")) (set parked false)
            (>= (os/clock :monotonic) deadline) (set parked false)
            (ev/sleep 0.01))))
      (let [now (session-state)
            stale (and (>= asked 0) (not= asked (now "generation")))
            [text next from] (session-since (if stale 0 (number-at "at" 0)))]
        [{"text" text
          "at" next
          "from" from
          "running" (now "running")
          "generation" (now "generation")
          "rows" (now "rows")
          "cols" (now "cols")
          "trimmed" (now "trimmed")
          "stamp" (now "stamp")
          "waited" (pos? wait)}
         false]))

    (= op "state") [(session-state) false]

    # The server says this on ctrl-c, and only then. Killing the agent here is
    # what preserves the behaviour of the single-process version: quitting
    # visualize takes the harness with it. A server that is merely restarting
    # -- because a file changed -- just closes the socket and says nothing.
    (= op "shutdown") [(do (session-stop) {"ok" true}) true]

    # The timing table above, plus the queue depths that tell "our pipeline
    # stalled" from "the program stopped reading". (dev/stats) at the repl
    # prints this beside the server's own ask timings.
    (= op "stats")
    [{"ops" op-stats
      "unsent" (length unsent)
      "chunks" (+ base (length backlog))
      "stamp" stamp/born
      "uptime" (- (os/clock :monotonic) born-clock)}
     false]

    [{"error" (string "unknown op '" op "'")} false]))
  (note-op (if (and (= op "since") (pos? (number-at "wait" 0))) "since+wait" op)
           (- (os/clock :monotonic) started))
  out)

(defn host
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
  # And a witness that survives a stalled event loop -- the one observer
  # position every in-process instrument lacks. Its reports land on stderr,
  # which VISUALIZE_SUPERVISOR_LOG can keep.
  (watchdog/start "supervisor")
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
