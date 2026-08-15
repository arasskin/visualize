# What the program knows, on disk, where anything can read it.
#
# THE POINT OF PUTTING IT HERE. Visualize exists so a program can grow its
# own view of itself, and a view is only as reachable as the facts behind
# it. While the scan lived in a var and the faults in a ring, the only way
# to see either was to be inside this process and ask it -- so every new
# view meant a new endpoint, and anything outside (a script, an agent, the
# next run) saw nothing at all.
#
# On disk, the same facts are readable by a page, a shell, an editor, an
# agent with a Read tool, and this process after a restart, without any of
# them agreeing on an API first. That is what makes an interface incidental:
# the state is the contract, and a view is just something that reads files.
#
# ONE DIRECTORY PER PROJECT, beside the config it belongs to, because these
# facts are about that source tree. Named `.visualize/` and gitignorable:
# it is a cache and a log, not something to commit.
#
# JSON, not marshal, for exactly the reason the wire uses it: a person or an
# agent will open these files, and the ability to read one in a terminal is
# worth more than the bytes it costs.

(import ./json)

(defn dir
  "The state directory for `root`, created if it is not there yet."
  [root]
  (def path (string root "/.visualize"))
  (unless (os/stat path :mode)
    (try (os/mkdir path) ([_] nil)))
  path)

(defn path-for
  "Where `name` lives for this project."
  [root name]
  (string (dir root) "/" name))

(defn write
  ``Write `value` as JSON under `name`. Atomic: written to a sibling
  temporary and renamed, so a reader never catches a half-written file --
  a page polling while a scan lands would otherwise parse a truncated
  object and report a broken graph.``
  [root name value]
  (def final (path-for root name))
  (def temp (string final ".tmp"))
  (spit temp (json/encode value))
  (os/rename temp final)
  final)

(defn read
  "Whatever is under `name`, or nil if it is missing or unreadable."
  [root name]
  (def path (path-for root name))
  (when (os/stat path :mode)
    (try (json/decode (slurp path)) ([_] nil))))

(defn append-line
  ``Add one JSON line to `name`, keeping at most `limit` lines.

  A LOG, NOT A DOCUMENT: faults and other events arrive one at a time and
  are read newest-first, so each is its own line and a reader can take the
  tail without parsing the whole file. The rewrite on trim is cheap at
  these sizes and keeps the file bounded without a rotation scheme.``
  [root name entry &opt limit]
  (default limit 200)
  (def path (path-for root name))
  (def existing (if (os/stat path :mode) (string/split "\n" (slurp path)) []))
  (def lines (filter |(not (empty? $)) existing))
  (array/push lines (json/encode entry))
  (def kept (if (> (length lines) limit)
              (slice lines (- (length lines) limit))
              lines))
  (def temp (string path ".tmp"))
  (spit temp (string (string/join kept "\n") "\n"))
  (os/rename temp path)
  nil)

(defn read-lines
  "The last `n` entries of a line log, oldest first."
  [root name &opt n]
  (default n 50)
  (def path (path-for root name))
  (if-not (os/stat path :mode)
    []
    (let [lines (filter |(not (empty? $)) (string/split "\n" (slurp path)))
          from (max 0 (- (length lines) n))]
      (filter (fn [x] (not (nil? x)))
              (map |(try (json/decode $) ([_] nil)) (slice lines from))))))
