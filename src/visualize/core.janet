#!/usr/bin/env janet
#
# visualize -- a dependency graph you draw by editing a file.
#
#     janet src/core.janet [directory]
#
# Opens a browser on the first free port at or above 8770. How the graph is
# drawn lives in `visualize.conf` in the directory being scanned -- a few
# s-expressions, edited through the page itself:
#
#     (hide ~.Tests)          drop it, and every edge touching it
#     ;;(hide ~.Tests)        comment it out to put it back
#     (hide ~.Clip.)          ...trailing dot: its contents, not itself
#     (box ~.Clip)            draw a box round its members, next palette colour
#     (box ~.Shared red)      ...or a colour you name
#     (only ~)                narrow to our own files -- the everyday setting
#     (lines)                 write each file's line count on it
#
# `~` IS THE PROJECT, the way a shell expands ~ to a home directory. Every
# other name is literal, so (box SwiftUI) and (hide WebKit) work on the
# imported frameworks exactly as they do on our own files.
#
# The config is real Janet, so it is not limited to the list above:
#
#     (each n ["Core" "UI" "Net"] (box (string "~." n)))
#
# The page runs that file on load, so the view you left is the view you return
# to. Every button press is a real edit to the real file.

# DEV MODE IS THE DEFAULT, DECIDED BEFORE ANYTHING COMPILES. Every server run
# hosts a repl inside itself (see src/dev.janet) and turns on `*redef*`,
# which is a property of code generation, not of runtime: set after the
# imports below, the engine would already be compiled to constants and a repl
# redefinition would silently change nothing. `--no-dev` opts out; `--dev` is
# accepted for old habits and changes nothing.
#
# The SUPERVISOR is not a dev surface: it hosts no repl, it owns the agent's
# pty, and it was never compiled under *redef* before -- the server spawned it
# without the flag. Excluding it here preserves exactly that.
(def dev?
  (let [argv (or (dyn *args*) [])]
    (not (or (index-of "--no-dev" argv)
             (index-of "--supervise" argv)))))

(when dev? (put root-env *redef* true))

(import ./http)
(import ./json)
# The first app built on this core. See the note at the top of graph.janet:
# it is a consumer, not a component -- delete it and the server still runs.
(import ./config)
(import ./graph)
(import ./scan)
# The terminal pane: a client here, and a host in another process. The pty's
# master fd belongs to whoever called forkpty and cannot be handed on, so the
# session has to outlive this server rather than live in it -- see
# ./term/host.janet. This process only ever speaks to it over a socket.
(import ./term/client :as term)
(import ./term/host :as term-host)

# The env the dev repl evaluates in protos to THIS one, captured at load so
# a connection sees the same names this file sees -- every module above,
# prefixed, and everything defined below.
(def- this-env (curenv))

# Where to start looking, not where it will land. `serve` walks upward to the
# first free port -- another copy of this tool is often already up in another
# window, and "address already in use" leaves you to go find out who has it.
(def default-port 8770)
(def port-tries 20)

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

# `/pane/<id>/<op>` split into its two halves, or nil when the path is not
# one -- which is what the route match tests.
#
# THE ID IS CONSTRAINED BECAUSE IT BECOMES A FILENAME. It is passed to
# `socket-for` as a tag and lands in $TMPDIR, so `..` or a slash in it would
# be a path this server was asked to bind rather than a name. Lowercase
# letters, digits and dashes only: everything a pane needs to be called and
# nothing that can leave the directory.
(defn- pane-route [path]
  (peg/match ~(* "/pane/" (<- (some (+ (range "az") (range "09") "-"))) "/"
                 (<- (some (range "az"))) -1)
             path))

