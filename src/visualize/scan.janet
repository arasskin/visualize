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
(import ./parsers/visualize-lang :as visualize-lang)

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
   javascript/spec python/spec swift/spec visualize-lang/spec])

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
  fifty thousand.

  `extra-skips` are further directory names to prune -- what the config has
  hidden, which cannot change a drawing it is not in.``
  [root &opt extra-skips]
  (def found @[])
  # Each spec's own skips, merged with the global set once rather than per
  # directory.
  (def skips (merge @{} skip-dirs))
  (each spec specs
    (each dir (or (spec :skip-dirs) []) (put skips dir true)))
  # WHAT THE DRAWING HAS NO USE FOR. A directory the config hides cannot
  # change the picture, so walking it is work spent to be ignored -- and on
  # a tree where the hidden part is most of the tree, it is most of the
  # work. One project here hides an `archive/` holding 2064 of its 2283
  # files, and paid 58ms a tick to keep noticing that they had not moved.
  #
  # PASSED IN RATHER THAN READ. This module does not know the config
  # language and should not learn it; the caller that owns the config says
  # which top-level names it has hidden. See `scanned` in core.janet.
  (each dir (or extra-skips []) (put skips dir true))

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
        :refs (found :refs)
        # A FILE THAT IS ITSELF A GRAPH names its own nodes and edges rather
        # than being one node. Absent from every ordinary spec, and absent
        # is what keeps them ordinary: see `build`, which only looks when
        # something is there.
        :nodes (found :nodes)
        :edges (found :edges)
        :extension (found :extension)
        # WHAT NAMES THIS FILE DEFINES FOR OTHER FILES. An html page's
        # import map is the only source of these today; it says what
        # `@wterm/dom` resolves to for every module the page loads. Carried
        # through because `build` applies it to the JAVASCRIPT files that
        # use those names, not to the html that declares them.
        :aliases (found :aliases)}))])

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

  # A FILE THAT DESCRIBES A GRAPH stands for the nodes it named, not for
  # itself. `.visualize` files are the case (see parsers/visualize-lang.janet):
  # one file, as many nodes as it writes down. Every other spec reports no
  # `:nodes` and keeps the one-file-one-node rule it always had.
  (defn declared [file] (or (file :nodes) []))
  (defn describes? [file] (not (empty? (declared file))))

  (def ours @{})
  (each file live
    (if (describes? file)
      (each name (declared file) (put ours name true))
      (put ours (node-name (file :rel)) true)))

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
  # WHAT A BARE FILENAME MEANS. The page asks the server for `/wterm-dom.js`
  # and the server looks in more than one directory to answer -- web/ first,
  # then the vendored source (see `static-roots` in core.janet). A parser
  # reading that URL cannot know which one holds it, so it guesses a sibling
  # of the page, and every guess that misses draws a phantom beside the real
  # file. So the last segment is indexed too, and a name that resolves
  # nowhere else is looked up by it.
  #
  # LAST RESORT, AND ONLY WHEN UNAMBIGUOUS: two files sharing a basename
  # resolve to neither, exactly as two files sharing a stem do. A guess that
  # picks one of them would draw a confident edge that is wrong half the
  # time.
  (def by-leaf @{})
  (each file live
    (def full (node-name (file :rel)))
    (def leaf (last (string/split "." (names/stem full))))
    (put by-leaf leaf (array/push (or (by-leaf leaf) @[]) full)))
  (def from-leaf @{})
  (eachp [leaf names] by-leaf
    (when (= 1 (length names)) (put from-leaf leaf (first names))))

  # AN IMPORT IS RELATIVE TO ITS OWN PROJECT, NOT TO THE SCAN ROOT. Point
  # this at a directory of projects and every python import inside one of
  # them is written from that project's root: `otto.retailers._shared` in
  # gaby-stuff/shoppingagent means the file
  # `shoppingagent/otto/retailers/_shared.py`, whose node name carries the
  # `shoppingagent.` the import never mentions.
  #
  # Those names matched nothing and became externals -- a hundred and forty
  # of them here, sitting on the graph beside `os` and `json` and
  # indistinguishable from them until externals started saying so.
  #
  # So a name is also looked up by its TAIL: a file whose node name ends
  # with `.otto.retailers._shared` answers to it. The leaf map above is the
  # same idea for a single segment; this is the whole remainder, which is
  # far more specific and so far less likely to be a coincidence.
  #
  # AMBIGUITY RESOLVES TO NOTHING, the rule every other lookup here follows:
  # two projects that both hold `otto.retailers._shared` cannot be told
  # apart by a name that says neither, so the reference stays external
  # rather than being attributed to whichever was read first.
  (def by-tail @{})
  (each file live
    (def full (node-name (file :rel)))
    (def stem (names/stem full))
    (def parts (string/split "." stem))
    # Every suffix of the path but the whole of it -- the whole is what the
    # exact match above already covers.
    (for i 1 (length parts)
      (def tail (string/join (slice parts i) "."))
      (unless (empty? tail)
        (put by-tail tail (array/push (or (by-tail tail) @[]) full)))))
  (def from-tail @{})
  (eachp [tail names] by-tail
    (when (= 1 (length (distinct names))) (put from-tail tail (first names))))

  # A PACKAGE IS A DIRECTORY, AND ITS FILE IS `__init__.py`. `import
  # otto.texting` names a directory in python, not a module file, and what
  # runs is the `__init__.py` inside it -- so the import matched nothing and
  # drew a node beside the very file it meant.
  #
  # Keyed the same two ways as everything else here: by the whole dotted
  # path, and by every tail of it, because an import inside a subproject is
  # written from that project's root and says nothing about where the
  # project sits. `otto.texting` finds
  # `shoppingagent.otto.texting.__init__.py`.
  #
  # AMBIGUITY RESOLVES TO NOTHING, as everywhere else in this function.
  (def by-package @{})
  (each file live
    (def full (node-name (file :rel)))
    (def stem (names/stem full))
    (when (string/has-suffix? ".__init__" stem)
      (def pkg (string/slice stem 0 (- (length stem) (length ".__init__"))))
      (def parts (string/split "." pkg))
      (for i 0 (length parts)
        (def key (string/join (slice parts i) "."))
        (unless (empty? key)
          (put by-package key
               (array/push (or (by-package key) @[]) full))))))
  (def from-package @{})
  (eachp [key names] by-package
    (when (= 1 (length (distinct names))) (put from-package key (first names))))

  # A FILE'S OWN PACKAGE IS NOT A DEPENDENCY OF IT. Python runs
  # `otto/mcp/__init__.py` before `otto/mcp/core.py`, so the parser reports
  # it and pydeps agrees -- but on a DRAWING it says nothing the picture is
  # not already saying: the two sit in the same box, and every module in a
  # package gets the identical arrow to the box it is drawn inside. Seventy
  # seven of them on shoppingagent, all noise.
  #
  # ONLY THE FILE'S OWN PACKAGE. An edge into a DIFFERENT package's
  # `__init__.py` is a real dependency and stays -- `otto/mcp/core.py`
  # importing `otto.product_reads` crosses from one box to another, which is
  # exactly what the drawing exists to show.
  (defn- own-package? [here target]
    (and (string/has-suffix? ".__init__.py" target)
         (string/has-prefix?
           (string (string/slice target 0 (- (length target)
                                             (length ".__init__.py"))) ".")
           here)))

  # THE SAME MAP WITHOUT THE SUFFIX KEYS: a package under its WHOLE name
  # only. `otto/mcp/__init__.py` is registered above under both `otto.mcp`
  # and the bare `mcp`, so a project holding an `otto/mcp/` answers to a
  # name meaning the installed `mcp` library. That suffix matching is what
  # lets an import written from a subproject's own root resolve, so it stays
  # -- but a name NOBODY WROTE gets the exact key alone. See the note on
  # `speculative?` below.
  (def from-package-exact @{})
  (each file live
    (def full (node-name (file :rel)))
    (def stem (names/stem full))
    (when (string/has-suffix? ".__init__" stem)
      (put from-package-exact
           (string/slice stem 0 (- (length stem) (length ".__init__"))) full)))

  (def by-stem @{})
  (each file live
    (def full (node-name (file :rel)))
    (def key (names/stem full))
    (put by-stem key (array/push (or (by-stem key) @[]) full)))
  (def from-stem @{})
  (eachp [key names] by-stem
    (when (= 1 (length names)) (put from-stem key (first names))))

  # NO LINE COUNT FOR A DECLARED NODE. `auth` is a label in a file, not a
  # file, so it has no length -- and dividing the file's own lines between
  # the nodes it names would be inventing a number. `(lines)` simply says
  # nothing about them, which `sizes` already handles by omission.
  (def sizes @{})
  (each file live
    (unless (describes? file)
      (put sizes (node-name (file :rel)) (file :lines))))

  # Modification times, keyed like the sizes. What `animate` compares.
  # THE FILE'S OWN MTIME, given to every node it names: editing the file is
  # the only way any of them can change, so they all flash together. That is
  # the honest answer -- the change really did arrive as one edit.
  (def stamps @{})
  (each file live
    (if (describes? file)
      (each name (declared file) (put stamps name (file :stamp)))
      (put stamps (node-name (file :rel)) (file :stamp))))

  # Collected as (user, used) -- the direction the scan discovers, since it
  # walks a file and asks what that file needs -- then flipped once at the end.
  # One flip in one place beats every reader having to remember.
  # NAMES A PAGE GAVE TO FILES. An HTML file may carry an import map, which
  # says what `@wterm/dom` means for every module the page loads (see the
  # html spec). Those names appear in JAVASCRIPT files, not in the html that
  # declares them, so the mapping is collected across the whole tree and
  # applied wherever a name matches -- there is one page here and one map,
  # and a project with two would want the same answer anyway.
  (def aliases @{})
  (each file live
    (eachp [name target] (or (file :aliases) {})
      (put aliases name target)))

  (def pairs @{})
  (def externals @{})
  # EDGES A FILE WROTE DOWN ITSELF, both ends already node names -- there is
  # no tree to resolve them against, because the file that named them also
  # named the nodes.
  (each file live
    (each [from to] (or (file :edges) [])
      (unless (= from to) (put pairs [from to] true))))
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
      # An import map turns a package name into a path; the path is then
      # resolved like any other. `@wterm/dom` arrives here as `wterm.dom`,
      # which is the safe-name of the specifier, so the map is keyed both
      # ways.
      # A TRAILING DOT MARKS AN INFERRED NAME. Python's parser reports the
      # packages above each import (`otto` and `otto.mcp` for
      # `otto.mcp.cart`), because importing a submodule runs its parents --
      # but the source never wrote those names, so one that matches no file
      # must not be invented as an external. The mark is a character no
      # module name can contain; it comes off before anything is looked up.
      (def speculative? (string/has-suffix? "." name))
      (def name (if speculative? (slice name 0 -2) name))
      (def mapped (or (get aliases name) name))
      # A SIBLING IS WHERE PYTHON LOOKS FIRST. `import db` in
      # `archive/shoppingagent-mcp/src/main.py` means the `db.py` beside it
      # -- the directory a script runs from is on the path, so a bare name
      # is a same-directory module before it is anything else.
      #
      # And it has to be tried before the global fallbacks, not after: three
      # files in this tree end in `db` (two of them `.db` DATABASES rather
      # than modules), so the by-leaf map calls the name ambiguous and gives
      # up -- while the file sitting next to the importer is not ambiguous
      # at all.
      # THE DIRECTORY A SCRIPT RUNS FROM IS ON PYTHON'S PATH, so `import db`
      # in `src/main.py` means the `db.py` beside it. The walk goes up from
      # the importer, because a package-qualified name is written from the
      # package ROOT: `from otto import db` inside
      # `shoppingagent/otto/store_cart.py` means `shoppingagent/otto/db.py`,
      # which is the name resolved against `shoppingagent/`.
      #
      # IT STOPS AT THE FIRST DIRECTORY THAT IS NOT A PACKAGE, because that
      # is where python stops. PEP 328 removed implicit relative imports in
      # python 3: from inside a package, `import json` is the STDLIB json,
      # never the `json.py` sitting beside it, and only a directory ON
      # sys.path -- a script's own, or a package root -- answers a bare name.
      #
      # WITHOUT THAT STOP the walk climbed out of the package and kept
      # matching: `from mcp.server.fastmcp import FastMCP` in
      # `otto/retailer_onboarding/page_tools_server.py` found the local
      # `otto/mcp/` and drew an edge to it, when the name means the INSTALLED
      # mcp library. A directory holding `__init__.py` is a package, and the
      # first one without it is the root the imports are written against.
      (def beside
        (let [parts (string/split "." (names/stem (node-name (file :rel))))]
          (var found nil)
          (var depth (- (length parts) 1))
          (var climbing true)
          (while (and climbing (nil? found) (> depth 0))
            (def dir (string/join (slice parts 0 depth) "."))
            (def candidate (string dir "." mapped))
            (set found (or (from-stem candidate)
                           (and (ours candidate) candidate)))
            # Having just looked in `dir`, stop if `dir` is not itself a
            # package -- anything above it is not on the path.
            (unless (from-package dir) (set climbing false))
            (-- depth))
          found))
      # AN INFERRED NAME GETS ONLY THE EXACT LOOKUPS. The fallbacks below
      # match a name ANYWHERE in the tree, which is right for a name a file
      # actually wrote -- it was written from some root, and the root is what
      # they recover. It is wrong for a prefix nobody wrote: `from
      # mcp.server.fastmcp import FastMCP` yields the prefix `mcp`, and
      # `from-package` matched the local `otto/mcp/` for it, drawing an edge
      # to this project from a name meaning the INSTALLED mcp library. The
      # leaf `mcp.server.fastmcp` stayed external, as it should, so the graph
      # disagreed with itself about the same import.
      (def target (or (from-stem mapped)
                      (and (ours mapped) mapped)
                      beside
                      # A python package: the directory's __init__.py. An
                      # inferred name gets the EXACT map -- matched on the
                      # whole path, not on a suffix of it -- because a parent
                      # package is what an inferred name usually is, while a
                      # suffix match on one is how `mcp` found `otto/mcp/`.
                      (if speculative?
                        (from-package-exact mapped)
                        (from-package mapped))
                      (when (not speculative?)
                        (or
                          # A name written from a subproject's own root --
                          # see `by-tail` above.
                          (from-tail mapped)
                          # A path that named no file may still name one in
                          # another served directory -- matched on its last
                          # segment. See `by-leaf` above.
                          (from-leaf (last (string/split "." mapped)))))))
      (cond
        target (unless (or (= target here) (own-package? here target))
                 (put pairs [here target] true))

        # A NAME WHOSE OWN PREFIX RESOLVED IS A SYMBOL, NOT A MODULE, and is
        # dropped rather than invented. Python's `from otto.models import
        # Cart` could mean the submodule `otto/models/Cart.py` or the class
        # `Cart` inside `otto/models.py`, and nothing in the syntax says
        # which -- so the parser reports BOTH readings and leaves the choice
        # to whoever can see the files. That is here.
        #
        # `otto.models` resolved to a real file, so `otto.models.Cart` is the
        # class, and a class is not a dependency of its own module. Drawing
        # it made `?.otto.models.FetchFn` a third-party package sitting
        # beside `otto.models.py` itself -- three hundred and sixty externals
        # on shoppingagent, most of them types.
        #
        # ONLY WHEN THE PREFIX RESOLVED. `from typing import cast` leaves
        # `typing` external too, and `?.typing.cast` is no more wrong than
        # `?.typing`; both are outside the tree and neither is checked
        # against files that are not there.
        # An inferred package that named no file: nothing wrote it, so
        # nothing is drawn for it.
        speculative? nil

        (let [parts (string/split "." name)
              prefix (string/join (slice parts 0 -2) ".")]
          (and (> (length parts) 1)
               (not (empty? prefix))
               (or (from-stem prefix)
                   (and (ours prefix) prefix)
                   (from-tail prefix)
                   (from-package prefix))))
        nil

        # Anything else is a genuine external -- `fmt`, `Foundation`,
        # `@wterm/core` -- and becomes a node so it can be grouped and
        # hidden like any other.
        #
        # MARKED AS NOT BEING HERE. An external is a name, not a place:
        # there is no directory behind it and no path to prefix. Saying so
        # in the name is what lets a nested config's `(hide os)` mean the
        # external `os` rather than a file called os under that project --
        # see `nested-lines` in config.janet.
        (do (put externals (names/external name) true)
            (unless (= name here)
              (put pairs [here (names/external name)] true))))))

  (def nodes @[])
  (each file live
    (if (describes? file)
      # LABELLED LIKE A FILE IS, because it reads like one: the dotted name
      # a segment per line, and the file's extension underneath at the small
      # size. The extension is the same for every node the file declared, so
      # the spec reports it once (see parsers/visualize-lang.janet).
      (each name (declared file)
        (def rows (string/join (string/split "." name) ".\n"))
        (def ext (file :extension))
        (array/push nodes {:name name
                           :label (if ext (string rows "\n." ext) rows)
                           :ours true}))
      (array/push nodes {:name (node-name (file :rel))
                         :label (node-label (file :rel))
                         :ours true})))
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
  [root &opt workers extra-skips]
  (build (read-all (find-files root extra-skips) workers)))

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
  the last one would otherwise look like nothing happened.

  `yield?` makes the walk COOPERATIVE, which is what keeps a big tree from
  being felt in the terminal. `os/stat` is synchronous and janet has no
  async filesystem call, so a walk of a few thousand files holds the event
  loop for as long as it takes -- 58ms on a 2283-file tree, every tick,
  while every request waits behind it. Handing the loop back every so often
  turns one long block into many short ones: the walk takes the same total
  time and stops being a stall.

  Off by default, because the walk is also called from places where nothing
  else is waiting and a yield would only add scheduling.``
  [root &opt yield? extra-skips]
  (var sum 0)
  (var count 0)
  (var since 0)
  (each job (find-files root extra-skips)
    (def stats (os/stat (job :path)))
    (when stats
      (++ count)
      # The path contributes too, so a rename with identical timestamps is
      # still a change.
      (+= sum (+ (get stats :modified 0)
                 (get stats :size 0)
                 (length (job :rel)))))
    (when yield?
      (++ since)
      # A few hundred stats is well under a millisecond; yielding per file
      # would cost more in scheduling than the stats themselves.
      (when (>= since 200) (set since 0) (ev/sleep 0))))
  [sum count])

(defn watch
  ``Watch `root` and call `changed` when the source has moved.

  Returns a function that stops the watch. `every` is the poll interval in
  seconds; the default is a compromise between noticing an edit quickly and
  not walking the tree constantly.

  The first fingerprint is taken WITHOUT firing: the tree existing is not a
  change, and a page that just loaded should not immediately be told to
  redraw what it is already showing.``
  [root changed &opt every skips-of]
  (default every 0.7)
  (var running true)
  # `skips-of` is asked EACH TICK rather than once, because what the config
  # hides changes while the program runs -- unhiding a directory has to put
  # it back under watch, or an edit in it would never be noticed.
  (defn skips [] (if skips-of (skips-of) []))
  (var last (fingerprint root false (skips)))
  (ev/go
    (fn []
      (while running
        (ev/sleep every)
        (when running
          # YIELDING, because this is the loop everything else shares.
          (def now (try (fingerprint root true (skips)) ([_] nil)))
          (when (and now (not= now last))
            (set last now)
            # A failure in the callback must not end the watch: the next
            # edit deserves the same chance as this one.
            (try (changed) ([err] (eprintf "watch: %s" (string err)))))))))
  (fn [] (set running false)))
