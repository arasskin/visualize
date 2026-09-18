#!/usr/bin/env janet

(import ./cli)

(def dev?
  (let [argv (or (dyn *args*) [])]
    (and (not= (get argv 1) "--supervise")
         (try ((cli/parse (drop 1 argv)) :dev) ([_] true)))))

(when dev? (put root-env *redef* true))

(import ./http)
(import ./trace)
(import ./json)

(import ./config)
(import ./errors)
(import ./graph)
(import ./config-graph)
(import ./websocket)
(import ./scan)

(import ./term/client :as term)
(import ./term/host :as term-host)

(def default-port 8770)
(def port-tries 20)

(def- terminal-operations ["input" "start" "stop" "shutdown" "resize" "redraw" "screen" "theme" "capture" "diagnostics"])

(defn- pane-id? [id]
  (and (string? id) (<= (length id) 64)
       (peg/match ~(* (some (+ (range "az") (range "09") "-")) -1) id)))

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

  (def options (cli/parse (drop 1 args)))
  (when (options :help) (print cli/usage) (os/exit 0))
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
  (eachp [key value] (cli/environment root "")
    (put launch-environment key value))


  (var source-generation 0)

  (config/initialize config-path)
  (def project-graph (graph/start root (fn [value] (set source-generation value))))

  (def token (make-token))
  (var stopping false)

  (def page-born (os/time))


  (def panes @{})
  (def documents (merge @{} (config/markdown (config/read-config config-path))))
  (var pane-generation 0)
  (defn panes-changed [] (++ pane-generation))
  (defn visible-panes [] (keys panes))

  (def pane-sockets @{})

  (defn- remember-panes []

    (def pairs (seq [id :in (sorted (keys pane-sockets))]
                 [id (get pane-sockets id)]))
    (config/write-config config-path (config/remember-terminals (config/read-config config-path) pairs)))

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
      (config/write-config config-path (config/remember-markdown (config/read-config config-path) documents)))
    (when-let [client (get panes id)] (:disconnect client))
    (put panes id nil)
    (put pane-sockets id nil)
    (panes-changed)
    (remember-panes))

  (defn- answers? [socket]
    (and (os/stat socket :mode)
         (if-let [probe (try (net/connect :unix socket) ([_] nil))]
           (do (try (:close probe) ([_] nil)) true)
           false)))

  (each [id socket] (config/terminals (config/read-config config-path))
    (if (answers? socket)
      (pane-for id)

      (try (os/rm socket) ([_] nil))))

  (remember-panes)

  (var terminal-theme {"foreground" 0x3a4851 "background" 0xffffff})
  (def start-empty? (empty? panes))
  (defn pane-labels [] (config/labels (config/read-config config-path)))
  (defn set-pane-title [id text]
    (def lines (config/read-config config-path))
    (def labels (config/labels lines))
    (put labels id text)
    (config/write-config config-path (config/remember-labels lines labels))
    (panes-changed))
  (defn document-language [file]
    (def lower (string/ascii-lower file))
    (cond
      (= (last (string/split "/" file)) config/config-name) "config"
      (some |(string/has-suffix? $ lower) [".md" ".markdown" ".mdown"]) "markdown"
      (some |(string/has-suffix? $ lower) [".c" ".h" ".cc" ".hh" ".cpp" ".cxx" ".hpp"]) "c"
      (some |(string/has-suffix? $ lower) [".lisp" ".lsp" ".cl" ".clj" ".cljs" ".cljd" ".janet" ".scm" ".ss"]) "lisp"
      (some |(string/has-suffix? $ lower) [".py" ".pyw"]) "python"
      (some |(string/has-suffix? $ lower) [".js" ".mjs" ".cjs" ".jsx"]) "javascript"
      "text"))
  (defn control-call [operation arguments]
    (try (cond
      (= operation "document_open")
      (let [id (get arguments "id") file (os/realpath (get arguments "file" ""))]
        (unless (get panes id) (error "unknown pane id"))
        (unless (and file (= :file (os/stat file :mode))) (error "expected a readable document file"))
        (when (> (os/stat file :size) 4194304) (error "document exceeds 4 MiB"))
        (put documents id file)
        (config/write-config config-path (config/remember-markdown (config/read-config config-path) documents))
        (panes-changed)
        {"ok" true "file" file "language" (document-language file)})
      (error "unknown document operation"))
      ([e]
        (try (:write error-log {"phase" "document-control" "pane" (get arguments "id" "")
                               "operation" operation "message" (string e)}) ([_] nil))
        (error e))))

  (defn harness-argv []
    (cli/argv (or (os/getenv "SHELL") "/bin/sh") (options :command)))

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

  (defn draw [] (:call project-graph :draw))

  (defn page [title lines problems svg fill]

    (def template (slurp (string web-dir "/index.html")))
    (var out (->> template
                  (string/replace "{{TITLE}}" (escaped title))
                  (string/replace "{{FAVICON}}" favicon)
                  (string/replace "{{CONFIG_FILE}}" (json/encode config-path))
                  (string/replace "{{START_EMPTY}}" (json/encode start-empty?))

                  (string/replace "{{CONFIG_LINES}}" (json/encode lines))
                  (string/replace "{{CONFIG_PROBLEMS}}" (json/encode problems))

                  (string/replace "{{PANE_POSITIONS}}" (json/encode (config/placements (config/read-config config-path))))
                  (string/replace "{{PANE_DOCUMENTS}}" (json/encode documents))
                  (string/replace "{{PANE_LABELS}}"
                                  (json/encode
                                    (config/labels
                                      (config/read-config config-path))))

                  (string/replace "{{CONFIG_DOCS}}" (json/encode (config/docs)))
                  (string/replace "{{CONFIG_COLOURS}}" (json/encode (config/colours)))

                  (string/replace "{{HARNESS_PRESENT}}" (json/encode (has-key? panes "harness")))
                  (string/replace "{{OPEN_TERMINALS}}"
                                  (json/encode (filter |(not= $ "harness") (visible-panes))))))
    (eachp [key value] fill
      (set out (string/replace (string "{{" key "}}") value out)))

    (string/replace "{{GRAPH}}" (fn [&] svg) out))

  (defn config-edit [sent]
    (def action (get sent "action"))
    (def target (or (get sent "file") config-path))
    (def target-root (string/join (slice (string/split "/" target) 0 -2) "/"))
    (def lines (config-graph/update-file target sent))
    (def [state problems] (config/run lines target-root))
    (def [visible moved] (config/shown lines problems))
    (def response @{"lines" visible "problems" moved "svg" "" "error" "" "generation" source-generation})
    (when (and (truthy? (get sent "draw")) (index-of action ["run" "regenerate"]))
      (def [_ _ ok svg generation] (:call project-graph :draw (= action "regenerate")))
      (put response "svg" (if ok svg ""))
      (put response "error" (if ok "" svg))
      (put response "generation" generation))
    (when (get sent "diagram")
      (def [model svg] (:call project-graph :diagram [target visible]))
      (put response "graph" model)
      (put response "diagram" svg))
    (json/encode response))

  (defn operate-terminal [id op sent]
    (when stopping (error "server stopping"))
    (def client (if (= op "start") (pane-for id) (get panes id)))
    (unless client
      (break (json/encode {"reachable" false "absent" true "running" false "generation" 0})))
    (def rows (math/floor (or (get sent "rows") 24)))
    (def cols (math/floor (or (get sent "cols") 100)))
    (case op
      "diagnostics" (json/encode (:remote-stats client))
      "start"
      (json/encode (:start client
        (if (or (get sent "command") (get sent "node"))
          (cli/file-argv (or (os/getenv "SHELL") "/bin/sh") (get sent "command")
                        (:call project-graph :file sent))
          (cli/argv (or (os/getenv "SHELL") "/bin/sh") nil))
        root rows cols (get sent "theme")
        (merge launch-environment {"VISUALIZE_PANE_ID" id})))
      "stop" (json/encode (:stop client))
      "shutdown"
      (do (:shutdown client) (forget-pane id) (json/encode {"ok" true}))
      "input" (:raw-send client (string (get sent "text" ""))
                           (get sent "generation"))
      "redraw" (do (:redraw client) (json/encode {"ok" true}))
      "resize"
      (do (:resize client rows cols (get sent "cellWidth") (get sent "cellHeight"))
          (json/encode {"ok" true}))
      "screen" (:raw-screen client (get sent "at" 0) (get sent "generation" 0) 0)
      "theme"
      (let [theme (get sent "theme" {}) response (:theme client theme)]
        (set terminal-theme theme)
        response)
      "capture" (json/encode (:capture client))
      (error "unknown terminal operation")))

  (defn terminal-stream [send]
    (var alive true)
    (def streams @{})
    (def actors @{})
    (defn reply [id raw]
      (when alive (send (string "{\"type\":\"reply\",\"id\":" (json/encode id) ",\"body\":" raw "}"))))
    (defn unsubscribe [id]
      (when-let [sub (streams id)]
        (put sub :alive false)
        (ev/chan-close (sub :credit))
        (put streams id nil)))
    (defn subscribe [id at generation subscription]
      (unsubscribe id)
      (def sub @{:alive true :credit (ev/chan 1) :subscription subscription})
      (put streams id sub)
      (ev/give (sub :credit) [at generation])
      (ev/go (fn []
        (try
          (let [client (or (get panes id) (error "terminal closed"))]
            (while (and alive (sub :alive))
              (if-let [[at generation] (ev/take (sub :credit))]
                (let [raw (:raw-screen client at generation 1000)]
                  (when (and alive (sub :alive))
                    (send (string "{\"type\":\"output\",\"subscription\":" (json/encode subscription) ",\"pane\":" (json/encode id)
                                  ",\"body\":" raw "}"))))
                (put sub :alive false))))
          ([e]
            (when (and alive (sub :alive))
              (try (send (json/encode {"type" "output" "pane" id "subscription" subscription
                                       "body" {"reachable" false "error" (string e)}})) ([_] nil))))))))
    (defn actor [pane]
      (or (actors pane)
        (do
          (when (>= (length actors) 64) (error "too many terminal panes"))
          (def state @{:queue (ev/chan 128) :bytes 0 :alive true})
          (put actors pane state)
          (ev/go (fn []
            (while (and alive (state :alive))
              (when-let [[id op body size] (ev/take (state :queue))]
                (-= (state :bytes) size)
                (def raw (try (operate-terminal pane op body)
                              ([e] (json/encode {"error" (string e)}))))
                (try (reply id raw) ([_] nil))
                (when (= op "shutdown")
                  (put state :alive false)
                  (put actors pane nil)
                  (unsubscribe pane)
                  (while (pos? (ev/count (state :queue)))
                    (def queued (ev/take (state :queue)))
                    (try (reply (queued 0) (json/encode {"error" "terminal closed"})) ([_] nil)))
                  (ev/chan-close (state :queue)))))))
          state)))
    {:message (fn [text]
      (def message (json/decode text))
      (def kind (get message "type"))
      (def pane (get message "pane"))
      (unless (pane-id? pane) (error "invalid terminal pane"))
      (case kind
        "subscribe"
        (do
          (when (>= (length streams) 64) (error "too many terminal subscriptions"))
          (subscribe pane (math/floor (or (get message "at") 0))
                          (math/floor (or (get message "generation") 0)) (get message "subscription")))
        "unsubscribe" (unsubscribe pane)
        "credit"
        (when-let [sub (streams pane)]
          (when (and (= (get message "subscription") (sub :subscription)) (zero? (ev/count (sub :credit))))
            (ev/give (sub :credit) [(math/floor (or (get message "at") 0))
                                    (math/floor (or (get message "generation") 0))])))
        "request"
        (let [id (get message "id")
              op (get message "op")
              body (or (get message "body") {})]
          (unless (and (number? id) (>= id 0)
                       (index-of op terminal-operations))
            (error "invalid terminal operation"))
          (def state (actor pane))
          (def size (length text))
          (if (or (>= (ev/count (state :queue)) 128) (> (+ size (state :bytes)) 262144))
            (reply id (json/encode {"error" "terminal input queue full"}))
            (do (+= (state :bytes) size)
                (ev/give (state :queue) [id op body size]))))
        (error "invalid terminal message")))
     :close (fn []
       (set alive false)
       (each id (keys streams) (unsubscribe id))
       (each state (values actors) (ev/chan-close (state :queue))))})

  (defn handler [request]
    (when stopping (break ["503 Service Unavailable" "text/plain" "server stopping"]))
    (def path (without-query (request :path)))
    (def method (request :method))

    (defn guarded [reply]

      (if (permitted? request)
        (reply)
        ["403 Forbidden" "application/json"
         (json/encode {"error" "bad or missing token"})]))

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
                (terminal-stream send))))}))

      (and (= method "GET") (= path "/diagnostics/graph"))
      (guarded (fn []
        ["200 OK" "application/json" (json/encode (:call project-graph :diagnostics))]))

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
                       "ids" (visible-panes) "labels" (pane-labels) "documents" documents})]))

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
        (try
          (do
            (def sent (json/decode (or (request :body) "{}")))
            (def file (get sent "file"))
            (when file
              (def full (os/realpath file))
              (unless (and full (= :file (os/stat full :mode))) (error "configuration file is unavailable"))
              (put sent "file" full))
            ["200 OK" "application/json" (config-edit sent)])
          ([err] ["400 Bad Request" "application/json" (json/encode {"error" (string err)})]))))

      (and (= method "POST") (= path "/panes/placements"))
      (guarded (fn []
        (when (> (length (or (request :body) "")) 65536) (error "pane placements too large"))
        (def sent (json/decode (or (request :body) "")))
        (unless (and (dictionary? sent) (<= (length sent) 256)) (error "invalid pane placements"))
        (each id (keys sent)
          (def pos (get sent id))
          (def pos (if (and (indexed? pos) (= (last pos) true)) (slice pos 0 -2) pos))
          (unless (and (pane-id? id) (indexed? pos)
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
        (config/write-config config-path (config/remember-placements (config/read-config config-path) sent))
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

      (and (= method "POST") (pane-route path))
      (guarded (fn []
        (def [id op] (pane-route path))
        (if (index-of op terminal-operations)
          ["200 OK" "application/json"
           (operate-terminal id op (or (json/decode (or (request :body) "{}")) {}))]
          ["404 Not Found" "application/json" (json/encode {"error" "unknown terminal operation"})])))

      ["404 Not Found" "text/plain" "not found"]))

  (def [server bound accept-loop]
    (http/serve default-port port-tries handler
      (fn [path]
        (case (without-query path)
          "/errors" 16384
          "/panes/placements" 65536
          http/max-body))))
  (set serving-port bound)
  (def control-path (socket-for root (string "." bound ".control.sock")))
  (def close-control (cli/serve control-path control-call))
  (put launch-environment "VISUALIZE_SOCKET" control-path)
  (put launch-environment "VISUALIZE_MAIN_HARNESS_COMMAND" (options :command))
  (os/setenv "VISUALIZE_SOCKET" control-path)
  (os/setenv "VISUALIZE_MAIN_HARNESS_COMMAND" (options :command))
  (when start-empty?
    (:start-once (pane-for "harness") (harness-argv) root 24 100
      (merge launch-environment {"VISUALIZE_PANE_ID" "harness"}) terminal-theme))
  (def url (string "http://127.0.0.1:" bound))

  (os/sigaction :int
    (fn []
      (set stopping true)
      (close-control)
      (print)
      (each client (values panes) (try (:shutdown client) ([_] nil)))
      (:stop project-graph)
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
        (:stop project-graph)
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

  (print "\n" (cli/banner project) "\n")
  (print "project: " root)
  (print "browser: " url)
  (print "config: " config-path)
  (print "parsers: " (string/join (scan/languages) ", "))
  (print)
  (print "ctrl-c stops the server and terminal sessions.")
  (print "ctrl-d restarts the server, keeping terminal sessions.")

  (file/flush stdout)
  (trace/heartbeat)

  (def browser-launch (os/spawn ["open" url] :p))
  (ev/go (fn [] (os/proc-wait browser-launch)))
  (accept-loop))
