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
(import ./select)
(import ./layout)
(import ./config)
(import ./json)

# THE ONE SPELLING of the file this program writes into the directory it is
# pointed at. src/visualize/watch.janet reads it from here rather than
# keeping its own copy -- it has to skip this file when fingerprinting the
# tree, and two copies of a filename is one that goes stale.
#
# `.conf` rather than `.janet`: the config stopped being Janet when it became
# a PEG, and a file named for a language it is not misleads anyone who opens
# it expecting to write one.
(def config-name "visualize.conf")

# What the panel calls itself: the file, without the extension. The panel IS
# visualize.conf -- what you type there is what lands in it -- so naming it
# anything else made the two look like different things.
(def config-title "visualize")

# Written on first run so there is something to edit rather than a blank pane.
# Comments survive a round-trip through the editor, so they are worth having.
# THE STARTER no longer lists the verbs. It used to, and that made it the
# third place that had to be remembered when one changed -- `font` outlived
# its deletion here. The `?` in the corner is generated from the grammar and
# is therefore always right, so this points at it instead.
(def starter
  ``# One verb per line. Press ? for the full list.
# A name is the dotted path a node shows: (box src.parsers) draws a box
# round that directory, (hide src.test) drops it. Any other name is
# literal, so (box SwiftUI) boxes the framework. Comment out with '#'.
(lines)
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

  'run', 'reorder', 'regenerate' and 'check' change no text: every action
  re-runs the file anyway, so running IS just saving what is on screen, and
  `check` is running WITHOUT the saving.``
  [lines action index]
  (def out (array ;lines))
  (cond
    (or (= action "run") (= action "reorder") (= action "regenerate")
        (= action "check")) out
    (= action "insert-above") (array/insert out (max 0 index) "")
    (= action "insert-below") (array/insert out (min (length out) (+ index 1)) "")
    (= action "delete") (if (and (>= index 0) (< index (length out)))
                          (array/remove out index)
                          out)
    (errorf "unknown action '%s'" action)))

# WHAT THE LAST DRAWING SAW. Kept per-process rather than on disk: the
# comparison is "since you last looked", and a fresh page has not looked yet.
#
# Recorded on every draw whether or not `animate` asked for it, so turning
# the verb on mid-session compares against the drawing before it rather than
# against nothing.
(var- seen nil)

(defn- moved-since [stamps]
  ``Which nodes are new or have been written since the last drawing.

  Nothing on the FIRST draw -- there is no previous one to differ from, and
  flashing the whole graph on load would say only that the graph exists.``
  (def flashing @{})
  (when seen
    (eachp [name stamp] stamps
      (def before (seen name))
      (when (or (nil? before) (not= before stamp))
        (put flashing name true))))
  flashing)

(defn- render-svg
  ``Draw the graph the config asks for. Returns [ok svg-or-error].

  The scan is the whole graph; the narrowing, hiding, grouping and colouring
  are all applied to it on the way to the layout.``
  [root state]
  (def graph (scan/graph-of root))
  (if (graph :error)
    [false (graph :error)]
    (do
      # Narrow before hiding: (only ~) then (hide ~.Tests) reads the way
      # it is written, and hiding something already filtered out is a no-op
      # rather than an error.
      (def trimmed (select/drop-nodes (select/keep graph (state :only)) (state :hidden)))
      # AN ALIAS RELABELS THE NODES IT COVERS. `(prefix ~ src.visualize)`
      # makes `src.visualize.color` read `~.color`, so the picture speaks the
      # vocabulary the config is written in -- which is most of the point of
      # naming a prefix at all, since the shared head is the part that is the
      # same on every node and tells you nothing.
      #
      # The NAME is untouched: it is the node's identity, what edges point at
      # and what the config matches. Only the label changes.
      (def aliased
        (if (empty? (state :aliases))
          trimmed
          (merge trimmed
                 {:nodes (map (fn [node]
                                (if-let [short (config/alias-label (state :aliases)
                                                                   (node :name))]
                                  (merge node {:label (string/join (string/split "." short) ".\n")})
                                  node))
                              (trimmed :nodes))})))
      # The label carries the line count when (lines) asked for it. Done
      # on the graph rather than in a renderer, so both layouts get it and
      # the text that goes between them already says what the box reads.
      (def labelled
        (if (state :sized)
          (merge aliased
                 {:nodes (map (fn [node]
                                (if-let [size (get (graph :sizes) (node :name))]
                                  (merge node {:label (string (node :label) "\n"
                                                              (select/thousands size))})
                                  node))
                              (aliased :nodes))})
          aliased))
      # Compared before the record is updated, or every node would look
      # unchanged against a stamp taken moments ago.
      (def flashing (moved-since (graph :stamps)))
      (set seen (graph :stamps))
      (layout/draw labelled {:groups (state :groups)
                             :sized (state :sized)
                             :flashing (if (state :animated) flashing {})}))))


