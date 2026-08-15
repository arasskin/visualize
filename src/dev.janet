# A repl the running server hosts, for working on the tool from inside it.
#
# In most lisps you launch the program FROM a repl and live there. Two facts
# about this runtime rule that out: `getline` blocks the whole thread while it
# waits, so an idle stdin prompt would freeze every fiber the server is
# serving with; and top-level defs compile to constants, so redefining a
# function at a prompt silently changes nothing that was already compiled.
# So the arrangement is inverted, the way Swank and nREPL invert it: the
# SERVER hosts the repl on a unix socket, reads it with the same ev machinery
# it serves requests with, and dev mode turns on `*redef*` before anything
# compiles so redefinition actually lands. Connect with `nc -U <socket>`.
#
# Three doors in:
#
#   - The socket repl evaluates in an env whose proto is the server's own, so
#     every module and def is in reach. An error drops the CONNECTION into
#     the core dot-command debugger -- (.stack), (.frame), (.locals),
#     (.step) -- on the failed fiber, exactly as `janet -d` does on stdin.
#
#   - A request handler that errors leaves its fiber, whole stack and locals
#     intact, in `crashed`. Attach to it minutes later with (attach n): the
#     corpse is a value, not a moment.
#
#   - A breakpoint -- (debug/fbreak fun pc), set from the repl on the live
#     bytecode -- parks the next request that crosses it in `parked`, its
#     client waiting, every other request unaffected. (attach id) opens the
#     debugger on it mid-flight; (continue id) lets it finish.

# -- what the wrapper catches -------------------------------------------------

(def crashes-kept 16)

(def crashed
  "Request fibers that died, oldest first, stacks and locals intact."
  @[])

(def parked
  "Requests suspended at a breakpoint: id -> {:fiber :gate :since}."
  @{})

(var- park-counter 0)

(defn continue
  "Let a parked request run on. The id is a key of `parked`."
  [id]
  (if-let [park (get parked id)]
    (do (ev/give (park :gate) :continue) :continuing)
    (errorf "nothing parked under %v -- see (keys dev/parked)" id)))

(defn watched
  ``Wrap a request handler so its failures stay debuggable.

  The work runs in an inner fiber that masks error and debug signals, so this
  wrapper -- not the scheduler -- decides what happens next. An error banks
  the fiber in `crashed` and then propagates, so the server's own logging and
  500 still happen; the bank is the difference between a stacktrace and a
  stack. A debug signal parks the request behind a channel until `continue`.
  ev suspensions are neither masked nor maskable, so the handler's real io
  passes through the inner fiber untouched.``
  [handler]
  (fn [request]
    (def inner (fiber/new (fn [] (handler request)) :de))
    (var out (resume inner))
    (forever
      (case (fiber/status inner)
        :error (do
                 (array/push crashed inner)
                 (when (> (length crashed) crashes-kept)
                   (array/remove crashed 0))
                 (propagate out inner))
        :debug (do
                 (def id (++ park-counter))
                 (def gate (ev/chan 1))
                 (put parked id {:fiber inner :gate gate :since (os/clock)})
                 (eprintf "dev: a request hit a breakpoint -- (dev/attach %d) inspects, (dev/continue %d) resumes" id id)
                 (ev/take gate)
                 (put parked id nil)
                 (set out (resume inner)))
        (break)))
    out))

# -- the debugging equipment ---------------------------------------------------
# The hang hunt's tools, kept where the next investigator -- human or model
# -- will find them: at the repl, named in the connection banner. Each one
# had to be improvised once; none should need improvising twice.

(import ./harness)
(import ./stamp)

(def- here (os/realpath (string (dyn :current-file) "/../..")))

