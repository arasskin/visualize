(import ../../src.server/cli)
(import ../../src.server/json)
(import ./harness :as t)

(t/test "launch options preserve scripts and allow overriding launcher defaults"
  (def script "values=('a b' 'c'); printf '%s\\n' \"${values[@]}\"")
  (def parsed (cli/parse ["--command" "default" "project with spaces" "--command" script "--no-dev"]))
  (t/is= "project with spaces" (parsed :project))
  (t/is= script (parsed :command))
  (t/is= false (parsed :dev))
  (t/is= "--no-dev" ((cli/parse ["--command" "--no-dev"]) :command))
  (t/is= "-project" ((cli/parse ["--" "-project"]) :project))
  (t/is= true ((cli/parse ["--help"]) :help))
  (t/is= nil ((cli/parse []) :project)))

(t/test "invalid launch options fail before starting a server"
  (each args [["--default-harness"] ["--default-harness" " "] ["--unknown"] ["--command"] ["--command" "  "] ["one" "two"]]
    (t/ok (try (do (cli/parse args) false) ([_] true)))))

(t/test "the invocation remains one argument through login shell setup"
  (def script "printf '%s' 'a \"quote\" $(not-expanded) `not-expanded`'")
  (def argv (cli/argv "/bin/sh" script))
  (t/is= ["/bin/sh" "-l" "-i" "-c" `exec /bin/bash -c "$1"` "visualize-invocation" script] argv)
  (t/is= ["/bin/zsh" "-l" "-i"] (cli/argv "/bin/zsh" nil)))

(t/test "launch context carries the project, document connection, and literal startup prompt"
  (def prior (os/getenv "VISUALIZE_STARTUP_PROMPT"))
  (defer (os/setenv "VISUALIZE_STARTUP_PROMPT" prior)
    (def prompt "Keep \"quotes\", 'apostrophes', $(commands), `backticks`, \\slashes and 🚀.\nSecond line.")
    (os/setenv "VISUALIZE_STARTUP_PROMPT" prompt)
    (def env (cli/environment "/tmp/project" "/tmp/a socket"))
    (t/is= "/tmp/project" (env "VISUALIZE_PROJECT"))
    (t/is= "/tmp/a socket" (env "VISUALIZE_SOCKET"))
    (t/is= prompt (env "VISUALIZE_STARTUP_PROMPT"))
    (t/is= prompt (json/decode (env "VISUALIZE_STARTUP_PROMPT_JSON")))))

(t/test "file command quotes the path independently from the user's command"
  (def path "/tmp/a 'quoted' $(touch never) `false` ü.txt")
  (def args (cli/file-argv "/bin/sh" "printf '%s'" path))
  (t/is= ["/bin/sh" "-l" "-i" "-c"] (slice args 0 4))
  (def child (os/spawn ["/bin/sh" "-c" (args 4)] :p {:out :pipe}))
  (t/is= path (string (:read (child :out) :all)))
  (:close (child :out))
  (t/is= 0 (os/proc-wait child)))

(t/test "file command rejects an empty command"
  (t/ok (try (do (cli/file-argv "/bin/sh" "  " "/tmp/file") false) ([_] true))))
