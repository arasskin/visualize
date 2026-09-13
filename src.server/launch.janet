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
