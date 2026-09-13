#!/usr/bin/env janet

(import ./launch)

(def dev?
  (let [argv (or (dyn *args*) [])]
    (and (not= (get argv 1) "--supervise")
         (try ((launch/parse (drop 1 argv)) :dev) ([_] true)))))

(when dev? (put root-env *redef* true))

(import ../src.mcp/local :as control)
(import ../src.mcp/workers :as worker-api)
(import ./http)
(import ./trace)
(import ./json)

(import ./config)
(import ./command)
(import ./errors)
(import ./worker)
(import ./websocket)
(import ./term/stream :as stream)
(import ./scan)

(import ./term/client :as term)
(import ./term/host :as term-host)

(def- this-env (curenv))

(def default-port 8770)
(def port-tries 20)

(defn- query

  [path]
  (def out @{})
  (when-let [at (string/find "?" path)]
    (each pair (string/split "&" (string/slice path (+ at 1)))
      (when-let [eq (string/find "=" pair)]
        (put out (string/slice pair 0 eq) (string/slice pair (+ eq 1))))))
  out)

(defn- without-query [path]
  (if-let [at (string/find "?" path)] (string/slice path 0 at) path))

(defn- make-token

  []
  (string/join (map |(string/format "%02x" $) (os/cryptorand 24)) ""))

(defn- pane-route [path]
  (peg/match ~(* "/pane/" (<- (some (+ (range "az") (range "09") "-"))) "/"
                 (<- (some (range "az"))) -1)
             path))

(defn- socket-for

  [root &opt tag]
  (default tag ".sock")
  (def base (string/trimr (or (os/getenv "TMPDIR") "/tmp") "/"))

  (var digest 5381)
  (each byte (string/trimr root "/")
    (set digest (% (+ (* digest 33) byte) 0x7fffffff)))
  (string base "/visualize-" (string/format "%08x" digest) tag))

