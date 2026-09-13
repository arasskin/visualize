(import ./control)
(import ./launch)

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
    (os/exit (os/execute (launch/argv shell command))))
  (let [file (os/realpath op) id (os/getenv "VISUALIZE_PANE_ID")]
    (unless (and path id) (error "run vz file inside a Visualize pane"))
    (unless file (error "file does not exist"))
    (control/call path "document_open" {"id" id "file" file})))
