# Walking the tree and reading every file, on all the cores there are.
#
# THE LANGUAGES ARE NAMED HERE, and nowhere above. This file imports the
# specs, finds the files they claim, hands each one to a worker thread and
# turns the answers into a graph -- so a caller asks for a graph and gets one
# without ever holding a parser. src/visualize/graph.janet cannot name a
# language, which is the point.
#
# The specs themselves stay data: what a language IS lives in
# `visualize/parsers/`, and how to run one lives in src/visualize/parser.janet.
# Neither of those names a language either. This is the one place that does,
# because finding a file means asking every spec whether it claims one.
#
# WHY THREADS. The scan is the slow half -- reading a few thousand files and
# running three PEGs over each -- and it is embarrassingly parallel: no file's
# parse depends on any other's. Janet's `ev/thread` is a real OS thread, not a
# green one, so this uses every core rather than interleaving on one. The
# post-processing that follows (hiding, grouping, colouring) is milliseconds of
# string work on one core and is not worth splitting.

(import ./parser)
(import ./names)
(import ./parsers/arduino :as arduino)
(import ./parsers/visualize-bash :as bash)
(import ./parsers/css :as css)
(import ./parsers/go :as go)
(import ./parsers/janet :as janet-lang)
(import ./parsers/html :as html)
(import ./parsers/javascript :as javascript)
(import ./parsers/python :as python)
(import ./parsers/swift :as swift)

(def specs
  ``Every language this program can read, in name order.

  A LIST, not a directory scan. This used to be src/parsers.janet: a loader
  that walked the parsers directory at runtime, dofile'd whatever it found,
  unwrapped a `spec` export through two possible shapes, and tolerated a
  broken file by skipping that language -- a plugin system for six files
  that ship in this repo and change when someone edits this line anyway.
  Adding a language is now an import and an entry here, which is the same
  amount of editing the loader was avoiding, minus the machinery.``
  [arduino/spec bash/spec css/spec go/spec html/spec janet-lang/spec
   javascript/spec python/spec swift/spec])

(defn languages
  "Their names, for the startup banner."
  []
  (map |($ :name) specs))

# Directories no scan should ever descend into, whatever the language. A spec
# adds its own via :skip-dirs; these are the ones every project has.
(def skip-dirs
  {".git" true ".hg" true ".svn" true
   "node_modules" true ".venv" true "venv" true
   "__pycache__" true ".build" true "build" true "dist" true
   "DerivedData" true "Pods" true "Carthage" true
   ".next" true ".cache" true "target" true "vendor" true})

