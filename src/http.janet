# Just enough HTTP to serve one page to one browser on localhost.
#
# Not a web framework and not trying to be. This tool talks to exactly one
# client, on 127.0.0.1, over two endpoints -- so what it needs from HTTP is
# the request line, the headers it uses to find the body, and the body. Every
# other feature of the protocol is somebody else's problem.
#
# Bound to 127.0.0.1 rather than 0.0.0.0, deliberately: the server reads the
# filesystem and runs a config, and neither belongs on the network.


(defn- header-end
  "Where the headers stop and the body begins, or nil if they have not."
  [buf]
  (if-let [at (string/find "\r\n\r\n" buf)]
    (+ at 4)
    # Some clients send bare newlines. Cheap to accept, and the alternative is
    # a request that hangs forever for no visible reason.
    (if-let [at (string/find "\n\n" buf)] (+ at 2))))

(defn- parse-headers
  "Header lines as a table, lowercased so lookups do not have to guess case."
  [text]
  (def headers @{})
  (each line (string/split "\n" text)
    (def clean (string/trim line))
    (when-let [colon (string/find ":" clean)]
      (put headers
           (string/ascii-lower (string/trim (string/slice clean 0 colon)))
           (string/trim (string/slice clean (+ colon 1))))))
  headers)

(defn read-request
  ``Read one request off `conn`. Returns {:method :path :body} or nil.

  `carry` is the CONNECTION'S buffer, owned by the caller and living as long
  as the connection does: with keep-alive a read can deliver the tail of one
  request and the head of the next, and bytes left after this request's body
  stay in `carry` for the next call. Losing them would desynchronize the
  connection -- every later request parsed from its middle.

  The body is read by Content-Length rather than to end-of-stream, because
  the connection stays open. Reads carry a 75-second idle deadline: a
  keep-alive connection a browser abandoned without closing would otherwise
  hold its fiber forever.``
  [conn carry]
  (var split (header-end carry))
  # Headers first, one chunk at a time until the blank line shows up.
  (while (not split)
    (def chunk (:read conn 4096 nil 75))
    (if-not chunk (break))
    (buffer/push-string carry chunk)
    (set split (header-end carry)))
  (when split
    (def head (string/slice carry 0 split))
    (def lines (string/split "\n" head))
    (def request (string/split " " (string/trim (or (first lines) ""))))
    (when (>= (length request) 2)
      (def headers (parse-headers (string/join (drop 1 lines) "\n")))
      (def wanted (scan-number (or (headers "content-length") "0")))
      # Pull until this request's whole body is here; one read is not a
      # promise of one message.
      (while (< (- (length carry) split) wanted)
        (def chunk (:read conn 4096 nil 75))
        (if-not chunk (break))
        (buffer/push-string carry chunk))
      (def have (min wanted (- (length carry) split)))
      (def body (string/slice carry split (+ split have)))
      # Everything past this request's body belongs to the NEXT request.
      (def rest (string/slice carry (+ split have)))
      (buffer/clear carry)
      (buffer/push-string carry rest)
      {:method (request 0)
       :path (request 1)
       # Kept because the terminal endpoints check it: a page on another
       # origin can POST here, and one that runs a shell must not accept it.
       :origin (headers "origin")
       # Honoured by the serve loop: a client may still ask for the old
       # one-request behaviour.
       :close (= "close" (string/ascii-lower (or (headers "connection") "")))
       :body body})))