(defn stats
  ``Print both sides' op timings: the server's asks (turn-wait vs talk --
  the split that separates "queued behind a wedged exchange" from "the
  wedged exchange itself") and the supervisor's handle table, plus its
  queue depths. Numbers survive since each process started.``
  []
  (def all (harness/stats))
  (print "server asks (op: count, worst turn-wait, worst talk):")
  (eachp [op entry] (all "server-asks")
    (printf "  %-12s %6d  %6.3fs  %6.3fs" op (entry :count)
            (entry :worst-turn) (entry :worst-talk))
    (each slow (entry :slow)
      (printf "      slow: turn %.2fs talk %.2fs" (slow :turn) (slow :talk))))
  (def sup (all "supervisor"))
  (if-not sup
    (print "supervisor: unreachable (or predates the stats op)")
    (do
      (printf "supervisor (stamp %s, up %.0fs, unsent %d, chunks %d):"
              (get sup "stamp" "?") (get sup "uptime" 0)
              (get sup "unsent" 0) (get sup "chunks" 0))
      (eachp [op entry] (get sup "ops" {})
        (printf "  %-12s %6d  %6.3fs worst" op (get entry "count" 0)
                (get entry "worst" 0))
        (each slow (get entry "slow" [])
          (printf "      slow: %.2fs" (get slow "took" 0))))))
  nil)

(defn dump
  ``Write the live session's whole backlog -- the recording of everything
  the program drew -- to `path`, and say how to replay it. This is the
  capture half of the forensic loop that convicted the wrap and
  alternate-screen bugs; (dev/replay) is the other half.``
  [&opt path]
  (default path (string "/tmp/visualize-dump-" (os/time) ".bin"))
  (def now (harness/poll 0))
  (spit path (get now "text" ""))
  (printf "%d bytes -> %s (recorded at %dx%d)"
          (length (get now "text" "")) path (get now "rows" 24) (get now "cols" 80))
  (printf "replay: (dev/replay %v) or: node %s/tools/replay.mjs %s --rows %d --cols %d"
          path here path (get now "rows" 24) (get now "cols" 80))
  path)

(defn replay
  ``Run a capture through the emulator headlessly and report suspects --
  escape-like text on the final screen, the signature of a torn stream or
  a parser gap. Geometry defaults to the live session's, since a recording
  replayed at the wrong size scatters absolute cursor positions.``
  [path &opt rows cols]
  (def now (harness/poll 0))
  (default rows (get now "rows" 24))
  (default cols (get now "cols" 80))
  # Spawned with a pipe rather than executed: the child's stdout is the
  # PROCESS's stdout -- the server's log -- while the repl reader is on the
  # other end of a socket. Read and re-print, so the verdict lands where
  # the question was asked.
  (def proc (os/spawn ["node" (string here "/tools/replay.mjs") path
                       "--rows" (string rows) "--cols" (string cols)]
                      :p {:out :pipe :err :pipe}))
  (def said (:read (proc :out) :all))
  (def complained (:read (proc :err) :all))
  (os/proc-wait proc)
  (when said (prin said))
  (when (and complained (pos? (length complained))) (prin complained))
  nil)

# -- hot reload ---------------------------------------------------------------

(defn reload
  ``Re-evaluate a loaded module's source into its LIVE environment.

  `import :fresh` is the wrong tool for a running image: it builds a new
  environment, and every caller compiled so far holds bindings from the old
  one. Re-running the file into the env `module/cache` already has updates
  those bindings in place, and with `*redef*` on -- dev mode sets it before
  anything compiles -- the update is seen by every compiled caller at once.
  Top-level state (`var`, `def` of a table) is re-initialised by the re-run;
  state that must survive development belongs in the supervisor anyway,
  which is the same reason the server itself is restartable.

  `name` matches a substring of the module's path: (dev/reload "scan").``
  [name]
  (unless (dyn *redef*)
    (error "not in dev mode: without *redef* set at startup, a reload compiles but changes no caller"))
  (def hits (filter (fn [[path _]] (string/find name path)) (pairs module/cache)))
  (case (length hits)
    0 (errorf "no loaded module matches %v" name)
    1 (let [[path env] (first hits)]
        (dofile path :env env)
        path)
    (errorf "%v is ambiguous: %s" name (string/join (map first hits) ", "))))

# -- the socket repl ----------------------------------------------------------
# Core `repl` and core `debugger-env`, re-plumbed from stdin to a connection.
# Everything evaluated prints into `out`, and `out` is flushed to the socket
# each time the repl comes back for more input -- so results, stacktraces and
# the next prompt arrive in the order a person expects them.

(defn- flush-to [conn out]
  (when (pos? (length out))
    (:write conn out)
    (buffer/clear out)))

(defn- socket-chunks
  "A `repl` chunks function that speaks the socket instead of `getline`."
  [conn out name]
  (fn [buf p]
    (flush-to conn out)
    (def [line] (parser/where p))
    (:write conn (string name ":" line ":" (parser/state p :delimiters) "> "))
    # nil -- the client hung up -- ends the repl, which ends the connection.
    (when-let [got (:read conn 4096)]
      (buffer/push-string buf got))))

# Tied in a knot on purpose: an error at the repl enters the debugger, and an
# error IN the debugger enters a deeper one, numbered like the core's.
(var- enter-debugger nil)

(defn- make-onsignal
  ``What happens when an evaluated form finishes or fails.

  A finished form echoes its value, kept under `_` like the core repl keeps
  it. A fiber that stopped without dying -- an error, or a breakpoint the
  form walked into -- goes to the debugger with its stack still standing.``
  [conn out env level]
  (fn [f x]
    (if (= :dead (fiber/status f))
      (do
        (put env '_ @{:value x})
        (xprintf out (get env :pretty-format "%q") x))
      (do
        (debug/stacktrace f x "")
        (enter-debugger conn out f level)))))

(set enter-debugger
  (fn [conn out f level]
    (def denv (make-env (fiber/getenv f)))
    # The dot-commands find their subject through the env they run under.
    (merge-into denv debugger-env)
    (put denv :fiber f)
    (put denv :debug-level level)
    (put denv :signal (fiber/last-value f))
    (put denv *out* out)
    (put denv *err* out)
    # The trace that got us here is sitting in the buffer; it must reach the
    # socket BEFORE the banner, or the debugger appears to open unprovoked.
    (flush-to conn out)
    (:write conn (string "entering debug[" level "] -- (.stack) (.frame n) (.locals), (quit) leaves\n"))
    (repl (socket-chunks conn out (string "debug[" level "]"))
          (make-onsignal conn out denv (+ level 1))
          denv)
    (flush-to conn out)
    (:write conn (string "exiting debug[" level "]\n"))))

(defn attach
  ``Open the debugger on a parked or crashed fiber from a repl connection.

  Callable only at the socket repl -- it talks to the connection the call
  came in on. Takes a `parked` id, an index into `crashed`, or a fiber.``
  [which]
  (def conn (dyn :dev-conn))
  (unless conn (error "attach only works from a dev repl connection"))
  (def f (cond
           (fiber? which) which
           (get-in parked [which :fiber])
           (get-in parked [which :fiber])
           (get crashed which)))
  (unless f (errorf "nothing to attach to under %v" which))
  (enter-debugger conn (dyn :dev-out) f 1))

(defn- connection
  [conn env name]
  (def out @"")
  (def cenv (make-env env))
  # Two routes to the same buffer: evaluated code reads its dynamics from
  # `cenv`, while the repl machinery -- result echo, stacktraces, parse
  # errors -- reads them from this fiber.
  (put cenv *out* out)
  (put cenv *err* out)
  (put cenv :dev-conn conn)
  (put cenv :dev-out out)
  (setdyn *out* out)
  (setdyn *err* out)
  (defer (:close conn)
    (try
      (do
        (:write conn (string "the server's own image. (quit) or ctrl-d leaves; the server stays.\n"
                             "equipment: (dev/stats) op timings both sides · (dev/dump) capture the session\n"
                             "           (dev/replay path) run a capture through the emulator · (dev/reload name)\n"
                             "           (dev/attach n) open a crashed/parked request · dev/crashed dev/parked\n"))
        (repl (socket-chunks conn out name) (make-onsignal conn out cenv 1) cenv)
        (flush-to conn out))
      # The client vanished mid-write; there is nobody left to tell.
      ([_] nil))))

(defn serve
  ``Host a repl for this process on a unix socket at `path`.

  LOOPBACK IS NOT A BOUNDARY, and this endpoint is more than a graph: it
  evaluates whatever connects. A unix socket rather than a TCP port makes
  the filesystem the gate -- created 0600, unreachable from a browser, and
  invisible to the network entirely. A stale file from a previous run is
  deleted rather than probed: the name is keyed to the project like the
  supervisor's, and the newest server wins it.``
  [path env &opt name]
  (default name "visualize")
  (try (os/rm path) ([_] nil))
  (def server (net/server :unix path))
  (os/chmod path 8r600)
  (ev/go
    (fn []
      (forever
        # The server closing is how this loop is told to stop -- accept then
        # errors (or hands back nothing), and neither is worth a stacktrace.
        (def conn (try (:accept server) ([_] nil)))
        (unless conn (break))
        # Each connection its own fiber and its own scratch env, sharing the
        # program underneath through the proto chain.
        (ev/go (fn [] (connection conn env name))))))
  server)
