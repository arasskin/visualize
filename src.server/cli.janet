(import ./json)

(def usage
  (string "usage: visualize [project] [--command <bash-script>] [--no-dev]\n"
          "\n--command runs a Bash script on cold startup after loading your login shell. New tabs open a plain login shell.\n"
          "The visualize launcher supplies the default invocation; later options override it.\n"
          "Use -- before a project path beginning with a dash.\n"
          "ctrl-c stops the server and terminals; ctrl-d restarts the server, preserving terminals."))

(defn parse [args]
  (def out @{:project nil :command nil :help false :dev true})
  (var positional false)
  (var at 0)
  (while (< at (length args))
    (def arg (get args at))
    (cond
      (and (not positional) (= arg "--")) (set positional true)
      (and (not positional) (= arg "--command"))
      (do
        (++ at)
        (def value (get args at))
        (unless (and (string? value) (not (empty? (string/trim value)))
                     (not (string/find "\x00" value)))
          (error (string arg " requires a nonempty value")))
        (put out (keyword (string/slice arg 2)) value))
      (and (not positional) (index-of arg ["--help" "-h"])) (put out :help true)
      (and (not positional) (= arg "--dev")) (put out :dev true)
      (and (not positional) (= arg "--no-dev")) (put out :dev false)
      (and (not positional) (string/has-prefix? "-" arg)) (error (string "unknown option " arg "\n" usage))
      (do
        (when (out :project) (error (string "only one project path is allowed\n" usage)))
        (put out :project arg)))
    (++ at))
  out)

(defn argv [shell script]
  (if script
    [shell "-l" "-i" "-c" `exec /bin/bash -c "$1"` "visualize-invocation" script]
    [shell "-l" "-i"]))

(defn environment [project socket]
  (def prompt (or (os/getenv "VISUALIZE_STARTUP_PROMPT") ""))
  {"VISUALIZE_PROJECT" project "VISUALIZE_SOCKET" socket
   "VISUALIZE_STARTUP_PROMPT" prompt "VISUALIZE_STARTUP_PROMPT_JSON" (json/encode prompt)})

(defn file-argv [shell command path]
  (unless (and (string? command) (<= (length command) 4096)
               (not (empty? (string/trim command))))
    (error "enter a terminal command (up to 4096 characters)"))
  (unless (and (string? path) (not (string/find "\0" path)))
    (error "invalid file path"))
  [shell "-l" "-i" "-c"
   (string (string/trim command) " '" (string/replace-all "'" "'\\''" path) "'")])

(def- message-limit 1048576)

(defn- read-line [connection &opt timeout]
  (default timeout 35)
  (def pending @"")
  (var line nil)
  (forever
    (when (> (length pending) message-limit) (error "control message too large"))
    (when-let [at (string/find "\n" pending)]
      (set line (string/slice pending 0 at)) (break))
    (def chunk (:read connection 65536 nil timeout))
    (unless chunk (error "control connection closed before reply"))
    (buffer/push-string pending chunk))
  line)

(defn- call [path operation arguments]
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

(defn main [& args]
  (var path (os/getenv "VISUALIZE_SOCKET"))
  (var at 1)
  (when (= (get args at) "--socket")
    (set path (get args (inc at)))
    (+= at 2))
  (def op (get args at))
  (unless op
    (def command (os/getenv "VISUALIZE_MAIN_HARNESS_COMMAND"))
    (unless command (error "vz must run inside Visualize or VISUALIZE_MAIN_HARNESS_COMMAND must be set"))
    (def shell (or (os/getenv "SHELL") "/bin/sh"))
    (os/exit (os/execute (argv shell command))))
  (let [file (os/realpath op) id (os/getenv "VISUALIZE_PANE_ID")]
    (unless (and path id) (error "run vz file inside a Visualize pane"))
    (unless file (error "file does not exist"))
    (call path "document_open" {"id" id "file" file})))
