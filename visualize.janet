#!/usr/bin/env janet
#
# visualize -- a dependency graph you draw by editing a file.
#
#     janet visualize.janet [directory]
#
# Opens a browser on the first free port at or above 8770. How the graph is
# drawn lives in `visualize.conf` in the directory being scanned -- a few
# s-expressions, edited through the page itself:
#
#     (hide ~.Tests)          drop it, and every edge touching it
#     ;;(hide ~.Tests)        comment it out to put it back
#     (hide ~.Clip.)          ...trailing dot: its contents, not itself
#     (group ~.Clip)          box its members, next palette colour
#     (group ~.Shared red)    ...or a colour you name
#     (fill-color)            fill nodes with their group colour
#     (show-only ~)           narrow to our own files -- the everyday setting
#     (show-lines)            write each file's line count on it
#     (show-lines-coloring)   ...and shade by size instead of by edges
#
# `~` IS THE PROJECT, the way a shell expands ~ to a home directory. Every
# other name is literal, so (group SwiftUI) and (hide WebKit) work on the
# imported frameworks exactly as they do on our own files.
#
# The config is real Janet, so it is not limited to the list above:
#
#     (each n ["Core" "UI" "Net"] (group (string "~." n)))
#
# The page runs that file on load, so the view you left is the view you return
# to. Every button press is a real edit to the real file.

(import ./src/scan)
(import ./src/dot)
(import ./src/config)
(import ./src/http)
(import ./src/parsers)
(import ./src/json)
(import ./src/harness)

# Where to start looking, not where it will land. `serve` walks upward to the
# first free port -- another copy of this tool is often already up in another
# window, and "address already in use" leaves you to go find out who has it.
(def default-port 8770)
(def port-tries 20)

(def config-name "visualize.conf")

# What the terminal window runs when the config does not say. Claude Code
# because it is the harness this was built against; `(harness pi)` in the
# config picks another, and nothing below this line knows the difference.
(def default-harness ["claude"])

# Written on first run so there is something to edit rather than a blank pane.
# Comments survive a round-trip through the editor, so they are worth having.
(def starter
  ``;; (group prefix & color), (hide prefix), (show-only prefix)
;; (fill-color), (show-lines), (show-lines-coloring)
;; `~` is this project: ~.Sub is the Sub directory. Any other name is literal,
;; so (group SwiftUI) groups the framework. Comment out with ';'.
;; colors: red green orange purple blue yellow orange-red teal magenta
;;         yellow-green pink dark-blue grey
(show-only ~)
(show-lines)
``)

# The starter above ends without a newline, because a long-string literal ends
# where it ends. Written as-is, the last line has nothing after it and the
# next edit through the page appends to it -- so the file is normalised on the
# way to disk exactly as `write-config` does it.

(defn- read-config
  "The config file as a list of lines, creating it if it is not there."
  [path]
  (unless (os/stat path :mode)
    (spit path (string (string/trimr starter "\n") "\n")))
  (def text (try (slurp path) ([_] "")))
  # A trailing newline is one empty string on the end, which would show as a
  # phantom blank row in the editor.
  (def lines (string/split "\n" text))
  (if (and (> (length lines) 0) (= "" (last lines)))
    (slice lines 0 -2)
    lines))

(defn- write-config
  "Write the lines back, as a real edit to the real file."
  [path lines]
  (spit path (string (string/join lines "\n") "\n")))

# Which actions are worth a redraw. Inserting adds an EMPTY line, which by
# definition draws the same graph -- so it saves and returns immediately
# instead of making you wait to see nothing change. Deleting is not here by
# oversight: removing a line really can change the picture.
(def draws {"run" true "delete" true "reorder" true "regenerate" true})

(defn- edit
  ``Apply one button press to the file's lines.

  The browser sends the lines it is showing along with the action, so an
  in-place typo and the button that acts on it arrive together -- there is no
  separate save step to forget.

  'run', 'reorder' and 'regenerate' change no text: every action re-runs the
  file anyway, so running IS just saving what is on screen.``
  [lines action index]
  (def out (array ;lines))
  (cond
    (or (= action "run") (= action "reorder") (= action "regenerate")) out
    (= action "insert-above") (array/insert out (max 0 index) "")
    (= action "insert-below") (array/insert out (min (length out) (+ index 1)) "")
    (= action "delete") (if (and (>= index 0) (< index (length out)))
                          (array/remove out index)
                          out)
    (errorf "unknown action '%s'" action)))

# The scan's output for a given source tree never varies -- same files, same
# graph, every time. It is fast, but it is still pointless to redo per edit
# when only the post-processing changes. Regenerate is how you say the SOURCE
# changed and this is stale.
(var- cached nil)