(defn- socket-for
  ``Where this project's supervisor listens.

  Keyed to the root so two copies of visualize, pointed at two directories, do
  not end up sharing one terminal. The name is derived rather than random: a
  restarting server has to find the supervisor its predecessor started, and it
  has nothing to go on but the path it was given.

  HASHED RATHER THAN SPELLED OUT, because a sockaddr_un holds about 104 bytes
  on this platform and $TMPDIR alone is half of that. A deep project path
  would overflow it, and the failure is a bind error rather than a truncation
  you could notice.``
  [root &opt tag]
  (default tag ".sock")
  (def base (string/trimr (or (os/getenv "TMPDIR") "/tmp") "/"))
  # A cheap, stable digest: the path never leaves this machine, so this is
  # only asking for "different directories, different names".
  #
  # `%` RATHER THAN `band`, and 31 bits rather than 32. Janet's bitwise ops
  # take 32-bit SIGNED operands and `* 33` leaves that range on the third
  # character of any real path -- so masking afterwards is already too late,
  # and masking with 0xffffffff would then hand `%x` a number it also refuses.
  # A modulo applies to the arithmetic value before either limit is reached.
  # Dropping the top bit costs nothing: this is a name, not a checksum.
  (var digest 5381)
  (each byte (string/trimr root "/")
    (set digest (% (+ (* digest 33) byte) 0x7fffffff)))
  (string base "/visualize-" (string/format "%08x" digest) tag))