(defn respond
  ``Write one response and its body. `keep` announces the connection stays
  open for the next request.

  KEEP-ALIVE EXISTS BECAUSE CLOSE WAS THE STALL. One connection per request
  meant a hard scroll churned dozens of sockets a second through the
  browser's six-per-origin pool; one reply lost to the macOS fd race left
  its slot a zombie the browser reaps only on a ~10s timeout, a few zombies
  exhausted the pool, and every fetch -- keystrokes included -- queued
  behind them: the pane froze for exactly as long as the reaping took.
  Reused connections make the churn, and most of the race's exposure,
  simply not happen. Content-Length is always sent, which is what makes
  reuse safe without chunked encoding.``
  [conn status content-type body &opt keep]
  (def payload (if (bytes? body) body (string body)))
  (:write conn (string "HTTP/1.1 " status "\r\n"
                       "Content-Type: " content-type "\r\n"
                       "Content-Length: " (length payload) "\r\n"
                       # Without this the browser caches statics HEURISTICALLY
                       # -- no header at all means "guess" -- and an edited
                       # app.js can lose to a stale copy from a previous run
                       # on the same port. For a localhost tool whose files
                       # are being edited live, yesterday's code served fresh
                       # is the worst possible cache hit. no-store: the files
                       # are local and tiny, revalidation would need ETags for
                       # no win.
                       "Cache-Control: no-store\r\n"
                       (if keep
                         "Connection: keep-alive\r\n"
                         "Connection: close\r\n")
                       "\r\n"
                       payload)))

(defn- answered?
  ``Is something already serving this port?

  Asked by CONNECTING, because asking by binding gets a lie: the runtime sets
  SO_REUSEPORT on every server socket, so binding a taken port SUCCEEDS and
  the kernel then splits incoming connections between the old server and the
  new one. A connect tells the truth -- refused means free, accepted means
  taken.``
  [port]
  (if-let [probe (try (net/connect "127.0.0.1" (string port)) ([_] nil))]
    (do (try (:close probe) ([_] nil)) true)
    false))

