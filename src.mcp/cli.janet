(import ./local)
(import ../src.server/json)

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
    (os/exit (os/execute [shell "-l" "-i" "-c" command])))
  (if (index-of op ["list_agents" "spawn_agent" "read_agent" "send_message" "close_agent"])
    (print (json/encode (local/call path op (json/decode (get args (inc at) "{}")))))
    (let [file (os/realpath op) id (os/getenv "VISUALIZE_PANE_ID")]
      (unless (and path id) (error "run vz file inside a Visualize pane"))
      (unless file (error "file does not exist"))
      (local/call path "document_open" {"id" id "file" file}))))
