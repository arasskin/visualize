(import ./json)

(def usage
  (string "usage: visualize [project] [--command <bash-script>] [--default-harness <executable>] [--no-dev]\n"
          "\n--command runs a Bash script on cold startup after loading your login shell. New tabs open a plain login shell.\n"
          "--default-harness selects the worker executable, launched without arguments.\n"
          "The visualize launcher supplies the default invocation; later options override it.\n"
          "Use -- before a project path beginning with a dash.\n"
          "ctrl-c stops the server and terminals; ctrl-d restarts the server, preserving terminals."))

(defn parse [args]
  (def out @{:project nil :command nil :default-harness nil :help false :dev true})
  (var positional false)
  (var at 0)
  (while (< at (length args))
    (def arg (get args at))
    (cond
      (and (not positional) (= arg "--")) (set positional true)
      (and (not positional) (index-of arg ["--command" "--default-harness"]))
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

(defn worker-argv [shell executable]
  [shell "-l" "-i" "-c" `exec "$1"` "visualize-worker" executable])

(defn environment [repo project socket]
  (def instructions (or (os/getenv "VISUALIZE_AGENT_INSTRUCTIONS") ""))
  (when (empty? (string/trim instructions)) (error "agent instructions are empty"))
  (when (string/find "\x00" instructions) (error "agent instructions contain a NUL byte"))
  {"VISUALIZE_PROJECT" project
   "VISUALIZE_AGENT_JSON" (json/encode instructions)
   "VISUALIZE_MCP_COMMAND" (string repo "/visualize-mcp")
   "VISUALIZE_MCP_COMMAND_JSON" (json/encode (string repo "/visualize-mcp"))
   "VISUALIZE_SOCKET" socket
   "VISUALIZE_SOCKET_JSON" (json/encode socket)})