(defn- worker-count
  ``How many threads to run.

  `os/cpu-count` is absent on some builds -- including the Homebrew one this
  was developed against -- so the count is asked for politely and falls back
  to a number that is wrong on nobody's machine in a way that matters. Too
  many threads costs a little context switching; too few costs wall time.``
  []
  (def reported (when (dyn 'os/cpu-count) (os/cpu-count)))
  (max 1 (min 32 (or reported 8))))

(defn find-files
  ``EVERY file under `root`, each with the spec that claims it or nil.

  Returns [{:path absolute :rel repo-relative :spec spec-or-nil} ...] sorted
  by relative path -- sorted because the DOT is generated in this order and
  an unstable one would reshuffle the layout between runs for no reason.

  THE TREE COMES FIRST, AND IT IS NOT THE PARSEABLE SET. This used to keep
  only files a spec claimed, which quietly made "what files are there" mean
  "what can we parse" -- and everything downstream inherited that. A .ttf
  next to the stylesheet that names it was not a file as far as the scan was
  concerned, so the stylesheet's `url(/Parkinsans-Bold.ttf)` matched nothing
  in the tree, fell through to the external branch, and was named from the
  raw specifier: `Parkinsans-Bold.ttf`, bare at the top level, extension
  intact, while every one of its siblings wore `src.web.`. The asset was
  right there on disk the whole time.

  So the walk reports what is on disk and NOTHING ELSE decides. A file with
  no spec is still a file: it becomes a node, it can be depended upon, and
  it is named by exactly the rule its neighbours are named by. What a spec
  changes is whether the file is READ, which is a separate question asked
  later (see `read-all`).

  Directories are pruned as they are met rather than filtered afterwards, so
  a node_modules with fifty thousand files in it costs one `stat` instead of
  fifty thousand.``
  [root]
  (def found @[])
  # Each spec's own skips, merged with the global set once rather than per
  # directory.
  (def skips (merge @{} skip-dirs))
  (each spec specs
    (each dir (or (spec :skip-dirs) []) (put skips dir true)))

  (defn walk [dir rel]
    (each entry (try (os/dir dir) ([_] []))
      (def full (string dir "/" entry))
      (def here (if (empty? rel) entry (string rel "/" entry)))
      (case (os/stat full :mode)
        :directory (unless (or (skips entry) (string/has-prefix? "." entry))
                     (walk full here))
        # A DOTFILE IS NOT A NODE. Hidden directories are pruned above and
        # hidden files are skipped here, for the same reason: `.gitignore`
        # and `.DS_Store` are not what anyone is drawing.
        #
        # `full` as well as the name, so a spec can look at a shebang when
        # the name gives it nothing -- see parser/claims?. No spec is not an
        # error; it is a file this program cannot read, which is most of
        # them and fine.
        :file (unless (string/has-prefix? "." entry)
                (array/push found
                            {:path full :rel here
                             :spec (find |(parser/claims? $ entry full) specs)})))))

  (walk root "")
  (sorted-by |($ :rel) found))

# What one thread does. Defined at the top level and taking only strings,
# because a thread gets a COPY of the function and its arguments -- a closure
# over the parser spec would be copied per file, and a PEG compiled here would
# be recompiled per file. So the worker receives the spec as plain data and
# `parser/run` compiles the patterns on the far side, once per file. That is
# the cost of the threading model and it is still far cheaper than the IO.
(defn- read-one
  ``Read and parse a single file. Runs on a worker thread.

  Takes [index job] and returns [index result], so a result that arrives out
  of order still knows which file it belongs to.``
  [[index job]]
  # A FILE WITH NO SPEC IS NOT READ. It is still a file -- it gets a node and
  # a stamp below -- but nothing here can parse it, and slurping a 434KB wasm
  # to count its "lines" would be work spent on an answer that means nothing.
  # Its size is left nil, which is what `sizes` already omits.
  (def parseable (truthy? (job :spec)))
  (def text (when parseable (try (slurp (job :path)) ([_] nil))))
  # WHAT THE FILE LOOKED LIKE WHEN IT WAS READ, so a redraw can tell which
  # files moved since the one before it -- see `animate` in the config
  # language. Taken on the worker beside the read, because that is where the
  # file is already being touched.
  #
  # MTIME AND SIZE TOGETHER, not mtime alone. `os/stat :modified` counts
  # whole seconds, and the case animate exists for -- save a file, the
  # watcher redraws a moment later -- happens well inside one. An edit that
  # changes the length is caught by the size even when the clock has not
  # moved; one that changes the same second AND keeps the length exactly is
  # the pair this cannot see, and that is a narrow enough miss to accept.
  (def st (try (os/stat (job :path)) ([_] nil)))
  (def stamp (when st [(st :modified) (st :size)]))
  [index
   (cond
     # AN UNPARSEABLE FILE IS STILL PRESENT. No spec claims it, so it has no
     # imports and declares nothing -- but it exists, and something may well
     # depend on it (a stylesheet on a font, a loader on a wasm). Reported
     # without :skipped so it reaches the graph as a node.
     (not parseable)
     {:rel (job :rel) :stamp stamp}

     # An unreadable file is skipped rather than fatal: a broken symlink or a
     # permissions hole should not take the whole graph down.
     (not text)
     {:rel (job :rel) :skipped true}

     true
     (let [found (parser/run (job :spec) text (job :rel))]
       {:rel (job :rel)
        :stamp stamp
        # Counted the way `wc -l` counts: a trailing newline ends the last
        # line rather than starting an empty one.
        :lines (length (string/split "\n" (string/trimr text "\n")))
        :declares (found :declares)
        :imports (found :imports)
        :refs (found :refs)}))])

(defn read-all
  ``Parse every job, across `workers` OS threads.

  Each thread is given ONE file and its result arrives on a supervisor
  channel as (:ok value task-id). The task-id is the job's index, which is how
  a result finds its way back to the file it came from -- threads finish out
  of order, and nothing else in the message says which file it was.

  A thread that dies takes its file out of the graph and nothing else: the
  message arrives with a status other than :ok, and the file is treated as
  unreadable.``
  [jobs &opt workers]
  (default workers (worker-count))
  (def total (length jobs))
  (if (zero? total)
    @[]
    (do
      (def sup (ev/thread-chan (max 8 total)))
      (def out (array/new-filled total))
      # In flight at once. Bounded rather than spawning one thread per file:
      # a repo with 4000 files would otherwise ask the OS for 4000 threads.
      (def limit (min workers total))
      (var next-job 0)
      (var done 0)

      (defn launch []
        (when (< next-job total)
          (def index next-job)
          (++ next-job)
          # :n returns immediately rather than suspending us until the thread
          # is done -- without it this loop would be sequential.
          #
          # The index travels INSIDE the value and comes back inside the
          # result, rather than as a task-id: `ev/thread` takes one value
          # argument, and threads finish out of order, so the answer has to
          # carry its own return address.
          (ev/thread read-one [index (jobs index)] :n sup)))

      (repeat limit (launch))
      (while (< done total)
        (def message (ev/take sup))
        (++ done)
        # (:ok value) on success; anything else is a thread that died, and its
        # file simply stays nil -- `build` filters those out.
        (when message
          (def [status value] message)
          (when (and (= status :ok) (indexed? value))
            (put out (value 0) (value 1))))
        (launch))
      out)))

# THE NAMING RULES LIVE IN names.janet now, because the parsers need them
# too and cannot import this file -- this one imports them. Re-exported here
# so the many callers that already say `scan/node-name` keep working, and so
# there is still one obvious place to look.
(def resolve-relative names/resolve-relative)
(def safe-name names/safe-name)
(def node-name names/node-name)

(defn node-label
  ``A file's label, wrapped a segment per line.

  A REAL NEWLINE, where this used to emit the two characters `\` and `n` --
  graphviz's own line break inside a quoted label. v strings decode their
  escapes when they parse, so a label arrives at the renderer carrying actual
  newlines and the renderer splits on them (see layout/svg.janet). The
  DOTS, MATCHING THE NODE NAME. The label used to show the path with its
  slashes while the node answered to something else entirely; now both are
  the dotted form, so what you read is what you type into the config.

  THE EXTENSION IS ITS OWN ROW, marked with a leading dot so the renderer
  can spot it and set it small -- the same size as the line count, since it
  is the same kind of thing: a fact about the file rather than part of what
  the file is called. It has to be SHOWN because it is now part of the node
  name (see names.janet), and it has to be QUIET because a column of `.janet`
  repeated forty times is noise on every box.``
  [rel]
  (def cut (names/stem rel))
  (def ext (names/extension rel))
  (def name (string/join (string/split "/" cut) ".\n"))
  (if ext (string name "\n." ext) name))

(defn build
  ``Turn parsed files into a graph: nodes, edges, and each file's size.

  Returns {:nodes [...] :edges [...] :sizes {...} :stamps {...} :ours {...}}.

  TWO KINDS OF EDGE, because languages come in two kinds. Where a parser
  reported :imports, the import IS the dependency and becomes an edge to a
  node named for the module. Where it reported :declares and :refs, a file
  depends on another when it MENTIONS a name that one declares.

  Three rules shape the result, and each exists because breaking it drew a
  wrong picture:

  - A file never depends on itself. Every file mentions its own types
    constantly and a self-loop says nothing.
  - A name declared by SEVERAL files is dropped, not resolved. `ContentView`
    declared in two directories cannot be attributed without a type checker;
    guessing draws a confident edge that is wrong half the time. Losing an
    edge says nothing false.
  - AN ARROW MEANS "DEPENDS ON". `A -> B` is A needing B, so the arrowhead
    lands on the thing being depended upon and dependents sit above their
    dependencies.

  - A FILE NO PARSER CLAIMS IS STILL A FILE. Fonts, wasm, images and docs
    get nodes like anything else; what they do not get is imports, since
    nothing here can read them. This is what lets a stylesheet depend on the
    font sitting beside it instead of on an invented external.``
  [parsed]
  (def live (filter |(and $ (not ($ :skipped))) parsed))

  # Which file declares each name. A list, not a single owner, so ambiguity
  # can be recognised rather than silently resolved to whoever was read first.
  (def owners @{})
  (each file live
    (each name (or (file :declares) [])
      (put owners name (array/push (or (owners name) @[]) (file :rel)))))
  (def resolved @{})
  (eachp [name files] owners
    (when (= 1 (length files)) (put resolved name (first files))))

  (def ours @{})
  (each file live (put ours (node-name (file :rel)) true))

  # WHAT AN IMPORT'S SPELLING MEANS. A node name keeps its extension so that
  # `visualize` and `visualize.conf` stay two nodes -- but an import rarely
  # writes one: `./store` means store.js, `(import ./color)` means
  # color.janet. So parsers answer with the STEM (see names.janet) and this
  # is what joins a stem to the file it names.
  #
  # AMBIGUITY IS DROPPED RATHER THAN GUESSED, the same rule `resolved` uses
  # for declared names just above. `external-src/janet/janet.c` and
  # `janet.h` share the stem `external-src.janet.janet`, and nothing in an
  # import that says only `janet` can choose between them -- so that stem
  # resolves to nothing and the reference stays an external rather than
  # picking whichever file was read first. Losing an edge says nothing
  # false; inventing one does.
  (def by-stem @{})
  (each file live
    (def full (node-name (file :rel)))
    (def key (names/stem full))
    (put by-stem key (array/push (or (by-stem key) @[]) full)))
  (def from-stem @{})
  (eachp [key names] by-stem
    (when (= 1 (length names)) (put from-stem key (first names))))

  (def sizes @{})
  (each file live (put sizes (node-name (file :rel)) (file :lines)))

  # Modification times, keyed like the sizes. What `animate` compares.
  (def stamps @{})
  (each file live (put stamps (node-name (file :rel)) (file :stamp)))

  # Collected as (user, used) -- the direction the scan discovers, since it
  # walks a file and asks what that file needs -- then flipped once at the end.
  # One flip in one place beats every reader having to remember.
  (def pairs @{})
  (def externals @{})
  (each file live
    (def here (node-name (file :rel)))
    (each name (or (file :refs) [])
      (when-let [target (resolved name)]
        (unless (= target (file :rel))
          (put pairs [here (node-name target)] true))))
    # AN IMPORT IS ALREADY A NODE NAME. The parser converted it -- each one
    # knows its own language, so the Janet spec resolved `./term/client`
    # against this file's directory and the Python spec left `otto.store`
    # alone (see names.janet and the :imports-are contract in parser.janet).
    # Nothing here inspects the string.
    #
    # WHAT THIS REPLACES was a guess: no leading dot meant "dotted module",
    # so every dot became a path separator. A path whose file had an
    # extension -- `external-src/janet/janet.c`, which the build script
    # really does name -- came out as `external-src/janet/janet/c`, matched
    # nothing, and was invented as an external wearing its extension beside
    # the real file it had failed to find. Two kinds of string, one rule,
    # and no way to tell from here which kind had arrived.
    (each name (or (file :imports) [])
      # A stem the tree can place becomes that file; a name that IS a node
      # (an import that wrote the extension) is taken as it stands.
      (def target (or (from-stem name) (and (ours name) name)))
      (cond
        target (unless (= target here) (put pairs [here target] true))
        # Anything else is a genuine external -- `fmt`, `Foundation`,
        # `@wterm/core` -- and becomes a node so it can be grouped and
        # hidden like any other.
        (do (put externals name true)
            (unless (= name here) (put pairs [here name] true))))))

  (def nodes @[])
  (each file live
    (array/push nodes {:name (node-name (file :rel))
                       :label (node-label (file :rel))
                       :ours true}))
  # Externals after our own files, so the generated DOT reads ours-then-theirs.
  (each name (sorted (keys externals))
    (array/push nodes {:name name :label name :ours false}))

  # `user -> used`: an arrow reads "a depends on b", and the arrowhead lands
  # on the thing being depended ON. That is the direction the pairs are
  # collected in -- [here internal], the importing file first -- so they are
  # taken as they are.
  #
  # THIS USED TO BE REVERSED, drawing `used -> user` so that arrows pointed
  # along the direction a change propagates: touch a file and the arrowheads
  # showed you who finds out. Both readings are defensible and the graph is
  # the same graph either way; this one matches how the dependency is spoken
  # aloud, which is what the arrow is asked to mean most often.
  #
  # Sorted, so the DOT is ordered by the names as written rather than by
  # collection order.
  (def edges (sorted (keys pairs)))

  {:nodes nodes :edges edges :sizes sizes :stamps stamps :ours ours})

(defn scan
  ``Find, read and graph everything under `root`. The whole pipeline.

  A ROOT WITH NOTHING IN IT IS NOT AN ERROR. It used to answer with one --
  "no files matched any parser", and the list of them -- which put a
  paragraph of text on the screen at the one moment there is nothing to say.
  A directory this tool has no parser for is a blank drawing, the same as a
  directory whose every node the config hid: the picture is what the picture
  is, and an empty one draws empty.

  `build` handles the empty file list on its own -- no nodes, no edges -- and
  graphviz draws an empty graph without complaint, so nothing here has to
  special-case it. What remains of :error is real render failures, which is
  what that channel is for.``
  [root &opt workers]
  (build (read-all (find-files root) workers)))

# -- watching ---------------------------------------------------------------
#
# Noticing that the source changed, so nobody has to press a button.
#
# HERE BECAUSE IT IS THE SAME FILE LIST. The fingerprint below walks exactly
# what `find-files` walks and sums a stat per file -- it is the cheap half of
# a scan, asking "has any of this moved" instead of "what does it say". A
# module of its own would have imported this one to ask.
#
# THE BUTTON THIS REPLACES. "Regenerate" existed because the scan is held
# somewhere and something had to say when it was stale -- which made the
# person responsible for knowing that they had just edited a file, and made
# the graph wrong until they remembered. A tool for seeing a codebase should
# not need to be told the codebase changed.
#
# BY MTIME, NOT BY EVENT. No kqueue, no FSEvents, no inotify: those are three
# platform APIs behind an FFI this project would then own forever, and the
# question they answer -- "did anything change?" -- is answered well enough
# by walking the file list and comparing modification times. The walk is a
# stat per file, and the skip rules keep node_modules to one stat.
#
# ON THE EVENT LOOP, in an ordinary fiber. The walk is stat-bound and short;
# a thread would mean copying the spec list per tick and marshalling results
# back for no gain.

# THE CONFIG IS IN THE LIST, and that is on purpose: it is a file in the tree
# and this walk reports the tree. It used to be absent by accident -- no
# parser claimed `.conf`, back when the walk kept only files a parser claimed
# -- and the accident was load-bearing, because a config write moves its
# mtime and the fingerprint cannot tell that from someone editing it. That
# closed a loop twice: the page saves, the watcher announces a changed
# source, the page redraws, its panes re-register in the file, and it saves
# again.
#
# What broke the loop is that a write which changes nothing no longer
# happens -- see `write-config` in config.janet, which compares before it
# spits. The file stays visible here, an edit to it still redraws, and the
# writes that carried no news no longer pretend to.

(defn fingerprint
  ``One number standing for the state of the tree: every file's mtime and
  size, summed with its path. Different content, different number -- and
  the same number for a tree nobody has touched, which is the common case
  and the one that has to be cheap.

  Size as well as mtime because a filesystem's mtime granularity is a
  second on some systems, and an edit that lands within the same second as
  the last one would otherwise look like nothing happened.``
  [root]
  (var sum 0)
  (var count 0)
  (each job (find-files root)
    (def stats (os/stat (job :path)))
    (when stats
      (++ count)
      # The path contributes too, so a rename with identical timestamps is
      # still a change.
      (+= sum (+ (get stats :modified 0)
                 (get stats :size 0)
                 (length (job :rel)))))
  )
  [sum count])

(defn watch
  ``Watch `root` and call `changed` when the source has moved.

  Returns a function that stops the watch. `every` is the poll interval in
  seconds; the default is a compromise between noticing an edit quickly and
  not walking the tree constantly.

  The first fingerprint is taken WITHOUT firing: the tree existing is not a
  change, and a page that just loaded should not immediately be told to
  redraw what it is already showing.``
  [root changed &opt every]
  (default every 0.7)
  (var running true)
  (var last (fingerprint root))
  (ev/go
    (fn []
      (while running
        (ev/sleep every)
        (when running
          (def now (try (fingerprint root) ([_] nil)))
          (when (and now (not= now last))
            (set last now)
            # A failure in the callback must not end the watch: the next
            # edit deserves the same chance as this one.
            (try (changed) ([err] (eprintf "watch: %s" (string err)))))))))
  (fn [] (set running false)))
