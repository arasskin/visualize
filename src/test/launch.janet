(import ../../src.server/launch)
(import ../../src.server/json)
(import ./harness :as t)

(t/test "launch options preserve scripts and allow overriding launcher defaults"
  (def script "values=('a b' 'c'); printf '%s\\n' \"${values[@]}\"")
  (def parsed (launch/parse ["--command" "default" "project with spaces" "--command" script "--no-dev"]))
  (t/is= "project with spaces" (parsed :project))
  (t/is= script (parsed :command))
  (t/is= false (parsed :dev))
  (t/is= "--no-dev" ((launch/parse ["--command" "--no-dev"]) :command))
  (t/is= "-project" ((launch/parse ["--" "-project"]) :project))
  (t/is= true ((launch/parse ["--help"]) :help))
  (t/is= nil ((launch/parse []) :project)))

(t/test "invalid launch options fail before starting a server"
  (each args [["--default-harness"] ["--default-harness" " "] ["--unknown"] ["--command"] ["--command" "  "] ["one" "two"]]
    (t/ok (try (do (launch/parse args) false) ([_] true)))))

(t/test "the invocation remains one argument through login shell setup"
  (def script "printf '%s' 'a \"quote\" $(not-expanded) `not-expanded`'")
  (def argv (launch/argv "/bin/sh" script))
  (t/is= ["/bin/sh" "-l" "-i" "-c" `exec /bin/bash -c "$1"` "visualize-invocation" script] argv)
  (t/is= ["/bin/zsh" "-l" "-i"] (launch/argv "/bin/zsh" nil)))

(t/test "launch context carries the project, document connection, and literal startup prompt"
  (def prior (os/getenv "VISUALIZE_STARTUP_PROMPT"))
  (defer (os/setenv "VISUALIZE_STARTUP_PROMPT" prior)
    (def prompt "Keep \"quotes\", 'apostrophes', $(commands), `backticks`, \\slashes and 🚀.\nSecond line.")
    (os/setenv "VISUALIZE_STARTUP_PROMPT" prompt)
    (def env (launch/environment "/tmp/project" "/tmp/a socket"))
    (t/is= "/tmp/project" (env "VISUALIZE_PROJECT"))
    (t/is= "/tmp/a socket" (env "VISUALIZE_SOCKET"))
    (t/is= prompt (env "VISUALIZE_STARTUP_PROMPT"))
    (t/is= prompt (json/decode (env "VISUALIZE_STARTUP_PROMPT_JSON")))))