(defn main [& args]
  (def launch-args args)

  (when (= (get args 1) "--supervise")
    (def path (or (get args 2) (error "usage: visualize --supervise <socket-path>")))
    (term-host/tools-at (os/realpath (string (dyn :current-file) "/../..")))
    (term-host/host path)
    (os/exit 0))

  (def options (launch/parse (drop 1 args)))
  (when (options :help) (print launch/usage) (os/exit 0))
  (def root (os/realpath (or (options :project) (os/cwd))))
  (unless (= :directory (os/stat root :mode)) (error "project must be a directory"))

  (def project
    (let [parts (filter |(not (empty? $)) (string/split "/" root))]
      (if (empty? parts) "/" (last parts))))

  (def here (os/realpath (string (dyn :current-file) "/../..")))
  (def web-dir (string here "/src/web"))

  (def wterm-dir (string here "/src.wterm"))
  (def static-roots [web-dir wterm-dir (string here "/external-src/markdown-it")])
  (def config-path (string root "/" config/config-name))
  (def error-log (errors/logger (or (os/getenv "VISUALIZE_ERROR_LOG_DIR")
                                     (string here "/.logs"))))

  (def repo here)
  (def launch-environment @{})
  (eachp [key value] (launch/environment repo root "")
    (put launch-environment key value))


  (var source-generation 0)

  (def graph-worker (worker/start root (fn [value] (set source-generation value))))

  (def token (make-token))
  (var stopping false)

  (def page-born (os/time))


  (def panes @{})
  (def documents (merge @{} (config/markdown (:call graph-worker :read))))
  (var pane-generation 0)
  (var harness-request 0)
  (def ready-panes @{})
  (defn panes-changed [&opt id]
    (when id (put ready-panes id true))
    (++ pane-generation))
  (defn visible-panes []
    (filter |(or (not (string/has-prefix? "agent-" $)) (get ready-panes $)) (keys panes)))

  (def pane-sockets @{})

  (defn- remember-panes []

    (def pairs (seq [id :in (sorted (keys pane-sockets))]
                 [id (get pane-sockets id)]))
    (:call graph-worker :notes pairs))

  (defn pane-for [id]
    (or (get panes id)
        (let [socket (socket-for root (string "." id ".sock"))
              client (term/make-client
                       socket
                       [(string repo "/external-src/janet/janet")
                        (string repo "/src.server/core.janet")
                        "--supervise" socket])]
          (put panes id client)
          (put pane-sockets id socket)
          (panes-changed)

          (remember-panes)
          client)))

  (defn- forget-pane [id]
    (when (has-key? documents id)
      (put documents id nil)
      (:call graph-worker :markdown documents))
    (when-let [client (get panes id)] (:disconnect client))
    (put panes id nil)
    (put pane-sockets id nil)
    (put ready-panes id nil)
    (panes-changed)
    (remember-panes))

  (defn- answers? [socket]
    (and (os/stat socket :mode)
         (if-let [probe (try (net/connect :unix socket) ([_] nil))]
           (do (try (:close probe) ([_] nil)) true)
           false)))

  (each [id socket] (config/terminals (:call graph-worker :read))
    (if (answers? socket)
      (do

        (pane-for id)
        (put ready-panes id true))

      (try (os/rm socket) ([_] nil))))

  (remember-panes)

  (var terminal-theme {"foreground" 0x3a4851 "background" 0xffffff})
  (def start-empty? (empty? panes))
  (defn pane-labels [] (config/labels (:call graph-worker :read)))
  (defn set-pane-title [id text]
    (:call graph-worker :label [id text])
    (panes-changed))
  (def dispatch-control (worker-api/make root panes pane-for forget-pane panes-changed launch-environment
                                      pane-labels set-pane-title (options :default-harness) (fn [] terminal-theme)))
  (defn document-language [file]
    (def lower (string/ascii-lower file))
    (cond
      (string/has-suffix? "visualize.conf" lower) "config"
      (some |(string/has-suffix? $ lower) [".md" ".markdown" ".mdown"]) "markdown"
      (some |(string/has-suffix? $ lower) [".c" ".h" ".cc" ".hh" ".cpp" ".cxx" ".hpp"]) "c"
      (some |(string/has-suffix? $ lower) [".lisp" ".lsp" ".cl" ".clj" ".cljs" ".cljd" ".janet" ".scm" ".ss"]) "lisp"
      (some |(string/has-suffix? $ lower) [".py" ".pyw"]) "python"
      (some |(string/has-suffix? $ lower) [".js" ".mjs" ".cjs" ".jsx"]) "javascript"
      "text"))
  (defn control-call [operation arguments]
    (try (cond
      (= operation "open_harness")
      (do (++ harness-request) (panes-changed) {"ok" true})
      (= operation "document_open")
      (let [id (get arguments "id") file (os/realpath (get arguments "file" ""))]
        (unless (get panes id) (error "unknown pane id"))
        (unless (and file (= :file (os/stat file :mode))) (error "expected a readable document file"))
        (when (> (os/stat file :size) 4194304) (error "document exceeds 4 MiB"))
        (put documents id file)
        (:call graph-worker :markdown documents)
        (panes-changed)
        {"ok" true "file" file "language" (document-language file)})
      (dispatch-control operation arguments))
      ([e]
        (try (:write error-log {"phase" "mcp-control" "pane" (get arguments "id" "")
                               "operation" operation "message" (string e)}) ([_] nil))
        (error e))))

  (defn harness-argv []
    (launch/argv (or (os/getenv "SHELL") "/bin/sh") (options :command)))

  (defn escaped [text]
    (->> text
         (string/replace-all "&" "&amp;")
         (string/replace-all "<" "&lt;")
         (string/replace-all ">" "&gt;")
         (string/replace-all "\"" "&quot;")
         (string/replace-all "'" "&#39;")))

  (def favicon
    (let [safe (escaped (string/ascii-upper (string/slice project 0 1)))]
      (string
        "data:image/svg+xml,"

        (string/replace-all
          "\"" "%22"
          (string/replace-all
            "#" "%23"
            (string/replace-all
              "\n" ""
              (string
                "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 32 32\">"
                "<rect width=\"32\" height=\"32\" rx=\"7\" fill=\"#8b1a2b\"/>"
                "<text x=\"16\" y=\"22\" text-anchor=\"middle\""
                " font-family=\"Comic Sans MS, cursive\" font-size=\"20\""
                " fill=\"#fdfdfb\">" safe "</text>"
                "</svg>")))))))

  (var serving-port nil)

  (defn permitted?

    [request]
    (def given (or ((query (request :path)) "k")
                   ((query (or (request :body) "")) "k")))
    (def sent-token (= given token))
    (def origin (request :origin))
    (def same-origin
      (or (not origin)
          (= (string "http://127.0.0.1:" serving-port) origin)
          (= (string "http://localhost:" serving-port) origin)))
    (and sent-token same-origin))

  (defn draw [] (:call graph-worker :draw))

  (defn page [title lines problems svg fill]

    (def template (slurp (string web-dir "/index.html")))
    (var out (->> template
                  (string/replace "{{TITLE}}" (escaped title))
                  (string/replace "{{FAVICON}}" favicon)
                  (string/replace "{{CONFIG_NAME}}" config/config-title)
                  (string/replace "{{CONFIG_FILE}}" (json/encode config-path))
                  (string/replace "{{START_EMPTY}}" (json/encode start-empty?))

                  (string/replace "{{HARNESS_NAME}}"
                                  (escaped (last (string/split "/" (first (harness-argv))))))
                  (string/replace "{{CONFIG_LINES}}" (json/encode lines))
                  (string/replace "{{CONFIG_PROBLEMS}}" (json/encode problems))

                  (string/replace "{{PANE_POSITIONS}}" (json/encode (config/placements (:call graph-worker :read))))
                  (string/replace "{{PANE_LABELS}}"
                                  (json/encode
                                    (config/labels
                                      (:call graph-worker :read))))

                  (string/replace "{{CONFIG_DOCS}}" (json/encode (config/docs)))
                  (string/replace "{{CONFIG_COLOURS}}" (json/encode (config/colours)))

                  (string/replace "{{HARNESS_PRESENT}}" (json/encode (has-key? panes "harness")))
                  (string/replace "{{OPEN_TERMINALS}}"
                                  (json/encode (filter |(not= $ "harness") (visible-panes))))))
    (eachp [key value] fill
      (set out (string/replace (string "{{" key "}}") value out)))

    (string/replace "{{GRAPH}}" (fn [&] svg) out))

  (defn config-edit [body] (:call graph-worker :edit (json/decode body)))

  (defn handler [request]
    (when stopping (break ["503 Service Unavailable" "text/plain" "server stopping"]))
    (def path (without-query (request :path)))
    (def method (request :method))

    (defn guarded [reply]

      (if (permitted? request)
        (reply)
        ["403 Forbidden" "application/json"
         (json/encode {"error" "bad or missing token"})]))

    (defn poll-answer

      [ask body]
      (def sent (json/decode body))

      (def raw
        (ask (math/floor (or (get sent "at") 0))

             (when-let [g (get sent "generation")] (math/floor g))

             (when-let [w (get sent "wait")] (math/floor w))
             (get sent "limit") (get sent "encoding")))
      ["200 OK" "application/json" raw])

    (cond
      (and (= method "GET") (= path "/session"))
      ["200 OK" "application/json" (json/encode {"token" token})]

      (and (= method "GET") (= path "/terminal"))
      (if-not (permitted? request)
        ["403 Forbidden" "text/plain" "bad or missing token"]
        (if-not (websocket/upgrade? request)
          ["400 Bad Request" "text/plain" "invalid websocket upgrade"]
          {:upgrade (fn [connection carry]
            (websocket/serve connection carry request
              (fn [send]
                (stream/open send (fn [id] (or (get panes id) (error "terminal closed")))
                  (fn [id op body]
                    (def [status _ raw] (handler {:method "POST"
                      :path (string "/pane/" id "/" op "?k=" token)
                      :body (json/encode body)}))
                    (unless (= status "200 OK") (error "terminal operation failed"))
                    raw)))))}))

      (and (= method "GET") (= path "/diagnostics/graph"))
      (guarded (fn []
        ["200 OK" "application/json" (json/encode (:call graph-worker :diagnostics))]))

      (and (= method "POST") (= path "/errors"))
      (guarded (fn []
        (when (> (length (or (request :body) "")) 16384) (error "error report too large"))
        (:write error-log (json/decode (request :body)))
        ["200 OK" "application/json" "{\"ok\":true}"]))

      (and (= method "GET") (= path "/diagnostics"))
      (guarded (fn []
        ["200 OK" "application/json" (json/encode (trace/snapshot))]))

      (and (= method "GET") (= path "/"))
      (do
        (def [lines problems ok result drawn-generation] (draw))
        ["200 OK" "text/html; charset=utf-8"

         (page project
               lines problems
               (if ok result (string "<p>could not render: " result "</p>"))

               {"TOKEN" (json/encode token) "GRAPH_GENERATION" (string drawn-generation)})])

      (and (= method "POST") (= path "/panes/watch"))
      (guarded (fn []
        (def sent (json/decode (request :body)))
        (def seen (get sent "generation" -1))
        (def deadline (+ (os/clock :monotonic) 25))
        (while (and (= seen pane-generation) (< (os/clock :monotonic) deadline) (not stopping))
          (ev/sleep 0.1))
        ["200 OK" "application/json"
         (json/encode {"generation" pane-generation
                       "ids" (visible-panes) "labels" (pane-labels) "documents" documents
                       "harnessRequest" harness-request})]))

      (and (= method "POST") (= path "/document"))
      (guarded (fn []
        (def sent (json/decode (request :body)))
        (def file (or (get documents (get sent "id")) (error "unknown document pane")))
        (def stat (or (os/stat file) (error "document file is unavailable")))
        (when (> (stat :size) 4194304) (error "document exceeds 4 MiB"))
        (def revision (string (stat :modified) ":" (stat :changed) ":" (stat :size) ":" (stat :inode)))
        ["200 OK" "application/json" (json/encode
          {"file" file "language" (document-language file) "revision" revision
           "text" (unless (= revision (get sent "revision")) (string (slurp file)))})]))

      (and (= method "POST") (= path "/watch"))
      (guarded (fn []
                 (def sent (try (json/decode (request :body)) ([_] {})))
                 (def seen (math/floor (or (get sent "generation") 0)))
                 (def deadline (+ (os/clock :monotonic) 25))
                 (while (and (= seen source-generation)
                             (< (os/clock :monotonic) deadline))
                   (ev/sleep 0.1))
                 ["200 OK" "application/json"
                  (json/encode {"generation" source-generation
                                "changed" (not= seen source-generation)})]))

      (and (= method "GET") (= path "/graph.svg"))
      (guarded (fn []
                 (def [_ _ ok result] (draw))
                 (if ok
                   ["200 OK" "image/svg+xml" result]
                   ["500 Internal Server Error" "text/plain" result])))

      (and (= method "GET")
           (when-let [name (http/static-file path)]
             (find |(= :file (os/stat (string $ "/" name) :mode)) static-roots)))
      (let [name (http/static-file path)
            dir (find |(= :file (os/stat (string $ "/" name) :mode)) static-roots)]
        ["200 OK" (http/content-type name) (slurp (string dir "/" name))])

      (and (= (request :method) "POST") (= path "/config"))
      (guarded (fn []
        (def sent (json/decode (or (request :body) "{}")))
        (def file (get sent "file"))
        (when file
          (def full (os/realpath file))
          (unless (and full (= :file (os/stat full :mode))) (error "configuration file is unavailable"))
          (put sent "file" full))
        ["200 OK" "application/json" (config-edit (json/encode sent))]))

      (and (= method "POST") (= path "/panes/placements"))
      (guarded (fn []
        (when (> (length (or (request :body) "")) 65536) (error "pane placements too large"))
        (def sent (json/decode (or (request :body) "")))
        (unless (and (dictionary? sent) (<= (length sent) 256)) (error "invalid pane placements"))
        (each id (keys sent)
          (def pos (get sent id))
          (unless (and (stream/pane-id? id) (indexed? pos)
            (or (and (index-of (length pos) [2 4]) (index-of (pos 0) ["top" "bottom"])
                     (number? (pos 1)) (<= 0 (pos 1) 100000) (= (pos 1) (math/floor (pos 1)))
                     (or (= 2 (length pos))
                         (and (number? (pos 2)) (number? (pos 3))
                              (> (pos 2) 0) (> (pos 3) 0)
                              (<= (pos 2) 100000) (<= (pos 3) 100000))))
                (and (index-of (length pos) [3 5]) (= "floating" (pos 0))
                     (every? (map |(and (number? $) (<= -100000 $ 100000)) (slice pos 1)))
                     (or (= 3 (length pos))
                         (and (> (pos 3) 0) (> (pos 4) 0))))))
            (error "invalid pane placement")))
        (:call graph-worker :placements sent)
        ["200 OK" "application/json" (json/encode {:ok true})]))

      (and (= method "POST") (= path "/label"))
      (guarded (fn []
        (def sent (or (json/decode (or (request :body) "")) {}))
        (def id (string (or (get sent "id") "")))
        (def text (string (or (get sent "text") "")))
        (if (empty? id)
          ["400 Bad Request" "application/json" (json/encode {:ok false})]
          (do
            (set-pane-title id text)
            ["200 OK" "application/json" (json/encode {:ok true})]))))

      (and (= method "POST") (string/has-prefix? "/pane/" path)
           (pane-route path))
      (guarded
        (fn []
          (def [id op] (pane-route path))
          (def client (if (= op "start") (pane-for id) (get panes id)))
          (unless client
            (break ["200 OK" "application/json"
              (json/encode {"reachable" false "absent" true "running" false "generation" 0})]))
          (def sent (if (empty? (or (request :body) ""))
                      {} (or (json/decode (request :body)) {})))
          (defn rows [] (math/floor (or (get sent "rows") 24)))
          (defn cols [] (math/floor (or (get sent "cols") 100)))
          (case op
            "diagnostics"
            ["200 OK" "application/json" (json/encode (:remote-stats client))]

            "start"
            ["200 OK" "application/json"
             (json/encode (:start client
               (if (or (get sent "command") (get sent "node"))
                 (command/argv (or (os/getenv "SHELL") "/bin/sh")
                               (get sent "command")
                               (:call graph-worker :file sent))
                 (launch/argv (or (os/getenv "SHELL") "/bin/sh") nil))
               root (rows) (cols) (get sent "theme")
               (merge launch-environment {"VISUALIZE_PANE_ID" id})))]

            "stop"
            ["200 OK" "application/json" (json/encode (:stop client))]

            "shutdown"
            (do (:shutdown client)
                (forget-pane id)
                ["200 OK" "application/json" (json/encode {"ok" true})])

            "input"

            ["200 OK" "application/json"
             (:raw-send client (string (get sent "text" ""))
                        (when-let [a (get sent "at")] (math/floor a))
                        (truthy? (get sent "quiet"))
                        (get sent "generation"))]

            "redraw"
            (do (:redraw client)
                ["200 OK" "application/json" (json/encode {"ok" true})])

            "resize"
            (do (:resize client (rows) (cols) (get sent "cellWidth") (get sent "cellHeight"))
                ["200 OK" "application/json" (json/encode {"ok" true})])

            "screen"
            ["200 OK" "application/json"
             (:raw-screen client (get sent "at" 0) (get sent "generation" 0) 0)]

            "theme"
            (let [theme (get sent "theme" {})
                  response (:theme client theme)]
              (set terminal-theme theme)
              ["200 OK" "application/json" response])

            "capture"
            ["200 OK" "application/json" (json/encode (:capture client))]

            "poll"
            (poll-answer (fn [at gen wait limit encoding] (:raw-poll client at gen wait limit encoding))
                         (request :body))

            ["404 Not Found" "application/json"
             (json/encode {"error" (string "no such pane op '" op "'")})])))

      ["404 Not Found" "text/plain" "not found"]))

  (def [server bound accept-loop]
    (http/serve default-port port-tries handler))
  (set serving-port bound)
  (def control-path (socket-for root (string "." bound ".control.sock")))
  (def close-control (control/serve control-path control-call))
  (put launch-environment "VISUALIZE_SOCKET" control-path)
  (put launch-environment "VISUALIZE_SOCKET_JSON" (json/encode control-path))
  (put launch-environment "VISUALIZE_MAIN_HARNESS_COMMAND" (options :command))
  (os/setenv "VISUALIZE_SOCKET" control-path)
  (os/setenv "VISUALIZE_MAIN_HARNESS_COMMAND" (options :command))
  (when start-empty?
    (:start-once (pane-for "harness") (harness-argv) root 24 100
      (merge launch-environment {"VISUALIZE_PANE_ID" "harness"}) nil terminal-theme))
  (def url (string "http://127.0.0.1:" bound))

  (os/sigaction :int
    (fn []
      (set stopping true)
      (close-control)
      (print)
      (each client (values panes) (try (:shutdown client) ([_] nil)))
      (:stop graph-worker)
      (os/exit 0)))

  (def keyboard?
    (try
      (let [stat-proc (os/spawn ["ps" "-o" "stat=" "-p" (string (os/getpid))]
                                :px {:out :pipe})
            stat (string/trim (or (:read (stat-proc :out) :all) ""))]
        (os/proc-wait stat-proc)
        (and (truthy? (string/find "+" stat))
             (let [tty-proc (os/spawn ["stty" "-g"] :p {:out :pipe})]
               (:read (tty-proc :out) :all)
               (zero? (os/proc-wait tty-proc)))))
      ([_] false)))
  (when keyboard?
    (def eof-chan (ev/thread-chan 2))
    (ev/thread
      (fn [ch]
        (forever
          (def b (file/read stdin 1))
          (unless (and b (pos? (length b))) (break)))
        (ev/give ch true)
        :done)
      eof-chan
      :nt (ev/thread-chan 2))
    (ev/go
      (fn []
        (ev/take eof-chan)
        (set stopping true)
        (close-control)
        (print "restarting server; terminal sessions kept")
        (:stop graph-worker)
        (os/posix-exec ["/bin/sh" "-c"
          ``for restart_fd in /dev/fd/*; do
  restart_fd=${restart_fd##*/}
  case "$restart_fd" in
    0|1|2|*[!0-9]*) ;;
    *) eval "exec $restart_fd>&-" ;;
  esac
done
exec "$@"``
          "visualize-restart" (string here "/external-src/janet/janet") ;launch-args]))))

  (defn align-word
    [word to]
    (string ;(map (fn [_] " ") (range (- (length to) (length word)))) word))

  (print "visualize: " root " on " url)
  (print (align-word "config: " "visualize: ") config-path)
  (print (align-word "parsers: " "visualize: ") (string/join (scan/languages) ", "))
  (print "mcp: " repo "/visualize-mcp " control-path)
  (print "ctrl-c stops the server and terminal sessions.")
  (print "ctrl-d restarts the server, keeping terminal sessions.")

  (file/flush stdout)
  (trace/heartbeat)

  (def browser-launch (os/spawn ["open" url] :p))
  (ev/go (fn [] (os/proc-wait browser-launch)))
  (accept-loop))
