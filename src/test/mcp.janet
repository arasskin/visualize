(import ../../src.mcp/protocol)
(import ../../src.mcp/workers)
(import ../../src.server/json)
(import ./harness :as t)

(t/test "MCP lifecycle and tool error boundaries"
  (def handle (protocol/make (fn [name args] (if (= name "list_agents") {"workers" []} (error "test tool failure")))))
  (defn ask [method &opt params]
    (handle (json/encode {"jsonrpc" "2.0" "id" 1 "method" method "params" (or params {})})))
  (t/is= -32000 (get-in (ask "tools/list") ["error" "code"]))
  (t/is= -32602 (get-in (ask "initialize") ["error" "code"]))
  (t/is= "2025-06-18" (get-in (ask "initialize" {"protocolVersion" "future" "capabilities" {} "clientInfo" {}}) ["result" "protocolVersion"]))
  (t/is= nil (handle `{"jsonrpc":"2.0","method":"notifications/initialized"}`))
  (t/is= 5 (length (get-in (ask "tools/list") ["result" "tools"])))
  (t/is= -32601 (get-in (ask "missing") ["error" "code"]))
  (t/is= -32602 (get-in (ask "tools/call" {"name" "list_agents" "arguments" {"unexpected" true}}) ["error" "code"]))
  (t/is= false (get-in (ask "tools/call" {"name" "list_agents"}) ["result" "isError"]))
  (t/is= true (get-in (ask "tools/call" {"name" "read_agent" "arguments" {"id" "missing"}}) ["result" "isError"]))
  (t/is= -32700 (get-in (handle `{"id":1} trailing`) ["error" "code"]))
  (t/is= -32600 (get-in (handle `[]`) ["error" "code"])))

(t/test "pane sends validate text and never replay input"
  (def calls @[])
  (def client {:request (fn [_ message]
    (if (= "state" (get message "op")) {"controlVersion" 1 "promptInput" true "paneOwnership" true "owner" "computer"}
      (do (array/push calls message) {"ok" true})))})
  (def dispatch (workers/make "/tmp" @{"one" client} (fn [&] (error "unexpected create")) (fn [&]) (fn [&])))
  (each args [{"id" "one"}
              {"id" "one" "message" 1}
              {"id" "one" "message" "hello\x1b"}]
    (t/ok (try (do (dispatch "send_message" args) false) ([_] true))))
  (t/is= 0 (length calls))
  (dispatch "send_message" {"id" "one" "message" "hello"})
  (t/is= 1 (length calls))
  (t/is= "hello" (get (first calls) "text"))
  (t/is= nil (get (first calls) "generation")))

(t/test "worker creation requires a configured harness and rejects command overrides"
  (var created 0)
  (var launched nil)
  (var sent nil)
  (def client {:request (fn [_ message]
    (if (= "capture" (get message "op")) {"text" "Ready" "running" true "revision" 1}
      (do (set sent (get message "text")) {"ok" true})))
    :start-once (fn [_ argv cwd rows cols environment owner &opt theme]
    (set launched {:argv argv :cwd cwd :environment environment :owner owner :theme theme})
    {"generation" 1})})
  (defn create [_] (++ created) client)
  (def missing (workers/make "/tmp" @{} create (fn [&]) (fn [&])))
  (t/ok (try (do (missing "spawn_agent" {"title" "Task" "message" "Investigate"}) false) ([_] true)))
  (t/is= 0 created)
  (def script "worker executable")
  (def dispatch (workers/make "/tmp" @{} create (fn [&]) (fn [&]) nil nil nil script (fn [] {"background" 0xffffff})))
  (each args [{"title" "Task" "message" "Investigate" "argv" ["/bin/sh"]}
              {"title" "Task" "message" "Investigate" "command" "bad"}
              {"title" "Task" "message" ""}
              {"title" " " "message" "Investigate"}]
    (t/ok (try (do (dispatch "spawn_agent" args) false) ([_] true))))
  (t/ok (try (do (dispatch "pane_open" {"argv" ["/bin/sh"]}) false) ([_] true)))
  (t/is= 0 created)
  (dispatch "spawn_agent" {"title" "Investigation"})
  (t/is= 1 created)
  (t/ok (string/has-prefix? "You are working in Visualize, a visual harness, as a subagent." sent))
  (def role sent)
  (dispatch "spawn_agent" {"title" "Investigation" "message" "Investigate this bug."})
  (t/is= (string role " Investigate this bug.") sent)
  (t/is= script (last (launched :argv)))
  (t/is= `exec "$1"` ((launched :argv) 4))
  (t/is= "computer" (launched :owner))
  (t/is= {"background" 0xffffff} (launched :theme)))

