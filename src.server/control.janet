(import ./json)

(def limit 1048576)

(defn read-line [connection &opt timeout]
  (default timeout 35)
  (def pending @"")
  (var line nil)
  (forever
    (when (> (length pending) limit) (error "control message too large"))
    (when-let [at (string/find "\n" pending)]
      (set line (string/slice pending 0 at)) (break))
    (def chunk (:read connection 65536 nil timeout))
    (unless chunk (error "control connection closed before reply"))
    (buffer/push-string pending chunk))
  line)

(defn call [path operation arguments]
  (unless path (error "set VISUALIZE_SOCKET or pass --socket <path>"))
  (def connection (net/connect :unix path))
  (defer (:close connection)
    (:write connection (string (json/encode {"op" operation "args" arguments}) "\n") 5)
    (def reply (json/decode (read-line connection)))
    (when-let [message (get reply "error")] (error message))
    (get reply "result")))

(defn serve [path dispatch]
  (when (os/stat path :mode)
    (def connection (try (net/connect :unix path) ([_] nil)))
    (when connection (:close connection) (error "control socket already in use"))
    (os/rm path))
  (def mask (os/umask 8r077))
  (def server (defer (os/umask mask) (net/server :unix path)))
  (var closed false)
  (ev/go (fn []
    (while (not closed)
      (def connection (try (:accept server) ([_] nil)))
      (unless connection (break))
      (ev/go (fn []
        (defer (try (:close connection) ([_] nil))
          (try
            (do
              (def reply (try
                (do
                  (def message (json/decode (read-line connection 5)))
                  {"result" (dispatch (get message "op") (get message "args" {}))})
                ([e] {"error" (string e)})))
              (:write connection (string (json/encode reply) "\n") 5))
            ([_] nil))))))))
  (fn []
    (unless closed
      (set closed true)
      (:close server)
      (try (os/rm path) ([_] nil)))))
