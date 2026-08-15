# The dependency graph: the first app built on visualize, and the one it
# needed for itself.
#
# THIS IS AN APP, NOT THE CORE, and the separation is the whole architecture.
# Visualize's core is an event loop, a repl, a harness holding an LLM, and
# facts on disk. What a program does with those -- what it draws, what it
# lets you edit, what it calls a node -- belongs to the program, and this
# file is the demonstration: a graph of a source tree, its config language,
# and the page that shows them. Delete it and the core still runs; write
# another one beside it and the core does not need to know.
#
# It reads the same scan.json every other consumer reads (see state.janet),
# which is what makes "an app that visualizes this project" a thing you can
# write without touching the server.

(import ./scan)
(import ./parsers)
(import ./dot)
(import ./config)
(import ./json)
(import ./state)

(def config-name "visualize.conf")

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

(defn read-config
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

(defn write-config
  "Write the lines back, as a real edit to the real file."
  [path lines]
  (spit path (string (string/join lines "\n") "\n")))

# Which actions are worth a redraw. Inserting adds an EMPTY line, which by
# definition draws the same graph -- so it saves and returns immediately
# instead of making you wait to see nothing change. Deleting is not here by
# oversight: removing a line really can change the picture.
(def draws {"run" true "delete" true "reorder" true "regenerate" true})

(defn edit
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
#
# AND IT IS WRITTEN DOWN. The scan is the most valuable fact this program
# holds -- every file, every dependency, every line count -- and it used to
# live in a var, visible only to code inside this process. On disk it is
# readable by a page, a script, an agent, or the next run, which is what
# lets a view of this project be something that reads a file rather than
# something that has to be built into the server. See src/state.janet.
(var- cached nil)

(defn- graph-for [root specs]
  (unless cached
    (set cached (scan/scan root specs))
    (try
      (state/write root "scan.json"
                   # The whole scan, not a chosen subset: a consumer this
                   # file has never heard of is the entire point.
                   {"at" (os/time)
                    "root" root
                    "nodes" (get cached :nodes [])
                    "edges" (get cached :edges [])
                    "sizes" (get cached :sizes {})
                    "ours" (get cached :ours {})
                    "error" (get cached :error)})
      ([_] nil)))
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


(defn page
  ``The HTML for a rendered graph. `fill` is what the CORE knows -- token,
  stamp, harness name, whether a repl exists -- supplied as a table, so this
  app does not reach into the server for it and the server does not know
  what a graph is.``
  [web-dir title lines problems svg fill]
  # `->>`, not `->`: string/replace takes the subject LAST, and threading it
  # first quietly produced a page that was the replacement value alone.
  (def template (slurp (string web-dir "/index.html")))
  (var out (->> template
                (string/replace "{{TITLE}}" title)
                (string/replace "{{CONFIG_NAME}}" config-name)
                (string/replace "{{CONFIG_LINES}}" (json/encode lines))
                (string/replace "{{CONFIG_PROBLEMS}}" (json/encode problems))))
  (eachp [key value] fill
    (set out (string/replace (string "{{" key "}}") value out)))
  # The SVG goes in last, and with a function rather than a literal:
  # string/replace treats `%` sequences in its replacement specially, and
  # graphviz output is full of them (`%3C` in URLs, percent widths). A
  # function replacement is taken verbatim.
  (string/replace "{{GRAPH}}" (fn [&] svg) out))

(defn draw
  ``Everything the page needs for one render: the config's lines, whatever
  was wrong with them, and the graph or the error that stopped it.``
  [root specs config-path]
  (def lines (read-config config-path))
  (def [state problems] (config/run lines))
  (def [ok result] (render-svg root specs state))
  [lines problems ok result])

(defn harness-argv
  ``What the config says to run in the terminal, or nil for the default.
  Read per request, so editing the config and pressing start does the new
  thing without a restart.``
  [config-path]
  (def [state _] (config/run (read-config config-path)))
  (state :harness))

(defn forget-scan
  "Drop the cached scan, so the next draw re-reads the source tree."
  []
  (set cached nil))

# Which actions are worth a redraw. Inserting adds an EMPTY line, which by
# definition draws the same graph -- so it saves and returns immediately
# instead of making you wait to see nothing change. Deleting is not here by
# oversight: removing a line really can change the picture.
(def- draws {"run" true "delete" true "reorder" true "regenerate" true})

(defn config-edit
  ``Apply one button press from the page and answer with the result: the
  new lines, what was wrong with them, and a fresh graph when the action
  could have changed one.

  THE WHOLE ROUTE, not a helper for it. The core hands over the request
  body and gets back a reply; nothing about buttons, configs or graphs
  needs to exist on the other side of that call.``
  [root specs config-path body]
  (def sent (json/decode body))
  (def action (string (get sent "action" "")))
  (def index (math/floor (or (get sent "index") -1)))
  (def lines (edit (map string (get sent "lines" [])) action index))
  # Save first: the file is the thing being edited, and it should hold what
  # you just did even if drawing it then fails.
  (write-config config-path lines)
  # Rescanning is Regenerate's job, never a side effect of an edit -- the
  # cache is dropped only when you ask for it.
  (when (= action "regenerate") (forget-scan))
  (def [state problems] (config/run lines))
  (def [ok result]
    (if (draws action) (render-svg root specs state) [true ""]))
  {"lines" lines
   "problems" problems
   # A render failure belongs to no single line -- graphviz being missing is
   # not any one form's fault -- so it stays separate from the per-line
   # messages.
   "error" (if ok "" result)
   "svg" (if ok result "")})

(defn load-specs
  ``The language specs, loaded from `dir`. Which languages exist is the
  graph's business: nothing in the core knows a file has a language.``
  [dir]
  (parsers/load dir))

(defn spec-names
  "Their names, for the startup banner."
  [specs]
  (map |($ :name) specs))
