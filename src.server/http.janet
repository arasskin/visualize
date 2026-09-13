(import ./trace)

(defn- header-end

  [buf]
  (if-let [at (string/find "\r\n\r\n" buf)]
    (+ at 4)

    (if-let [at (string/find "\n\n" buf)] (+ at 2))))

(defn- parse-headers

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

  [conn carry]
  (var split (header-end carry))

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

      (while (< (- (length carry) split) wanted)
        (def chunk (:read conn 4096 nil 75))
        (if-not chunk (break))
        (buffer/push-string carry chunk))
      (def have (min wanted (- (length carry) split)))
      (def body (string/slice carry split (+ split have)))

      (def rest (string/slice carry (+ split have)))
      (buffer/clear carry)
      (buffer/push-string carry rest)
      {:method (request 0)
       :path (request 1)
       :headers headers

       :origin (headers "origin")

       :close (= "close" (string/ascii-lower (or (headers "connection") "")))
       :body body})))

(defn respond

  [conn status content-type body &opt keep timing]
  (def payload (if (bytes? body) body (string body)))
  (:write conn (string "HTTP/1.1 " status "\r\n"
                       "Content-Type: " content-type "\r\n"
                       "Content-Length: " (length payload) "\r\n"

                       "Cache-Control: no-store\r\n"
                       (or timing "")
                       (if keep
                         "Connection: keep-alive\r\n"
                         "Connection: close\r\n")
                       "\r\n"
                       payload)))

(defn- answered?

  [port]
  (if-let [probe (try (net/connect "127.0.0.1" (string port)) ([_] nil))]
    (do (try (:close probe) ([_] nil)) true)
    false))

(defn serve

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

  [server bound
   (fn []
     (forever
       (def conn (:accept server))

       (ev/go
         (fn []
           (defer (:close conn)
             (def carry @"")
             (var serving true)
             (try

               (while serving

                 (setdyn :serving nil)
                 (def request (read-request conn carry))
                 (if-not request
                   (set serving false)
                   (do
                     (when trace/enabled (setdyn :latency @{}))
                     (def response (trace/measure "handler" (handler request)))
                     (if (and (dictionary? response) (response :upgrade))
                       (do
                         (set serving false)
                         ((response :upgrade) conn carry))
                       (do
                     (def [status content-type body] response)
                     (def timing
                       (when trace/enabled
                         (string "Server-Timing: "
                           (string/join
                             (map (fn [key] (string key ";dur=" ((dyn :latency) key)))
                                  (keys (dyn :latency))) ", ") "\r\n")))
                     (setdyn :serving (request :path))
                     (trace/measure "http-write"
                       (respond conn status content-type body (not (request :close)) timing))
                     (when (request :close) (set serving false)))))))
               ([err fib

                 (if (or (= (string err) "Bad file descriptor")

                         (and (= (string err) "timeout") (nil? (dyn :serving))))

                   (unless (= (string err) "timeout")
                     (eprintf "dropped one reply (%s): connection fd went stale"
                              (or (dyn :serving) "?")))
                   (do

                     (def where (or (dyn :serving) "before-respond"))
                     (eprintf "request failed (%s): %s" where (string err))
                     (debug/stacktrace fib err "  ")
                     (try
                       (respond conn "500 Internal Server Error" "text/plain"
                                (string err))
                       ([_] nil))))])))))))])

(defn static-file

  [path]
  (def name (string/slice path 1))
  (when (and (not (empty? name))
             (not (string/find "/" name))
             (not (string/find "\\" name))
             (not (string/has-prefix? "." name))

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
   ".json" "application/json"

   ".ttf" "font/ttf"

   ".wasm" "application/wasm"})

(defn content-type

  [name]
  (or (some (fn [suffix] (when (string/has-suffix? suffix name)
                           (content-types suffix)))
            (keys content-types))
      "text/plain; charset=utf-8"))
