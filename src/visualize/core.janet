#!/usr/bin/env janet

(def dev?
  (let [argv (or (dyn *args*) [])]
    (not (or (index-of "--no-dev" argv)
             (index-of "--supervise" argv)))))

(when dev? (put root-env *redef* true))

(import ./http)
(import ./trace)
(import ./json)
(import ./browser)

(import ./config)
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

  (when (= (get args 1) "--supervise")
    (def path (or (get args 2) (error "usage: visualize --supervise <socket-path>")))
    (term-host/host path)
    (os/exit 0))

  (def args (filter |(not (index-of $ ["--dev" "--no-dev"])) args))
  (def root (os/realpath (or (get args 1) (os/cwd))))

  (def project
    (let [parts (filter |(not (empty? $)) (string/split "/" root))]
      (if (empty? parts) "/" (last parts))))

  (def here (os/realpath (string (dyn :current-file) "/../..")))
  (def web-dir (string here "/web"))

  (def vendor-dir (string here "/../external-src/wterm"))
  (def static-roots [web-dir vendor-dir])
  (def config-path (string root "/" config/config-name))

  (var source-generation 0)

  (def graph-worker (worker/start root (fn [value] (set source-generation value))))

  (def token (make-token))

  (def page-born (os/time))

  (def repo (os/realpath (string here "/..")))

  (def panes @{})

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
                        (string repo "/src/visualize/core.janet")
                        "--supervise" socket])]
          (put panes id client)
          (put pane-sockets id socket)

          (remember-panes)
          client)))

  (defn- forget-pane [id]
    (put panes id nil)
    (put pane-sockets id nil)
    (remember-panes))

  (defn- answers? [socket]
    (and (os/stat socket :mode)
         (if-let [probe (try (net/connect :unix socket) ([_] nil))]
           (do (try (:close probe) ([_] nil)) true)
           false)))

  (def recovered @[])
  (each [id socket] (config/terminals (:call graph-worker :read))
    (if (answers? socket)
      (do

        (pane-for id)
        (array/push recovered id))

      (try (os/rm socket) ([_] nil))))

  (remember-panes)

  (def pane-client (pane-for "harness"))

  (defn harness-argv []
    (def named (os/getenv "VISUALIZE_HARNESS"))
    (if (and named (not (empty? named)))
      (string/split " " named)

      [(or (os/getenv "SHELL") "/bin/sh") "-l" "-i"]))

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

                  (string/replace "{{HARNESS_NAME}}"
                                  (escaped (last (string/split "/" (first (harness-argv))))))
                  (string/replace "{{CONFIG_LINES}}" (json/encode lines))
                  (string/replace "{{CONFIG_PROBLEMS}}" (json/encode problems))

                  (string/replace "{{PANE_LABELS}}"
                                  (json/encode
                                    (config/labels
                                      (:call graph-worker :read))))

                  (string/replace "{{CONFIG_DOCS}}" (json/encode (config/docs)))
                  (string/replace "{{CONFIG_COLOURS}}" (json/encode (config/colours)))

                  (string/replace "{{OPEN_TERMINALS}}"
                                  (json/encode (filter |(not= $ "harness") recovered)))))
    (eachp [key value] fill
      (set out (string/replace (string "{{" key "}}") value out)))

    (string/replace "{{GRAPH}}" (fn [&] svg) out))

  (defn config-edit [body] (:call graph-worker :edit (json/decode body)))

  (defn handler [request]
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
                (stream/open send pane-for
                  (fn [id op body]
                    (def [status _ raw] (handler {:method "POST"
                      :path (string "/pane/" id "/" op "?k=" token)
                      :body (json/encode body)}))
                    (unless (= status "200 OK") (error "terminal operation failed"))
                    raw)))))}))

      (and (= method "GET") (= path "/diagnostics/graph"))
      (guarded (fn []
        ["200 OK" "application/json" (json/encode (:call graph-worker :diagnostics))]))

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
        ["200 OK" "application/json"
         (config-edit (request :body))]))

      (and (= method "POST") (= path "/label"))
      (guarded (fn []
        (def sent (or (json/decode (or (request :body) "")) {}))
        (def id (string (or (get sent "id") "")))
        (def text (string (or (get sent "text") "")))
        (if (empty? id)
          ["400 Bad Request" "application/json" (json/encode {:ok false})]
          (do
            (:call graph-worker :label [id text])
            ["200 OK" "application/json" (json/encode {:ok true})]))))

      (and (= method "POST") (string/has-prefix? "/pane/" path)
           (pane-route path))
      (guarded
        (fn []
          (def [id op] (pane-route path))
          (def client (pane-for id))
          (def sent (if (empty? (or (request :body) ""))
                      {} (or (json/decode (request :body)) {})))
          (defn rows [] (math/floor (or (get sent "rows") 24)))
          (defn cols [] (math/floor (or (get sent "cols") 100)))
          (case op
            "diagnostics"
            ["200 OK" "application/json" (json/encode (:remote-stats client))]

            "start"
            ["200 OK" "application/json"
             (json/encode (:start client (harness-argv) root (rows) (cols)))]

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
            (do (:resize client (rows) (cols))
                ["200 OK" "application/json" (json/encode {"ok" true})])

            "poll"
            (poll-answer (fn [at gen wait limit encoding] (:raw-poll client at gen wait limit encoding))
                         (request :body))

            ["404 Not Found" "application/json"
             (json/encode {"error" (string "no such pane op '" op "'")})])))

      ["404 Not Found" "text/plain" "not found"]))

  (def [server bound accept-loop]
    (http/serve default-port port-tries handler))
  (set serving-port bound)
  (def url (string "http://127.0.0.1:" bound))

  (os/sigaction :int
    (fn []
      (print)
      (each client (values panes) (try (:shutdown client) ([_] nil)))
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
        (print "server stopped; terminals kept -- run visualize again to reattach")
        (os/exit 0))))

  (defn align-word
    [word to]
    (string ;(map (fn [_] " ") (range (- (length to) (length word)))) word))

  (print "visualize: " root " on " url)
  (print (align-word "config: " "visualize: ") config-path)
  (print (align-word "parsers: " "visualize: ") (string/join (scan/languages) ", "))
  (print "ctrl-c kills everything.")
  (print "ctrl-d kills only the server.")

  (trace/heartbeat)

  (os/spawn (browser/command url) :pd)
  (accept-loop))
