# The agent harness running in the terminal window.
#
# One session at a time: a pty, a thread pumping its output, and a buffer of
# what it has produced so far. The browser attaches to that buffer rather than
# to the pty, which is what makes a page reload cheap -- the harness keeps
# running and the reconnecting page is handed everything it missed.
#
# NOTHING HERE NAMES A PROGRAM. `start` takes argv, which the config supplies
# via `(harness claude)` or `(harness pi)`. Both were driven through this
# unchanged; see src/pty.janet.
#
# WHY A THREAD. The pump blocks on read(), and a blocking read on the main
# thread starves Janet's scheduler -- the server stops answering HTTP while
# the harness is busy, which was measured during development, not guessed.
# `ev/thread` gives it a real OS thread where blocking costs nothing. The
# thread talks back over a channel, which the main thread drains whenever a
# request arrives.

(import ./pty)

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

  Called on every request rather than on a timer: there is no other clock
  here, and a chunk sitting in the channel does no harm until somebody asks
  for it.

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

(defn running?
  "Is a harness alive right now?"
  []
  (drain)
  (and session (not exited) (pty/alive? session)))

(defn state
  "What the page needs to know about the session, without its output."
  []
  {:running (truthy? (running?))
   :generation generation
   :argv (if session (session :argv) [])
   :chunks (length backlog)})

(defn start
  ``Start `argv` on a pty, replacing any session already running.

  `rows` and `cols` come from the browser, which is the only thing that knows
  how big the panel is. Getting them wrong is not fatal -- the harness redraws
  on resize -- but starting at the right size avoids a visible reflow.``
  [argv root &opt rows cols]
  (default rows 24)
  (default cols 100)
  (when session (try (pty/close session) ([_] nil)))
  (set backlog @[])
  (set exited false)
  (++ generation)

  (def channel (ev/thread-chan 1024))
  (def ready (ev/thread-chan 2))
  # The pty is opened ON THE THREAD, not here, because the thread is where it
  # will be read: an ffi-signature cannot cross a thread boundary, so the
  # session must be created on the side that uses it. What comes back is a
  # plain struct, which marshals fine.
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
  # The child inherits the server's working directory, so the harness starts
  # wherever visualize was pointed -- which is the directory it is graphing.
  (state))

(defn stop
  "Stop the harness, if one is running."
  []
  (when session
    (try (pty/close session) ([_] nil))
    (set session nil)
    (set output nil)
    (set exited true))
  (state))

(defn send
  "Type at the harness."
  [text]
  (when (and session (not exited))
    (try (pty/write-input session text) ([_] nil)))
  nil)

(defn resize
  "Tell the harness its window changed size."
  [rows cols]
  (when session
    (try (pty/resize session rows cols) ([_] nil)))
  nil)

(defn since
  ``Everything the harness has printed since chunk `at`.

  Returns [text next]. The client sends back the `next` it was given, so a
  reload replays from the beginning and a live page only gets what is new.
  Chunks rather than bytes because the backlog is a list of reads, and a byte
  offset would have to be recomputed every time the cap dropped one.``
  [at]
  (drain)
  (def from (max 0 (min at (length backlog))))
  [(string/join (slice backlog from) "") (length backlog)])
