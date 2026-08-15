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
(import ./term/client :as term)
(import ./term/host :as term-host)
(import ./dev)
(import ./faults)
(import ./state)
# The first app built on this core. See the note at the top of graph.janet:
# it is a consumer, not a component -- delete it and the server still runs.
(import ./graph)
(import ./stamp)
(import ./watchdog)

# The env the dev repl evaluates in protos to THIS one, captured at load so
# a connection sees the same names this file sees -- every module above,
# prefixed, and everything defined below.
(def- this-env (curenv))

# Where to start looking, not where it will land. `serve` walks upward to the
# first free port -- another copy of this tool is often already up in another
# window, and "address already in use" leaves you to go find out who has it.
(def default-port 8770)
(def port-tries 20)

# What the terminal window runs when the config does not say. Claude Code
# because it is the harness this was built against; `(harness pi)` in the
# config picks another, and nothing below this line knows the difference.
(def default-harness ["claude"])

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
  # --supervise it is the process that owns the terminal, spawned by the
  # server's own client half and outliving it -- see src/term/host.janet
  # for why the pty cannot live here. Orchestrating both roles from this one
  # entry point means there is exactly one program to install, one to spawn,
  # and one place that knows how the pieces fit.
  (when (= (get args 1) "--supervise")
    (def path (or (get args 2) (error "usage: visualize --supervise <socket-path>")))
    # The tools live beside this file's checkout, and the host puts them on
    # the harness's PATH -- see ./vz. Computed here rather than read from
    # `here` below, which this branch runs before.
    (term-host/tools-at (os/realpath (string (dyn :current-file) "/../..")))
    (term-host/host path)
    (os/exit 0))

  # The dev flags were consumed at load (they had to be -- see the top of
  # this file); here they just must not be mistaken for the directory.
  (def args (filter |(not (index-of $ ["--dev" "--no-dev"])) args))
  (def root (os/realpath (or (get args 1) (os/cwd))))
  # The REPO root, two levels up: this file lives in visualize/, and bin/,
  # web/ and the parsers are siblings of that directory, not of this file.
  (def here (os/realpath (string (dyn :current-file) "/../..")))
  (def web-dir (string here "/web"))
  (def config-path (string root "/" graph/config-name))
  (def specs (graph/load-specs (string here "/src/parsers")))
  # Faults go to this project's state directory from here on, so a crash
  # that takes the server down is still readable afterwards.
  (faults/logging-to root)

  (def token (make-token))
  # When this run began. Faults are counted from here, so the page's number
  # means "since the server started" rather than "ever".
  (def page-born (os/time))

  # The terminal lives in another process, so that this one can be restarted
  # without killing the agent -- see src/term/client.janet. Told where to find
  # it and how to start one, both of which only this function knows.
  #
  # ONE CLIENT PER PANE, BUILT THE SAME WAY. The two panes differ in their
  # socket and in what their pty runs; everything else -- the backlog, the
  # reattach dance, the framing, the connection discipline -- is the same
  # code twice, which is the point. Registered by name so the repl's
  # equipment can ask about either without holding a client.
  #
  # The socket path is computed ONCE and passed twice per pane: the address
  # we look on and the address we tell a new host to bind have to be the same
  # string, and two calls is two chances for that to stop being true.
  (defn pane-for [socket]
    (term/make-client socket
                             [(string here "/bin/janet")
                              (string here "/src/core.janet")
                              "--supervise" socket]))

  (def agent-socket (socket-for root))
  (def agent-client (term/register "harness" (pane-for agent-socket)))

  # The repl window's pty, behind a SECOND host. What it runs is ./repl,
  # which is nc against this server's own repl socket: the page gets a
  # cooked-mode terminal into the live image, exactly what a person at a
  # shell gets. Dev-only, because the socket it would connect to only exists
  # in dev mode.
  (def replterm-socket (socket-for root ".replterm.sock"))
  (def repl-client
    (when dev?
      (term/register "repl" (pane-for replterm-socket))))
  # Where this run's dev repl listens. Named after the port, so it is only
  # knowable once the server has bound one -- set below, read per request.
  (var repl-socket nil)
  # Where this run advertises its url and token for local tooling (dev only).
  (var endpoint-path nil)

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
  (defn draw [] (graph/draw root specs config-path))

  (defn handler [request]
    (def path (without-query (request :path)))
    (def method (request :method))

    # Which harness the config asked for, re-read per request so editing the
    # config and pressing start does the new thing without a restart.
    (defn harness-argv []
      (or (graph/harness-argv config-path) default-harness))

    (defn guarded [reply]
      # One shape for every terminal endpoint: prove you are the page this run
      # served, or get nothing. See `permitted?`.
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
          {"serverStamp" stamp/born
           "faults" (faults/count-since page-born)}))])

    (cond
      (and (= method "GET") (= path "/"))
      (do
        (def [lines problems ok result] (draw))
        ["200 OK" "text/html; charset=utf-8"
         (graph/page web-dir (string (last (string/split "/" root)) " — visualize")
                     lines problems
                     (if ok result (string "<p>could not render: " result "</p>"))
                     # What only the core knows, handed over rather than
                     # reached for: the app fills its own template holes and
                     # this fills the server's.
                     {"TOKEN" (json/encode token)
                      "HARNESS_NAME" (string/join (harness-argv) " ")
                      "DEV" (json/encode dev?)
                      "STAMP" (json/encode stamp/born)})])

      # -- the harness ------------------------------------------------------
      # Polled rather than streamed over SSE. A terminal is a request/response
      # shape anyway -- the page has to send keystrokes regardless -- and one
      # endpoint that returns "everything since chunk N" is both the catch-up
      # path for a reload and the live path for a running session. SSE would
      # need a second mechanism for input and a way to resume a dropped
      # stream, which is this endpoint again with more parts.
      (and (= method "POST") (= path "/pane/harness/start"))
      (guarded (fn []
                 (def sent (json/decode (request :body)))
                 (def rows (math/floor (or (get sent "rows") 24)))
                 (def cols (math/floor (or (get sent "cols") 100)))
                 ["200 OK" "application/json"
                  (json/encode (:start agent-client (harness-argv) root rows cols))]))

      (and (= method "POST") (= path "/pane/harness/stop"))
      (guarded (fn [] ["200 OK" "application/json"
                       (json/encode (:stop agent-client))]))

      (and (= method "POST") (= path "/pane/harness/input"))
      (guarded (fn []
                 (def sent (json/decode (request :body)))
                 # `at` turns this into "type, and tell me what came back" --
                 # one round trip for a keystroke and its echo. See `send`.
                 (def echo (:send agent-client (string (get sent "text" ""))
                                         (when-let [a (get sent "at")]
                                           (math/floor a))
                                         (truthy? (get sent "quiet"))))
                 ["200 OK" "application/json"
                  (json/encode (or echo {"ok" true}))]))

      (and (= method "POST") (= path "/pane/harness/redraw"))
      (guarded (fn []
                 (:redraw agent-client)
                 ["200 OK" "application/json" (json/encode {"ok" true})]))

      (and (= method "POST") (= path "/pane/harness/resize"))
      (guarded (fn []
                 (def sent (json/decode (request :body)))
                 (:resize agent-client (math/floor (or (get sent "rows") 24))
                           (math/floor (or (get sent "cols") 100)))
                 ["200 OK" "application/json" (json/encode {"ok" true})]))

      (and (= method "POST") (= path "/pane/harness/poll"))
      (guarded (fn [] (poll-answer (fn [at gen wait] (:poll agent-client at gen wait))
                                   (request :body))))

      # -- the repl window --------------------------------------------------
      # The harness endpoints again, one per one, against the second
      # supervisor. The page drives both panes with the same code and only
      # the prefix differs, which is the point: nothing below this comment
      # knows it is a repl rather than an agent. Guarded by `dev?` first, so
      # without dev mode these fall through to the 404 like any other
      # unserved path.
      (and dev? (= method "POST") (= path "/pane/repl/start"))
      (guarded (fn []
                 (def sent (json/decode (request :body)))
                 ["200 OK" "application/json"
                  (json/encode
                    (:start repl-client
                            [(string here "/repl") repl-socket]
                            root
                            (math/floor (or (get sent "rows") 24))
                            (math/floor (or (get sent "cols") 100))))]))

      (and dev? (= method "POST") (= path "/pane/repl/stop"))
      (guarded (fn [] ["200 OK" "application/json"
                       (json/encode (:stop repl-client))]))

      (and dev? (= method "POST") (= path "/pane/repl/input"))
      (guarded (fn []
                 (def sent (json/decode (request :body)))
                 (def echo (:send repl-client
                                  (string (get sent "text" ""))
                                  (when-let [a (get sent "at")]
                                    (math/floor a))
                                  (truthy? (get sent "quiet"))))
                 ["200 OK" "application/json"
                  (json/encode (or echo {"ok" true}))]))

      (and dev? (= method "POST") (= path "/pane/repl/redraw"))
      (guarded (fn []
                 (:redraw repl-client)
                 ["200 OK" "application/json" (json/encode {"ok" true})]))

      (and dev? (= method "POST") (= path "/pane/repl/resize"))
      (guarded (fn []
                 (def sent (json/decode (request :body)))
                 (:resize repl-client
                          (math/floor (or (get sent "rows") 24))
                          (math/floor (or (get sent "cols") 100)))
                 ["200 OK" "application/json" (json/encode {"ok" true})]))

      (and dev? (= method "POST") (= path "/pane/repl/poll"))
      (guarded (fn []
                 (poll-answer (fn [at gen wait] (:poll repl-client at gen wait))
                              (request :body))))

      # WHICH TREE THIS RUN SERVES. The harness tools need the state
      # directory, and an agent's working directory is not a reliable
      # guide -- it may have cd'd anywhere. Cheap, and it means `vz` never
      # guesses.
      (and (= method "GET") (= path "/root"))
      (guarded (fn [] ["200 OK" "application/json"
                       (json/encode {"root" root "stamp" stamp/born})]))

      # WHAT HAS GONE WRONG LATELY, for the page's state line and for an
      # agent asking the tool about itself. Guarded like the terminal
      # endpoints because a stack trace names paths and code: the same
      # reasoning as `permitted?`, and no reason to be laxer.
      (and (= method "POST") (= path "/faults"))
      (guarded (fn []
                 (def sent (try (json/decode (request :body)) ([_] {})))
                 (def since (math/floor (or (get sent "since") 0)))
                 ["200 OK" "application/json"
                  (json/encode {"faults" (faults/recent
                                           (math/floor (or (get sent "limit") 10)))
                                "since" (faults/count-since since)
                                "now" (os/time)})]))

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
       (json/encode (graph/config-edit root specs config-path (request :body)))]

      ["404 Not Found" "text/plain" "not found"]))

  # In dev mode every request runs under the watcher, so a crash is a fiber
  # in dev/crashed and a breakpoint parks the request instead of losing it.
  (def [server bound accept-loop]
    (http/serve default-port port-tries (if dev? (dev/watched handler) handler)))
  (def url (string "http://127.0.0.1:" bound))

  # The dev repl: this process's own image on a unix socket, evaluating in an
  # env that sees everything this file sees. It runs whatever connects -- see
  # the security note on dev/serve. Now that every run hosts one, the name is
  # keyed to the BOUND PORT as well as the root: the live server and a sandbox
  # developing it share a root, and a name both computed from the root alone
  # would be stolen by whichever bound last -- dev/serve deletes and rebinds a
  # taken name on purpose. The port is the one thing the walk just made
  # unique, which is why this waits until after the bind.
  (when dev? (set repl-socket (socket-for root (string ".repl." bound ".sock"))))

  # WHERE AN AGENT FINDS THE DOOR. The terminal endpoints need this run's
  # token, and until now the only copy lived in the served HTML -- so an
  # agent working on this tool had to scrape the page for it, which is
  # precisely what one did before driving `start` at the wrong port and
  # replacing its own session. A dev-mode file says where the server is and
  # what the token is, so ./pane can post like the page does. Dev-only and
  # 0600: the token is the whole gate on a socket that runs a program.
  (when dev?
    (set endpoint-path (socket-for root ".endpoint.json"))
    (spit endpoint-path (json/encode {"url" url "token" token
                                      "stamp" stamp/born}))
    (os/chmod endpoint-path 8r600))
  # The repl advertises the session tools without importing them: harness
  # writes the lines, core hands them over, dev prints whatever it is given.
  # The repl advertises the session tools without importing them: harness
  # writes the lines, core hands them over, dev prints whatever it is given.
  (when dev?
    (dev/serve repl-socket this-env "visualize"
               (string term/equipment
                       "faults:   (faults/print-recent) what has gone wrong lately\n")))

  # CTRL-C TAKES THE AGENT WITH IT, and this is the only thing that does.
  #
  # The terminal now lives in another process precisely so the server can die
  # and come back -- but that must not turn quitting into "the agent silently
  # keeps running". So the two exits are told apart by who caused them:
  # ctrl-c says `shutdown` and the supervisor kills the pty exactly as the old
  # single process did, while a restart under --watch closes its socket and
  # says nothing.
  #
  # Explicit rather than relying on the signal reaching the supervisor. SIGINT
  # goes to the process group, which would usually include it -- but it was
  # spawned detached, and "usually" is not a lifetime guarantee.
  (os/sigaction :int (fn []
                       (print)
                       (print "visualize: stopping the harness")
                       (try (:shutdown agent-client) ([_] nil))
                       # The repl window's supervisor goes the same way: its
                       # nc is talking to a socket about to be removed, so
                       # there is nothing there worth outliving us.
                       (when repl-client (try (:shutdown repl-client) ([_] nil)))
                       # The repl socket dies with its server, so its name
                       # should too: every run mints one now, and the port in
                       # the name means a restart rarely reclaims yesterday's.
                       (when repl-socket (try (os/rm repl-socket) ([_] nil)))
                       (when endpoint-path (try (os/rm endpoint-path) ([_] nil)))
                       (os/exit 0)))

  (defn align-word
    [word to]
    (string ;(map (fn [_] " ") (range (- (length to) (length word)))) word))

  (print "visualize: " root " on " url)
  (print (align-word "config: " "visualize: ") config-path)
  (print (align-word "parsers: " "visualize: ") (string/join (graph/spec-names specs) ", "))
  (when dev? (print (align-word "repl: " "visualize: ") "nc -U " repl-socket))
  (print "ctrl-c to stop")
  # The loop's own witness: a thread that names event-loop stalls on stderr,
  # from the one vantage point a stall cannot silence.
  (watchdog/start "server")
  # Off the server, not off the constant: they differ whenever the first
  # choice was taken, and printing the wrong one sends you to somebody else's
  # page.
  (os/spawn ["open" url] :pd)
  (accept-loop))
