(import ../../src.server/launch)
(import ../../src.server/json)
(import ./harness :as t)

(t/test "launch options preserve scripts and allow overriding launcher defaults"
  (def script "values=('a b' 'c'); printf '%s\\n' \"${values[@]}\"")
  (def parsed (launch/parse ["--command" "default" "project with spaces" "--command" script "--no-dev"]))
  (t/is= "project with spaces" (parsed :project))
  (t/is= script (parsed :command))
  (t/is= "custom" ((launch/parse ["--default-harness" "default" "--default-harness" "custom"]) :default-harness))
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

(t/test "injected instructions and paths survive JSON quoting exactly"
  (def content "Keep \"quotes\", 'apostrophes', $(commands), `backticks`, \\slashes and 🚀.\nSecond line.\n")
  (os/setenv "VISUALIZE_AGENT_INSTRUCTIONS" content)
  (let [env (launch/environment "/tmp/a 'quoted' repo" "/tmp/project" "/tmp/a socket")]
    (t/is= content (json/decode (env "VISUALIZE_AGENT_JSON")))
    (t/is= "/tmp/a 'quoted' repo/visualize-mcp" (json/decode (env "VISUALIZE_MCP_COMMAND_JSON")))
    (t/is= "/tmp/a socket" (json/decode (env "VISUALIZE_SOCKET_JSON")))
    (t/is= nil (env "VISUALIZE_AGENT_FILE"))))

(t/test "worker executable is passed literally without harness-specific arguments"
  (t/is= ["/bin/sh" "-l" "-i" "-c" `exec "$1"` "visualize-worker" "/tmp/a worker $(literal)"]
         (launch/worker-argv "/bin/sh" "/tmp/a worker $(literal)")))