(defn- graph-for [root specs]
  (unless cached (set cached (scan/scan root specs)))
  cached)

(defn- render-svg
  ``Draw the graph the config asks for. Returns [ok svg-or-error].

  The scan is the whole graph; the narrowing, hiding, grouping and colouring
  are all applied to it on the way to graphviz.``
  [root specs state]
  (def graph (graph-for root specs))
  (if (graph :error)
    [false (graph :error)]
    (do
      # Narrow before hiding: (show-only ~) then (hide ~.Tests) reads the way
      # it is written, and hiding something already filtered out is a no-op
      # rather than an error.
      (def trimmed (dot/drop-nodes (dot/keep graph (state :only)) (state :hidden)))
      # Only the nodes still on the graph get a say in the ramp: ranking
      # against hidden files would spend the range on colours nothing wears.
      (def weights
        (when (state :sized-coloring)
          (def here @{})
          (each node (trimmed :nodes)
            (when-let [size (get (graph :sizes) (node :name))]
              (put here (node :name) size)))
          (dot/ramp-of here)))
      (dot/to-svg (dot/render trimmed {:groups (state :groups)
                                       :sized (state :sized)
                                       :filled (state :filled)
                                       :font (state :font)
                                       :weights weights})
                  root))))

(defn- page
  "The HTML for a rendered graph, with the config and the token baked in."
  [web-dir title lines problems token harness-argv svg]
  # `->>`, not `->`: string/replace takes the subject LAST, and threading it
  # first quietly produced a page that was the replacement value alone.
  (def template (slurp (string web-dir "/index.html")))
  (->> template
       (string/replace "{{TITLE}}" title)
       (string/replace "{{CONFIG_NAME}}" config-name)
       (string/replace "{{CONFIG_LINES}}" (json/encode lines))
       (string/replace "{{CONFIG_PROBLEMS}}" (json/encode problems))
       # The token the terminal endpoints require. In the page rather than a
       # cookie so it dies with the tab and never travels to another origin.
       (string/replace "{{TOKEN}}" (json/encode token))
       (string/replace "{{HARNESS_NAME}}" (string/join harness-argv " "))
       # The SVG goes in last, and with a function rather than a literal:
       # string/replace treats `%` sequences in its replacement specially, and
       # graphviz output is full of them (`%3C` in URLs, percent widths). A
       # function replacement is taken verbatim.
       (string/replace "{{GRAPH}}" (fn [&] svg))))

(defn- query
  ``The query string of a path, as a table. Enough for `?k=secret`.``
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
  ``A secret for this run, so only this page can drive the terminal.

  WHY THIS EXISTS. Everything else visualize serves is derived from files and
  the worst a stray request can do is redraw a graph. The harness endpoints
  run a program, and 127.0.0.1 IS NOT A BOUNDARY: any page in any tab can POST
  to a localhost port. Without a secret, a website you happen to be visiting
  could type into your agent.

  From `os/cryptorand` because a predictable token is not a token.``
  []
  (string/join (map |(string/format "%02x" $) (os/cryptorand 24)) ""))