(t/test "send preserves raw keys and rejects ambiguous modes"
  (def calls @[])
  (def client {:request (fn [_ message]
    (if (= "state" (get message "op"))
      {"controlVersion" 1 "paneOwnership" true "owner" "computer" "promptInput" true}
      (do (array/push calls message) {"ok" true})))})
  (def dispatch (workers/make "/tmp" @{"one" client} (fn [&]) (fn [&]) (fn [&])))
  (def keys "\x1b[A\x03\r\x00")
  (dispatch "send_message" {"id" "one" "message" keys "raw" true})
  (t/is= keys (get (first calls) "text"))
  (t/is= false (get (first calls) "paste"))
  (t/is= false (get (first calls) "submit"))
  (t/is= "computer" (get (first calls) "owner"))
  (dispatch "send_message" {"id" "one" "message" "hello"})
  (t/is= true (get (last calls) "paste"))
  (t/is= true (get (last calls) "submit"))
  (t/ok (try (do (dispatch "send_message" {"id" "one" "message" "hello" "raw" "false"}) false) ([_] true)))
  (t/ok (try (do (dispatch "read_agent" {"id" "one" "revision" -1}) false) ([_] true)))
  (t/ok (try (do (dispatch "read_agent" {"id" "one" "timeout_ms" 100}) false) ([_] true))))

(t/test "coordinator is absent from the API even if its ID is known"
  (var touched 0)
  (def hidden {:request (fn [&] (++ touched) {"owner" "computer" "paneOwnership" true "controlVersion" 1})})
  (def dispatch (workers/make "/tmp" @{"harness" hidden} (fn [&]) (fn [&]) (fn [&])))
  (t/is= [] (get (dispatch "list_agents" {}) "workers"))
  (each [operation args] [["read_agent" {"id" "harness"}]
                         ["send_message" {"id" "harness" "message" "hello"}]
                         ["send_message" {"id" "harness" "message" "\x03" "raw" true}]
                         ["close_agent" {"id" "harness"}]]
    (t/ok (try (do (dispatch operation args) false) ([_] true))))
  (t/is= 0 touched))

(t/test "worker API lists only active owned sessions and hides supervisor details"
  (var captured nil)
  (defn client [owner running]
    {:request (fn [_ message]
      (if (= "state" (message "op"))
        {"owner" owner "running" running "paneOwnership" true "controlVersion" 1
         "generation" 8 "rows" 24 "argv" ["private"] "cwd" "/tmp"}
        (do (set captured message)
            {"running" running "text" "Final result" "revision" 3 "generation" 8 "rows" 24})))})
  (def dispatch (workers/make "/tmp"
    @{"active" (client "computer" true) "exited" (client "computer" false)
      "manual" (client "user" true) "harness" (client "computer" true)
      "unreachable" {:request (fn [&] (error "unreachable"))}}
    (fn [&]) (fn [&]) (fn [&]) nil (fn [] {"active" "Feature"})))
  (t/is= {"project" "/tmp" "workers" [{"id" "active" "title" "Feature" "cwd" "/tmp" "running" true}]}
    (dispatch "list_agents" {}))
  (each operation ["read_agent" "send_message" "close_agent"]
    (t/ok (try (do (dispatch operation (if (= operation "send_message")
      {"id" "manual" "message" "hello"} {"id" "manual"})) false) ([_] true))))
  (t/is= nil captured)
  (t/is= {"id" "exited" "running" false "text" "Final result" "revision" 3 "reason" "exit"}
    (dispatch "read_agent" {"id" "exited"}))
  (t/is= "computer" (get captured "owner"))
  (each name ["pane_list" "worker_open" "pane_read" "pane_send" "pane_close"]
    (t/ok (try (do (dispatch name {}) false) ([_] true)))))