(defn serve
  ``Serve `handler` on the first genuinely free port at or above `port`.

  WALKING UP RATHER THAN DYING. The obvious behaviour -- bind one port, exit
  on "address already in use" -- fails constantly in the loop this tool is
  used in: another copy is often already up in another window, and the error
  leaves you to go find out who has the port.

  PROBED, NOT JUST BOUND. The walk used to rely on bind failing for a taken
  port, and bind does not fail: SO_REUSEPORT (set by the runtime on every
  server socket) makes N binds of one port all succeed, with the kernel
  spraying connections across them. Three servers ended up sharing 8770 --
  the live one and two development sandboxes -- and the page's requests
  landed on whichever the kernel picked: wrong token, wrong supervisor,
  intermittent 403s, a terminal that froze whenever a sandbox was up. That
  is what "developing from inside visualize freezes visualize" turned out
  to be. There is a connect-then-bind race window, but the loser of that
  race is a second copy started in the same instant, not a corrupted one.

  `handler` is (request) -> [status content-type body].``
  [port tries handler]
  (var server nil)
  (var bound nil)
  (for candidate port (+ port tries)
    (unless server
      (unless (answered? candidate)
        (when-let [attempt (try (net/server "127.0.0.1" (string candidate)) ([_] nil))]
          (set server attempt)
          (set bound candidate)))))
  (unless server
    (errorf "no free port in %d-%d" port (+ port tries -1)))
  # Named `accept-loop` by the caller, never `loop`: that is a core macro, and
  # binding over it turns a later `(loop ...)` into a confusing arity error.
  [server bound
   (fn []
     (forever
       (def conn (:accept server))
       # Each connection on its own fiber, so a slow one cannot wedge the
       # accept loop.
       (ev/go
         (fn []
           (defer (:close conn)
             (def carry @"")
             (var serving true)
             (try
               # MANY REQUESTS PER CONNECTION, until the client hangs up or
               # asks to -- the same shape as the supervisor's socket loop,
               # and for the same reason: connection churn is where the fd
               # race lives, and the browser's six-slot pool is what the
               # churn was starving.
               (while serving
                 # CLEARED BEFORE EACH READ, so it names the request being
                 # served rather than the last one served. On a keep-alive
                 # connection it used to persist, and an idle timeout waiting
                 # for the NEXT request was logged against the PREVIOUS one
                 # -- "request failed (/style.css): timeout" for a connection
                 # that had finished style.css a minute earlier and was
                 # simply idle. Alarming, and pointing at the wrong place.
                 (setdyn :serving nil)
                 (def request (read-request conn carry))
                 (if-not request
                   (set serving false)
                   (do
                     (def [status content-type body] (handler request))
                     (setdyn :serving (request :path))
                     (respond conn status content-type body (not (request :close)))
                     (when (request :close) (set serving false)))))
               ([err fib]
                 # A bug in a handler must not take the server down with it --
                 # the browser would see only "failed to fetch" and the next
                 # request would find nothing listening.
                 (if (or (= (string err) "Bad file descriptor")
                         # AN IDLE KEEP-ALIVE CONNECTION IS NOT A FAULT. A
                         # browser opens several and abandons most of them
                         # without closing; the read deadline in
                         # `read-request` is what stops those holding fibers
                         # forever, and it firing is the deadline WORKING.
                         # Logged as a crash with a stack trace, it filled
                         # the terminal with alarming noise about nothing --
                         # and taught the reader to ignore the place real
                         # faults appear.
                         (and (= (string err) "timeout") (nil? (dyn :serving))))
                   # A known, survivable race, worth one quiet line and no
                   # more: under heavy browser concurrency the runtime very
                   # occasionally invalidates a connection's fd behind its
                   # stream (macOS, fd numbers reused within one event-loop
                   # turn), and the write to that one connection fails. The
                   # page retries the poll and carries on; the fd churn that
                   # provoked it is also gone, so this is rare. No 500 is
                   # attempted -- it would be a second write to the same dead
                   # descriptor.
                   (unless (= (string err) "timeout")
                     (eprintf "dropped one reply (%s): connection fd went stale"
                              (or (dyn :serving) "?")))
                   (do
                     # WITH THE STACK, not just the message. An error with no
                     # location here was diagnosed wrong twice -- a leaked
                     # supervisor, then a graphviz stampede, both real bugs
                     # and neither the one being chased -- because one line
                     # said nothing about which of a dozen fd-using calls had
                     # thrown. An error a person must chase carries its trace.
                     (def where (or (dyn :serving) "before-respond"))
                     (eprintf "request failed (%s): %s" where (string err))
                     (debug/stacktrace fib err "  ")
                     (try
                       (respond conn "500 Internal Server Error" "text/plain"
                                (string err))
                       ([_] nil)))))))))))])

# -- serving files out of web/ ------------------------------------------------

(defn static-file
  ``The name of the file in web/ this path asks for, or nil.

  A SINGLE PATH COMPONENT, and that is the security of it: a request may name
  a file in web/ and may not describe a route to anywhere else. `..` and `/`
  are refused rather than resolved, so there is no traversal to get right --
  `/../../etc/passwd` simply is not a name this returns.``
  [path]
  (def name (string/slice path 1))
  (when (and (not (empty? name))
             (not (string/find "/" name))
             (not (string/find "\\" name))
             (not (string/has-prefix? "." name))
             # A conservative allowlist of characters. Anything outside it is
             # not a filename this project has.
             (peg/match ~(* (some (+ (range "az") (range "AZ") (range "09")
                                     "." "-" "_")) -1)
                        name))
    name))

(def content-types
  {".html" "text/html; charset=utf-8"
   ".js" "text/javascript; charset=utf-8"
   ".mjs" "text/javascript; charset=utf-8"
   ".css" "text/css; charset=utf-8"
   ".svg" "image/svg+xml"
   ".json" "application/json"})

(defn content-type
  ``What to call this file.

  The JavaScript one matters more than the others: a browser refuses to
  execute a module served as text/plain, and the failure looks like the file
  is missing rather than mislabelled.``
  [name]
  (or (some (fn [suffix] (when (string/has-suffix? suffix name)
                           (content-types suffix)))
            (keys content-types))
      "text/plain; charset=utf-8"))

