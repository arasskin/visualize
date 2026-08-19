# Walking the tree and reading every file, on all the cores there are.
#
# This file names no language either. It finds the files some parser claims,
# hands each one to a worker thread, and turns the answers into a graph. The
# only language-specific things in the process are the specs in `visualize/parsers/`,
# which arrive as data.
#
# WHY THREADS. The scan is the slow half -- reading a few thousand files and
# running three PEGs over each -- and it is embarrassingly parallel: no file's
# parse depends on any other's. Janet's `ev/thread` is a real OS thread, not a
# green one, so this uses every core rather than interleaving on one. The
# post-processing that follows (hiding, grouping, colouring) is milliseconds of
# string work on one core and is not worth splitting.

(import ./parser)

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
  ``Every file under `root` that some spec claims, with the spec that claims it.

  Returns [{:path absolute :rel repo-relative :spec spec} ...] sorted by
  relative path -- sorted because the DOT is generated in this order and an
  unstable one would reshuffle the layout between runs for no reason.

  Directories are pruned as they are met rather than filtered afterwards, so a
  node_modules with fifty thousand files in it costs one `stat` instead of
  fifty thousand.``
  [root specs]
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
        # `full` as well as the name, so a spec can look at a shebang when the
        # name gives it nothing -- see parser/claims?.
        :file (when-let [spec (find |(parser/claims? $ entry full) specs)]
                (array/push found {:path full :rel here :spec spec})))))

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
  (def text (try (slurp (job :path)) ([_] nil)))
  [index
   (if-not text
     # An unreadable file is skipped rather than fatal: a broken symlink or a
     # permissions hole should not take the whole graph down.
     {:rel (job :rel) :skipped true}
     (let [found (parser/run (job :spec) text (job :rel))]
       {:rel (job :rel)
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

(defn resolve-relative
  ``A relative import specifier, resolved against the importing file's path.

  `test/scan.janet` importing `../visualize/color` gives `visualize/color`, which is the
  node the scan already made for that file. Without this the specifier is
  flattened as written and becomes a node nothing else refers to.

  Any extension on the specifier is dropped, since node names carry none.``
  [from-rel module]
  (def parts (string/split "/" from-rel))
  # Start in the importing file's DIRECTORY, hence dropping its own name.
  (def stack (array ;(slice parts 0 (max 0 (- (length parts) 1)))))
  (each piece (string/split "/" module)
    (cond
      (or (= piece ".") (= piece "")) nil
      (= piece "..") (when (> (length stack) 0) (array/pop stack))
      (array/push stack piece)))
  (def joined (string/join stack "/"))
  # Drop a trailing extension the same way `node-name` does, so `./a.js` and
  # `./a` land on the same node.
  (if-let [dot (last (string/find-all "." joined))]
    (if (> dot (or (last (string/find-all "/" joined)) -1))
      (string/slice joined 0 dot)
      joined)
    joined))

(defn safe-name
  ``A path or module specifier as a node name: separators become dots.

  `src/visualize/color.janet` -> `src.visualize.color`, `github.com/lib/pq`
  -> `github.com.lib.pq`, `./store` -> `store`.

  ONE SPELLING EVERYWHERE, which is the point. This used to flatten to
  UNDERSCORES -- `src_visualize_color` -- while the label showed
  `src/visualize/color` and the config was written `src.visualize.color`, so
  a path had three forms and only one of them was ever visible. The dot is
  the one the config already used, it survives a DOT identifier as long as
  the name is quoted (which `layout/to-dot` does), and it is what a reader
  types after seeing the picture.

  Leading and trailing dots are trimmed and runs collapsed, so `./store` and
  `@scope/pkg` do not come back wearing punctuation they never had.

  HYPHENS SURVIVE. A directory called `demo-api` is one name, not two: with
  the hyphen swept into a dot it became `demo.api.worker`, which reads as a
  directory `demo` that does not exist and breaks the prefix a config would
  write. The old underscore flattening had the same bug in reverse (it made
  `demo-api_worker`, which graphviz then rejected) -- quoting the name is
  what lets the hyphen simply stay.``
  [text]
  (def dotted
    (string
      (peg/replace-all ~(if-not (+ (range "AZ") (range "az") (range "09") "_" "-" ".") 1)
                       "." text)))
  # `./store` becomes `..store` on the way through; collapse and trim so the
  # name is the shape the config language expects.
  (var out dotted)
  (while (string/find ".." out)
    (set out (string/replace-all ".." "." out)))
  (string/trim out "."))

(defn node-name
  ``A file's path as its DOT node name.

  `OttoClip/CartWebView.swift` -> `OttoClip_CartWebView`. DOT identifiers
  cannot carry a separator unquoted, so the path is flattened -- the same
  dots-to-underscores shape pydeps produces, which is what lets one config
  language address both.

  THE FLATTENING IS LOSSY and deliberately so: `OttoClip_Cart` could have been
  `OttoClip/Cart.swift` or `OttoClip_Cart.swift`, and nothing in the name says
  which. Everything that needs the real path therefore works FORWARD from the
  file list rather than backward from a node name.``
  [rel]
  (def without-ext
    (if-let [dot (last (string/find-all "." rel))]
      (if (> dot (or (last (string/find-all "/" rel)) -1))
        (string/slice rel 0 dot)
        rel)
      rel))
  (safe-name without-ext))

(defn node-label
  ``A file's label, wrapped a segment per line.

  A REAL NEWLINE, where this used to emit the two characters `\` and `n` --
  graphviz's own line break inside a quoted label. v strings decode their
  escapes when they parse, so a label arrives at the renderer carrying actual
  newlines and the renderer splits on them (see layout/svg.janet). The
  DOTS, MATCHING THE NODE NAME. The label used to show the path with its
  slashes while the node answered to something else entirely; now both are
  the dotted form, so what you read is what you type into the config.``
  [rel]
  (def without-ext
    (if-let [dot (last (string/find-all "." rel))]
      (if (> dot (or (last (string/find-all "/" rel)) -1))
        (string/slice rel 0 dot)
        rel)
      rel))
  (string/join (string/split "/" without-ext) ".\n"))

(defn build
  ``Turn parsed files into a graph: nodes, edges, and each file's size.

  Returns {:nodes [...] :edges [...] :sizes {...} :ours {...}}.

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
  - ARROWS POINT THE DATAFLOW WAY. `A -> B` means B depends on A, so the
    arrowhead lands on the file doing the importing. That is pydeps'
    direction, and matching it means the two graphs can sit side by side. It
    also puts leaves at the top, since dot ranks by edge direction.``
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

  (def sizes @{})
  (each file live (put sizes (node-name (file :rel)) (file :lines)))

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
    (each module (or (file :imports) [])
      # An import naming a file we scanned is an internal edge; anything else
      # is an external, and becomes a node so it can be grouped and hidden
      # like any other.
      #
      # Both names go through `safe-name`, because an import specifier can
      # carry anything a path can -- `github.com/lib/pq`, `./store`,
      # `@scope/pkg` -- and a bare DOT identifier admits none of it.
      (def as-node (safe-name module))
      (def internal
        (if (string/has-prefix? "." module)
          # A RELATIVE import names a file, and which file depends on where
          # the importing file sits. Resolved against that directory rather
          # than flattened, or `../visualize/color` becomes the node `___visualize_color`
          # -- a phantom external that nothing matches, instead of an edge to
          # the visualize/color the project already has.
          (safe-name (resolve-relative (file :rel) module))
          (safe-name (string/replace-all "." "/" module))))
      (cond
        (ours internal) (unless (= internal here) (put pairs [here internal] true))
        (do (put externals as-node true)
            (unless (= as-node here) (put pairs [here as-node] true))))))

  (def nodes @[])
  (each file live
    (array/push nodes {:name (node-name (file :rel))
                       :label (node-label (file :rel))
                       :ours true}))
  # Externals after our own files, so the generated DOT reads ours-then-theirs.
  (each name (sorted (keys externals))
    (array/push nodes {:name name :label name :ours false}))

  # THE FLIP: `used -> user`, so the arrowhead lands on the file that needs
  # the thing. Sorted after reversing, so the DOT is ordered by the names as
  # written rather than by collection order.
  (def edges (sorted (map (fn [pair] [(pair 1) (pair 0)]) (keys pairs))))

  {:nodes nodes :edges edges :sizes sizes :ours ours})

(defn scan
  "Find, read and graph everything under `root`. The whole pipeline."
  [root specs &opt workers]
  (def jobs (find-files root specs))
  (if (empty? jobs)
    {:error (string "no files under " root
                    " matched any parser (" (string/join (map |($ :name) specs) ", ") ")")}
    (build (read-all jobs workers))))