(defn page
  ``The HTML for a rendered graph. `fill` is what the CORE knows -- the
  token, so far -- supplied as a table, so this app does not reach into the
  server for it and the server does not know what a graph is.``
  [web-dir title lines problems svg fill]
  # `->>`, not `->`: string/replace takes the subject LAST, and threading it
  # first quietly produced a page that was the replacement value alone.
  (def template (slurp (string web-dir "/index.html")))
  (var out (->> template
                (string/replace "{{TITLE}}" title)
                (string/replace "{{CONFIG_NAME}}" config-title)
                (string/replace "{{CONFIG_LINES}}" (json/encode lines))
                (string/replace "{{CONFIG_PROBLEMS}}" (json/encode problems))
                # The help panel's content, generated from the grammar's own
                # verb table -- so the list cannot describe a verb the parser
                # does not have, or miss one it does.
                (string/replace "{{CONFIG_DOCS}}" (json/encode (config/docs)))))
  (eachp [key value] fill
    (set out (string/replace (string "{{" key "}}") value out)))
  # The SVG goes in last, and with a function rather than a literal:
  # string/replace treats `%` sequences in its replacement specially, and
  # SVG is full of them (percent widths, escaped characters in a label). A
  # function replacement is taken verbatim.
  (string/replace "{{GRAPH}}" (fn [&] svg) out))

(defn draw
  ``Everything the page needs for one render: the config's lines, whatever
  was wrong with them, and the graph or the error that stopped it.``
  [root config-path]
  (def lines (read-config config-path))
  (def [state problems] (config/run lines))
  (def [ok result] (render-svg root state))
  [lines problems ok result])

(defn forget-scan
  "Drop the cached scan, so the next draw re-reads the source tree."
  []
  (scan/forget))

# Which actions are worth a redraw. Inserting adds an EMPTY line, which by
# definition draws the same graph -- so it saves and returns immediately.
(def- draws {"run" true "delete" true "reorder" true "regenerate" true})

(defn config-edit
  ``Apply one button press from the page and answer with the result: the
  new lines, what was wrong with them, and a fresh graph when the action
  could have changed one.

  THE WHOLE ROUTE, not a helper for it. The core hands over the request
  body and gets back a reply; nothing about buttons, configs or graphs
  needs to exist on the other side of that call.``
  [root config-path body]
  (def sent (json/decode body))
  (def action (string (get sent "action" "")))
  (def index (math/floor (or (get sent "index") -1)))
  (def lines (edit (map string (get sent "lines" [])) action index))
  # `check` ASKS WITHOUT TELLING. It runs the lines and answers with what was
  # wrong, and writes nothing -- the compose bar uses it to find out whether
  # what you typed parses before that text reaches the file. Every other
  # action is an edit and saves.
  #
  # Save first, for those: the file is the thing being edited, and it should
  # hold what you just did even if drawing it then fails.
  (def asking (= action "check"))
  (unless asking (write-config config-path lines))
  # Rescanning is Regenerate's job, never a side effect of an edit -- the
  # cache is dropped only when you ask for it.
  (when (= action "regenerate") (forget-scan))
  (def [state problems] (config/run lines))
  (def [ok result]
    (if (and (draws action) (not asking)) (render-svg root state) [true ""]))
  {"lines" lines
   "problems" problems
   # A render failure belongs to no single line -- an unknown layout name is
   # not any one form's fault -- so it stays separate from the per-line
   # messages.
   "error" (if ok "" result)
   "svg" (if ok result "")})
