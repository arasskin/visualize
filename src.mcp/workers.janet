(import ../src.server/launch)
(import ./schema)

(def- worker-role (string/trim (slurp (string (os/realpath (string (dyn :current-file) "/..")) "/worker.md"))))

(defn- integer [value low high]
  (and (number? value) (= value (math/floor value)) (<= low value high)))

(defn- text [value]
  (and (string? value) (pos? (length value)) (not (string/find "\x00" value))))

(defn- prompt-text [value]
  (unless (and (text value) (not (empty? (string/trim value))) (<= (length value) 65536)
               (not (some |(or (= $ 127) (and (< $ 32) (not (index-of $ [9 10 13])))) value)))
    (error "prompt must be nonempty text of at most 65536 bytes without terminal control characters"))
  (string/replace-all "\r" "\n" (string/replace-all "\r\n" "\n" value)))

(defn- public-state [reply]
  (def out @{})
  (each key ["running" "error" "cwd" "text" "revision" "bracketedPaste" "synchronized" "ok"]
    (when (has-key? reply key) (put out key (get reply key))))
  out)

(defn make [root clients create forget changed &opt environment labels set-title default-harness current-theme]
  (fn [operation args]
    (unless (dictionary? args) (error "arguments must be an object"))
    (def definition (find |(= operation (get $ "name")) schema/tools))
    (unless definition (error "unknown worker operation"))
    (def shape (definition "inputSchema"))
    (unless (and (every? (map |(has-key? args $) (shape "required")))
                 (every? (map |(has-key? (shape "properties") $) (keys args))))
      (error "missing or unexpected tool argument"))
    (defn known []
      (or (and (not= "harness" (get args "id")) (get clients (get args "id")))
          (error "unknown worker id")))
    (defn title [value]
      (unless (and (string? value) (<= (length value) 256)
                   (not (some |(< $ 32) value)))
        (error "title must be a single line of at most 256 bytes"))
      value)
    (defn compatible [&opt owned prompt-input]
      (def client (known))
      (def state (:request client {"op" "state"}))
      (when (and prompt-input (not (get state "promptInput")))
        (error "This worker uses an older supervisor. Close and recreate it before sending prompts."))
      (when owned
        (unless (and (get state "paneOwnership") (= "computer" (get state "owner")))
          (error "Unknown worker: this session was not created through the worker API")))
      (unless (= 1 (get state "controlVersion"))
        (error "This worker uses an older supervisor. Close and recreate it before using MCP controls."))
      client)
    (defn request [message]
      (:request (compatible (get message "owner") (get message "paste")) message))
    (case operation
      "list_agents"
      (do
        (def titles (if labels (labels) {}))
        (def workers @[])
        (each id (sorted (keys clients))
          (unless (= id "harness")
            (def state (try (:request (clients id) {"op" "state"}) ([_] nil)))
            (when (and state (get state "paneOwnership")
                       (= "computer" (get state "owner")) (get state "running"))
              (array/push workers (merge (public-state state) {"id" id "title" (get titles id "")})))))
        {"project" root "workers" workers})

      "spawn_agent"
      (do
        (def caption (title (get args "title")))
        (when (empty? (string/trim caption)) (error "worker title must not be empty"))
        (def prompt (string worker-role
          (when (has-key? args "message") (string " " (prompt-text (get args "message"))))))
        (unless default-harness (error "No worker harness configured; launch Visualize with --default-harness"))
        (def argv (launch/worker-argv (or (os/getenv "SHELL") "/bin/sh") default-harness))
        (def cwd (get args "cwd" root))
        (unless (text cwd) (error "cwd must be a path"))
        (def directory (os/realpath (if (string/has-prefix? "/" cwd) cwd (string root "/" cwd))))
        (unless (= :directory (os/stat directory :mode)) (error "cwd is not a directory"))
        (def id (string "agent-" (string/join (map |(string/format "%02x" $) (os/cryptorand 12)))))
        (def client (create id))
        (try
          (do
            (def result (:start-once client argv directory 24 100
              (merge (or environment {}) {"VISUALIZE_PANE_ID" id}) "computer" (when current-theme (current-theme))))
            (when set-title (set-title id caption))
            (changed id)
            (def delivery (when prompt
              (try
                (do
                  (def deadline (+ (os/clock :monotonic) 5))
                  (var revision -1)
                  (var quiet-at (os/clock :monotonic))
                  (forever
                    (def screen (:request client {"op" "capture"}))
                    (unless (screen "running") (error "worker exited before receiving the initial prompt"))
                    (def now (os/clock :monotonic))
                    (when (not= revision (screen "revision"))
                      (set revision (screen "revision")) (set quiet-at now))
                    (when (and (not (empty? (string/trim (screen "text")))) (>= (- now quiet-at) 0.25)) (break))
                    (when (>= now deadline) (error "worker startup is not settled; inspect the worker and send the prompt when ready"))
                    (ev/sleep 0.05))
                  (:request client {"op" "input" "owner" "computer"
                                    "text" prompt "paste" true "submit" true "quiet" true})
                  {"promptSent" true})
                ([e] {"promptSent" false "promptError" (string e)}))))
            (merge {"id" id "cwd" directory "title" caption} (public-state result) (or delivery {})))
          ([e]
            (try (:shutdown client) ([_] nil))
            (forget id)
            (error e))))

      "send_message"
      (do
        (def raw (get args "raw" false))
        (unless (boolean? raw) (error "raw must be a boolean"))
        (def value (get args "message"))
        (unless (and (string? value) (<= (length value) 65536))
          (error "text must be a string of at most 65536 bytes"))
        (request {"op" "input" "owner" "computer" "text" (if raw value (prompt-text value))
                  "paste" (not raw) "submit" (not raw) "quiet" true}))

      "close_agent"
      (let [result (request {"op" "shutdown" "owner" "computer"})]
        (forget (get args "id"))
        result)

      "read_agent"
      (do
        (def at (get args "revision"))
        (def timeout (get args "timeout_ms" (if (nil? at) 0 10000)))
        (when (has-key? args "revision")
          (unless (integer at 0 9007199254740991) (error "revision must come from read_agent")))
        (unless (integer timeout 0 25000) (error "timeout_ms must be between 0 and 25000"))
        (when (and (pos? timeout) (nil? at)) (error "waiting requires a revision"))
        (def client (compatible true))
        (def deadline (+ (os/clock :monotonic) (/ timeout 1000)))
        (var result nil)
        (forever
          (def capture (:request client {"op" "capture" "owner" "computer"}))
          (def reason (cond
            (not (capture "running")) "exit"
            (nil? at) "snapshot"
            (not= at (capture "revision")) "output"
            (>= (os/clock :monotonic) deadline) "timeout"))
          (when reason (set result (merge (public-state capture) {"reason" reason "id" (get args "id")})) (break))
          (ev/sleep 0.05))
        result)

      (error "unknown worker operation"))))