(defn main [& args]
  # ONE PROGRAM, TWO ROLES. Run plainly, this is the web server. Run with
  # --supervise it is the process that owns a terminal, spawned by the
  # server's own client half and outliving it -- see ./term/host.janet for
  # why the pty cannot live here. Both roles from one entry point means one
  # program to install, one to spawn, and one place that knows how the
  # pieces fit.
  #
  # BEFORE the flag filtering below, and before anything reads a directory:
  # this branch never returns.
  (when (= (get args 1) "--supervise")
    (def path (or (get args 2) (error "usage: visualize --supervise <socket-path>")))
    (term-host/host path)
    (os/exit 0))

  # The dev flags were consumed at load (they had to be -- see the top of
  # this file); here they just must not be mistaken for the directory.
  (def args (filter |(not (index-of $ ["--dev" "--no-dev"])) args))
  (def root (os/realpath (or (get args 1) (os/cwd))))
  # THE PROJECT BEING LOOKED AT, which is not this tool. The last component
  # of the scanned path is what a person calls the thing on screen, and with
  # several visualize tabs open it is the only thing telling them apart.
  (def project
    (let [parts (filter |(not (empty? $)) (string/split "/" root))]
      (if (empty? parts) "/" (last parts))))
  # The REPO root, two levels up: this file lives in visualize/, and bin/,
  # web/ and the parsers are siblings of that directory, not of this file.
  (def here (os/realpath (string (dyn :current-file) "/../..")))
  (def web-dir (string here "/web"))
  (def config-path (string root "/" config/config-name))
  # THE SOURCE GENERATION. Bumped whenever the watcher sees the tree change;
  # the page waits on it and redraws, which is what replaced the Regenerate
  # button. A number rather than a flag so a page that missed one edit still
  # knows it is behind.
  (var source-generation 0)

  # THE SCANNED TREE, held here because this is what knows when it is stale.
  # The watcher below tells this loop the source moved, and the same place
  # that hears it is the place that drops the tree -- rather than a renderer
  # holding a cache that something else has to remember to invalidate.
  #
  # Scanned on demand rather than at startup, so a first draw pays for it and
  # a re-scan is just forgetting.
  #
  # CHECKED PER DRAW, not only when the watcher fires. The watcher polls, so
  # between an edit and the tick that notices it there is a window -- and a
  # config save landing in that window used to draw the STALE tree. That drew
  # the edited file as unchanged and, worse, recorded it as seen: the flash
  # then arrived on whatever redraw came after the tick, which is how a file
  # nobody was working on appeared to flash out of nowhere.
  #
  # The fingerprint is the cheap half of a scan (a stat per file), so asking
  # it per draw costs a few milliseconds and removes the window entirely.
  (var tree nil)
  (var tree-print nil)
  (defn scanned []
    (def now (scan/fingerprint root))
    (when (or (nil? tree) (not= now tree-print))
      (set tree (scan/scan root))
      (set tree-print now))
    tree)
  (defn rescan [] (set tree nil))

  # Faults go to this project's state directory from here on, so a crash
  # that takes the server down is still readable afterwards.
  (def token (make-token))
  # When this run began. Faults are counted from here, so the page's number
  # means "since the server started" rather than "ever".
  (def page-born (os/time))

  # THE TERMINAL LIVES IN ANOTHER PROCESS, so this one can be restarted
  # without killing what is running in it -- the pty's master fd belongs to
  # whoever called forkpty and cannot be handed on. This client knows where
  # to look for a host and how to start one; it never holds the fd itself.
  #
  # The socket path is computed ONCE and passed twice: the address we look on
  # and the address we tell a new host to bind have to be the same string,
  # and two calls is two chances for that to stop being true.
  # `here` is src/, which is what web-dir wants; the runtime and this file
  # are named from the REPO root, one level further up. Spelled out rather
  # than reusing `here` with a "/.." glued on, because the two are different
  # anchors and gluing hid that -- the first version spawned
  # src/external-src/janet/janet and the pane just never started.
  (def repo (os/realpath (string here "/..")))

  # A CLIENT PER PANE, MADE ON DEMAND. Panes are numbered, and a number is
  # all the page sends: the first request naming one builds its client and
  # its socket, and every request after finds the same one. Nothing is
  # started here, because a client that has never been asked for anything
  # has no host behind it -- the pane the page opens is what spawns one.
  #
  # KEYED BY THE SAME NUMBER ON BOTH SIDES. The socket tag is the pane's
  # number, so pane 2 always finds pane 2's host across a server restart --
  # which is the property the whole split exists for.
  (def panes @{})
  (defn pane-for [id]
    (or (get panes id)
        (let [socket (socket-for root (string "." id ".sock"))
              client (term/make-client
                       socket
                       [(string repo "/external-src/janet/janet")
                        (string repo "/src/visualize/core.janet")
                        "--supervise" socket])]
          (put panes id client)
          client)))
  # The pane Control opens. Numbered like the rest so nothing special-cases
  # it, and made eagerly because the page's markup names it at load.
  (def pane-client (pane-for "harness"))

  # WHAT THE TERMINAL RUNS. An environment variable rather than a config verb
  # for now: the config's verb table describes fixed-arity calls over graph
  # prefixes, and a command line is neither -- `(harness claude --flag x)` is
  # variadic free text, which the grammar has no kind for. Adding one is a
  # config-language decision, not a terminal one, so this stays out of the
  # way until that is made. VISUALIZE_HARNESS is read per request, so
  # changing it and pressing start does the new thing.
  (defn harness-argv []
    (def named (os/getenv "VISUALIZE_HARNESS"))
    (if (and named (not (empty? named)))
      (string/split " " named)
      # A shell is the honest default: it needs nothing installed, and it
      # proves the pane works before anything is pointed at it.
      [(or (os/getenv "SHELL") "/bin/sh") "-i"]))

  # A DIRECTORY NAME IS NOT MARKUP. Both the title and the favicon carry the
  # project's name into the page's head, and a directory may be called
  # anything at all -- `<script>` is a legal name on every filesystem here.
  # Escaped once, in one place, so the two holes cannot disagree about it.
  (defn escaped [text]
    (->> text
         (string/replace-all "&" "&amp;")
         (string/replace-all "<" "&lt;")
         (string/replace-all ">" "&gt;")
         (string/replace-all "\"" "&quot;")
         (string/replace-all "'" "&#39;")))

  # THE TAB'S PICTURE: the project's first letter, drawn rather than fetched.
  #
  # A data URI because everything else the page loads is served from web/ and
  # this is not a file -- it depends on which directory the server was pointed
  # at, so there is nothing to put on disk. SVG because a letter at 16px has
  # to be drawn at whatever size the browser asks for, and a bitmap picked one.
  #
  # The colour is the graph's own ink, so the tab matches the drawing.
  (def favicon
    (let [safe (escaped (string/ascii-upper (string/slice project 0 1)))]
      (string
        "data:image/svg+xml,"
        # Percent-encoded by hand: only the characters a data URI actually
        # cannot carry. Leaving the rest legible keeps this readable in a
        # view-source, which is where anyone will meet it.
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

  # The app's render, and the values only the CORE knows, kept apart: the
  # graph does not reach into the server for a token, and the server does
  # not know what a graph is.
  # ONE DRAWING, from the file: read the config, run it, render it. The three
  # steps are three modules -- config owns the file and the language, graph
  # owns the picture, and this is where they meet.
  (defn draw []
    (def lines (config/read-config config-path))
    (def [state problems] (config/run lines))
    (def [ok result] (graph/render-svg (scanned) state))
    [lines problems ok result])

  # THE PAGE, built here rather than in graph. Slurping a template and
  # substituting holes is serving, not drawing -- and it needed `json` to
  # hand the config to the browser, which was the renderer's only reason to
  # know that format exists.
  (defn page [title lines problems svg fill]
    # `->>`, not `->`: string/replace takes the subject LAST, and threading
    # it first quietly produced a page that was the replacement value alone.
    (def template (slurp (string web-dir "/index.html")))
    (var out (->> template
                  (string/replace "{{TITLE}}" (escaped title))
                  (string/replace "{{FAVICON}}" favicon)
                  (string/replace "{{CONFIG_NAME}}" config/config-title)
                  # The pane's bar says what it runs, so a glance tells you
                  # which harness this run would start.
                  # The LEAF, matching what the pane writes into its own bar
                  # once a session reports its argv -- /bin/zsh and zsh are
                  # the same answer, and the two should not disagree for the
                  # moment before the first start reply lands.
                  (string/replace "{{HARNESS_NAME}}"
                                  (escaped (last (string/split "/" (first (harness-argv))))))
                  (string/replace "{{CONFIG_LINES}}" (json/encode lines))
                  (string/replace "{{CONFIG_PROBLEMS}}" (json/encode problems))
                  # The help panel's content, generated from the grammar's
                  # own verb table -- so the list cannot describe a verb the
                  # parser does not have, or miss one it does.
                  (string/replace "{{CONFIG_DOCS}}" (json/encode (config/docs)))
                  (string/replace "{{CONFIG_COLOURS}}" (json/encode (config/colours)))))
    (eachp [key value] fill
      (set out (string/replace (string "{{" key "}}") value out)))
    # The SVG goes in last, and with a function rather than a literal:
    # string/replace treats `%` sequences in its replacement specially, and
    # SVG is full of them (percent widths, escaped characters in a label). A
    # function replacement is taken verbatim.
    (string/replace "{{GRAPH}}" (fn [&] svg) out))

  # ONE BUTTON PRESS from the page: edit the lines, save unless only asked,
  # and answer with what went wrong and a fresh drawing.
  #
  # Here rather than in graph because it is a route -- it decodes a request
  # body and shapes a reply, which is this file's subject. It also means the
  # body is decoded ONCE: core used to parse it to look for `regenerate` and
  # then hand the raw string to graph, which parsed it again.
  (defn config-edit [body]
    (def sent (json/decode body))
    (def action (string (get sent "action" "")))
    (def index (math/floor (or (get sent "index") -1)))
    (def lines (config/edit (map string (get sent "lines" [])) action index))
    # `check` ASKS WITHOUT TELLING. It runs the lines and answers with what
    # was wrong, and writes nothing -- the compose bar uses it to find out
    # whether what you typed parses before that text reaches the file. Every
    # other action is an edit and saves.
    #
    # Save first, for those: the file is the thing being edited, and it
    # should hold what you just did even if drawing it then fails.
    (def asking (= action "check"))
    (unless asking (config/write-config config-path lines))
    # Regenerate means "the source changed and I am telling you", so the
    # tree is dropped before the edit is drawn.
    (when (= action "regenerate") (rescan))
    # Drawn by graph, which owns what a config means. An action that changes
    # no picture is still RUN -- the complaints are what the editor draws
    # under the lines -- and only the drawing is skipped.
    (def [state problems] (config/run lines))
    # An action that cannot have changed the picture is still RUN -- the
    # complaints are what the editor writes under the rows -- and only the
    # drawing is skipped.
    (def [ok result]
      (if (or asking (not (config/draws action)))
        [true ""]
        (graph/render-svg (scanned) state)))
    {"lines" lines
     "problems" problems
     # A render failure belongs to no single line -- an unknown layout name
     # is not any one form's fault -- so it stays separate from the per-line
     # messages.
     "error" (if ok "" result)
     "svg" (if ok result "")})

  (defn handler [request]
    (def path (without-query (request :path)))
    (def method (request :method))

    (defn guarded [reply]
      # One shape for every endpoint that writes: prove you are the page this
      # run served, or get nothing. See `permitted?`.
      (if (permitted? request)
        (reply)
        ["403 Forbidden" "application/json"
         (json/encode {"error" "bad or missing token"})]))

    (defn poll-answer
      ``The reply to a poll, for either pane. `ask` is the client's poll --
      the ONLY thing that differs between the two panes, which is the point:
      the page drives both with identical code, so the server answers them
      with identical code. They were once two copy-pasted blocks, and the
      repl's copy had already lost the comments explaining its own arguments.

      One call rather than `since` plus `state`: this is the hot path, and
      each one is a round trip to the supervisor.``
      [ask body]
      (def sent (json/decode body))
      ["200 OK" "application/json"
       (json/encode
         (merge
          (ask (math/floor (or (get sent "at") 0))
               # Which session the page's `at` belongs to. Absent from an
               # older page, which then gets the previous behaviour rather
               # than an error.
               (when-let [g (get sent "generation")] (math/floor g))
               # How long the page is willing to have this request PARK for
               # output -- the streaming transport. Absent from an older
               # page, which keeps polling on its own timers.
               (when-let [w (get sent "wait")] (math/floor w)))
          # The server's own stamp beside the supervisor's, so the page can
          # tell WHICH of its three parties is running old code -- see
          # stamp.janet for the two rounds that question once cost. And how
          # many faults the server has recorded since this page loaded, so
          # the pane can say so rather than leaving them on a stderr nobody
          # is watching.
          {}))])

    (cond
      (and (= method "GET") (= path "/"))
      (do
        (def [lines problems ok result] (draw))
        ["200 OK" "text/html; charset=utf-8"
         # The PROJECT names the tab, not the tool. Someone with three of
         # these open is telling apart the things being looked at, and every
         # one of them is visualize.
         (page project
               lines problems
               (if ok result (string "<p>could not render: " result "</p>"))
               # What only the core knows, handed over rather than reached
               # for: the page fills the template's holes and this fills the
               # server's.
               {"TOKEN" (json/encode token)})])

      # THE WATCH: park until the source changes, so an edit on disk redraws
      # the page without anyone pressing anything. Parked rather than
      # polled so that an idle page costs one held connection rather
      # than a request a second -- with a bounded hold so a proxy or a
      # sleeping laptop cannot leave the request hanging forever.
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

      # THE GRAPH ALONE, as SVG. The page embeds the same picture, but an
      # agent asking "what does it look like now?" should not have to dig
      # it out of a page full of terminal panes and config rows -- and SVG
      # is text, which is the one image format something with a Read tool
      # can actually reason about. `vz shot` fetches this.
      (and (= method "GET") (= path "/graph.svg"))
      (guarded (fn []
                 (def [_ _ ok result] (draw))
                 (if ok
                   ["200 OK" "image/svg+xml" result]
                   ["500 Internal Server Error" "text/plain" result])))


      # Anything else in web/, served by name rather than by a route per file.
      #
      # THIS WAS A ROUTE PER FILE and it broke the whole page: app.js grew an
      # `import './term.js'`, nothing served term.js, and the 404 aborted the
      # module -- so panning, zooming and the config editor all died along
      # with the terminal. One missing line took out every interaction on the
      # page, which is exactly the failure a whitelist invites.
      (and (= method "GET")
           (when-let [name (http/static-file path)]
             (= :file (os/stat (string web-dir "/" name) :mode))))
      (let [name (http/static-file path)]
        ["200 OK" (http/content-type name) (slurp (string web-dir "/" name))])

      # The graph app's route, answered whole by the app. The core knows
      # only that something owns /config; what a config is, what a button
      # does and what gets drawn are none of its business.
      (and (= (request :method) "POST") (= path "/config"))
      ["200 OK" "application/json"
       (json/encode (config-edit (request :body)))]

      # -- the terminal pane ------------------------------------------------
      # Every one of these drives a session this process does not own. They
      # are all `guarded`: the endpoint runs a program, so no token means no
      # answer. See `permitted?`.
      #
      # THE /pane/ PREFIX EARNS ITS KEYSTROKES. A route called /term/poll
      # reads as though it polled a terminal emulator; this is a pane in the
      # page talking about the session behind it, and the prefix says so.
      #
      # ONE MATCH FOR EVERY PANE. The id is read out of the path rather than
      # written into five routes per pane -- the page opens as many as it
      # likes, and the first request naming one is what brings its client
      # into being. A pane id is [a-z0-9-]: it becomes a socket filename, so
      # anything that could climb out of a directory is not a name.
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
            "start"
            ["200 OK" "application/json"
             (json/encode (:start client (harness-argv) root (rows) (cols)))]

            "stop"
            ["200 OK" "application/json" (json/encode (:stop client))]

            # A TAB THAT IS BEING DESTROYED, not merely put away. `stop` ends
            # the session and leaves the host running to take another; this
            # ends the host as well, because nothing will ever ask about this
            # pane again and a supervisor per closed tab is a process leak.
            "shutdown"
            (do (:shutdown client)
                (put panes id nil)
                ["200 OK" "application/json" (json/encode {"ok" true})])

            # `at` turns this into "type, and tell me what came back" -- one
            # round trip for a keystroke and its echo.
            "input"
            ["200 OK" "application/json"
             (json/encode (:send client (string (get sent "text" ""))
                                 (when-let [a (get sent "at")] (math/floor a))))]

            "redraw"
            (do (:redraw client)
                ["200 OK" "application/json" (json/encode {"ok" true})])

            "resize"
            (do (:resize client (rows) (cols))
                ["200 OK" "application/json" (json/encode {"ok" true})])

            "poll"
            (poll-answer (fn [at gen wait] (:poll client at gen wait))
                         (request :body))

            ["404 Not Found" "application/json"
             (json/encode {"error" (string "no such pane op '" op "'")})])))

      ["404 Not Found" "text/plain" "not found"]))

  (def [server bound accept-loop]
    (http/serve default-port port-tries handler))
  (def url (string "http://127.0.0.1:" bound))

  (os/sigaction :int (fn [] (print) (os/exit 0)))

  (defn align-word
    [word to]
    (string ;(map (fn [_] " ") (range (- (length to) (length word)))) word))

  (print "visualize: " root " on " url)
  (print (align-word "config: " "visualize: ") config-path)
  (print (align-word "parsers: " "visualize: ") (string/join (scan/languages) ", "))
  (print "ctrl-c to stop")
  # WATCH THE SOURCE. An edit anywhere under the root drops the scan cache
  # and bumps the generation; the page is parked on /watch and redraws. This
  # is what the Regenerate button used to do by hand, and the reason it is
  # gone: a tool for seeing a codebase should not need to be told the
  # codebase changed.
  (scan/watch root
              (fn []
                (rescan)
                (++ source-generation)))
  # Off the server, not off the constant: they differ whenever the first
  # choice was taken, and printing the wrong one sends you to somebody else's
  # page.
  (os/spawn ["open" url] :pd)
  (accept-loop))