(defn main [& args]
  (def root (os/realpath (or (get args 1) (os/cwd))))
  (def here (os/realpath (string (dyn :current-file) "/..")))
  (def web-dir (string here "/web"))
  (def config-path (string root "/" config-name))
  (def specs (parsers/load (string here "/parsers")))
  (def token (make-token))

  (defn permitted?
    ``May this request drive the terminal?

    Two checks, because they fail differently. The TOKEN proves the request
    came from the page this run served -- another tab guessing the port does
    not have it. The ORIGIN check stops a cross-site POST from a page that
    somehow learned the token, and rejects anything not from this server.

    A missing Origin is allowed: `curl` sends none, and the token alone is
    what protects a request that no browser made.``
    [request]
    (def given (or ((query (request :path)) "k")
                   ((query (or (request :body) "")) "k")))
    (def sent-token (= given token))
    (def origin (request :origin))
    (def same-origin
      (or (not origin)
          (string/has-prefix? "http://127.0.0.1:" origin)
          (string/has-prefix? "http://localhost:" origin)))
    (and sent-token same-origin))

  (defn draw []
    (def lines (read-config config-path))
    (def [state problems] (config/run lines))
    (def [ok result] (render-svg root specs state))
    [lines problems ok result])

  (defn handler [request]
    (def path (without-query (request :path)))
    (def method (request :method))

    # Which harness the config asked for, re-read per request so editing the
    # config and pressing start does the new thing without a restart.
    (defn harness-argv []
      (def [state _] (config/run (read-config config-path)))
      (or (state :harness) default-harness))

    (defn guarded [reply]
      # One shape for every terminal endpoint: prove you are the page this run
      # served, or get nothing. See `permitted?`.
      (if (permitted? request)
        (reply)
        ["403 Forbidden" "application/json"
         (json/encode {"error" "bad or missing token"})]))

    (cond
      (and (= method "GET") (= path "/"))
      (do
        (def [lines problems ok result] (draw))
        ["200 OK" "text/html; charset=utf-8"
         (page web-dir (string (last (string/split "/" root)) " — visualize")
               lines problems token (harness-argv)
               (if ok result (string "<p>could not render: " result "</p>")))])

      # -- the harness ------------------------------------------------------
      # Polled rather than streamed over SSE. A terminal is a request/response
      # shape anyway -- the page has to send keystrokes regardless -- and one
      # endpoint that returns "everything since chunk N" is both the catch-up
      # path for a reload and the live path for a running session. SSE would
      # need a second mechanism for input and a way to resume a dropped
      # stream, which is this endpoint again with more parts.
      (and (= method "POST") (= path "/harness/start"))
      (guarded (fn []
                 (def sent (json/decode (request :body)))
                 (def rows (math/floor (or (get sent "rows") 24)))
                 (def cols (math/floor (or (get sent "cols") 100)))
                 ["200 OK" "application/json"
                  (json/encode (harness/start (harness-argv) root rows cols))]))

      (and (= method "POST") (= path "/harness/stop"))
      (guarded (fn [] ["200 OK" "application/json" (json/encode (harness/stop))]))

      (and (= method "POST") (= path "/harness/input"))
      (guarded (fn []
                 (def sent (json/decode (request :body)))
                 (harness/send (string (get sent "text" "")))
                 ["200 OK" "application/json" (json/encode {"ok" true})]))

      (and (= method "POST") (= path "/harness/resize"))
      (guarded (fn []
                 (def sent (json/decode (request :body)))
                 (harness/resize (math/floor (or (get sent "rows") 24))
                                 (math/floor (or (get sent "cols") 100)))
                 ["200 OK" "application/json" (json/encode {"ok" true})]))

      (and (= method "POST") (= path "/harness/poll"))
      (guarded (fn []
                 (def sent (json/decode (request :body)))
                 (def [text next] (harness/since (math/floor (or (get sent "at") 0))))
                 (def now (harness/state))
                 ["200 OK" "application/json"
                  (json/encode {"text" text
                                "at" next
                                "running" (now :running)
                                "generation" (now :generation)})]))

      (and (= (request :method) "GET") (= path "/style.css"))
      ["200 OK" "text/css; charset=utf-8" (slurp (string web-dir "/style.css"))]

      (and (= (request :method) "GET") (= path "/app.js"))
      ["200 OK" "text/javascript; charset=utf-8" (slurp (string web-dir "/app.js"))]

      (and (= (request :method) "POST") (= path "/config"))
      (do
        (def sent (json/decode (request :body)))
        (def action (string (get sent "action" "")))
        (def index (math/floor (or (get sent "index") -1)))
        (def lines (edit (map string (get sent "lines" [])) action index))
        # Save first: the file is the thing being edited, and it should hold
        # what you just did even if drawing it then fails.
        (write-config config-path lines)
        # Rescanning is Regenerate's job, never a side effect of an edit --
        # the cache is dropped only when you ask for it.
        (when (= action "regenerate") (set cached nil))
        (def [state problems] (config/run lines))
        (def [ok result]
          (if (draws action)
            (render-svg root specs state)
            [true ""]))
        ["200 OK" "application/json"
         (json/encode
           {"lines" lines
            "problems" problems
            # A render failure belongs to no single line -- graphviz being
            # missing is not any one form's fault -- so it stays separate from
            # the per-line messages.
            "error" (if ok "" result)
            "svg" (if ok result "")})])

      ["404 Not Found" "text/plain" "not found"]))

  (def [server bound accept-loop] (http/serve default-port port-tries handler))
  (def url (string "http://127.0.0.1:" bound))
  (printf "visualize: %s on %s" root url)
  (printf "  config: %s" config-path)
  (printf "  parsers: %s" (string/join (map |($ :name) specs) ", "))
  (print "  ctrl-c to stop")
  # Off the server, not off the constant: they differ whenever the first
  # choice was taken, and printing the wrong one sends you to somebody else's
  # page.
  (os/spawn ["open" url] :pd)
  (accept-loop))
