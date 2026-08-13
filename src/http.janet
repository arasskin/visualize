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

  The body is read by Content-Length rather than to end-of-stream, because
  the connection stays open -- a browser reuses it, and reading until close
  would hang until the tab did.``
  [conn]
  (def buf @"")
  (var split nil)
  # Headers first, one chunk at a time until the blank line shows up.
  (while (not split)
    (def chunk (:read conn 4096))
    (if-not chunk (break))
    (buffer/push-string buf chunk)
    (set split (header-end buf)))
  (when split
    (def head (string/slice buf 0 split))
    (def lines (string/split "\n" head))
    (def request (string/split " " (string/trim (or (first lines) ""))))
    (when (>= (length request) 2)
      (def headers (parse-headers (string/join (drop 1 lines) "\n")))
      (def wanted (scan-number (or (headers "content-length") "0")))
      (def body (buffer/slice buf split))
      # Keep pulling until the whole body has arrived; one read is not a
      # promise of one message.
      (while (< (length body) wanted)
        (def chunk (:read conn 4096))
        (if-not chunk (break))
        (buffer/push-string body chunk))
      {:method (request 0)
       :path (request 1)
       # Kept because the terminal endpoints check it: a page on another
       # origin can POST here, and one that runs a shell must not accept it.
       :origin (headers "origin")
       :body (string body)})))

(defn respond
  "Write one response and its body."
  [conn status content-type body]
  (def payload (if (bytes? body) body (string body)))
  (:write conn (string "HTTP/1.1 " status "\r\n"
                       "Content-Type: " content-type "\r\n"
                       "Content-Length: " (length payload) "\r\n"
                       # No keep-alive bookkeeping: one request per
                       # connection, and the browser opens another when it
                       # wants one. Simpler than getting reuse subtly wrong.
                       "Connection: close\r\n"
                       "\r\n"
                       payload)))

(defn serve
  ``Bind the first free port at or above `port` and serve `handler`.

  WALKING UP RATHER THAN DYING. The obvious behaviour -- bind one port, exit
  on "address already in use" -- fails constantly in the loop this tool is
  used in: another copy is often already up in another window, and the error
  leaves you to go find out who has the port. Walking up to the first free one
  and PRINTING WHICH beats printing a complaint.

  `handler` is (request) -> [status content-type body].``
  [port tries handler]
  (var server nil)
  (var bound nil)
  (for candidate port (+ port tries)
    (unless server
      (when-let [attempt (try (net/server "127.0.0.1" (string candidate)) ([_] nil))]
        (set server attempt)
        (set bound candidate))))
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
             (try
               (when-let [request (read-request conn)]
                 (def [status content-type body] (handler request))
                 (respond conn status content-type body))
               ([err]
                 # A bug in a handler must not take the server down with it --
                 # the browser would see only "failed to fetch" and the next
                 # request would find nothing listening.
                 (eprintf "request failed: %s" (string err))
                 (try
                   (respond conn "500 Internal Server Error" "text/plain"
                            (string err))
                   ([_] nil)))))))))])
