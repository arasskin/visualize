(import ./trace)

(import ./names)
(import ./parsers/arduino :as arduino)
(import ./parsers/shell)
(import ./parsers/c :as c)
(import ./parsers/clojure :as clojure)
(import ./parsers/css :as css)
(import ./parsers/go :as go)
(import ./parsers/janet :as janet-lang)
(import ./parsers/html :as html)
(import ./parsers/javascript :as javascript)
(import ./parsers/python :as python)
(import ./parsers/swift :as swift)
(import ./parsers/visualize-lang :as visualize-lang)

(defn- name-imports

  [spec found path]
  (when (empty? found) (break found))
  (case (spec :imports-are)
    :paths   (map |(names/from-path (or path "") $) found)
    :modules (map |(names/from-module $) found)
    (errorf "parser spec '%s' has :imports but no :imports-are"
            (or (spec :name) "?"))))

(defn- captures

  [pattern text &opt skip]
  (if-not pattern
    @[]
    (distinct (or (peg/match (if skip ~(any (+ ,pattern (drop ,skip) 1))
                                      ~(any (+ ,pattern 1))) text) @[]))))

(defn blank-noise

  [pattern text]
  (if-not pattern
    text
    (do

      (def out (buffer/new (length text)))
      (def scan (peg/compile ~(any (+ (/ (capture ,pattern) ,|(string/repeat " " (length $)))
                                      (capture 1)))))
      (each piece (or (peg/match scan text) @[])
        (buffer/push-string out piece))
      (string out))))

(defn parse

  [spec text &opt path]
  (def text (string/replace-all "\r\n" "\n" text))
  (if-let [custom (spec :parse)]
    (custom text path)
    (let [

          clean (blank-noise (spec :noise) text)]
      {:declares (captures (spec :declares) clean)

       :imports (name-imports spec (captures (spec :imports) text (spec :noise)) path)
       :refs (distinct [;(captures (spec :refs) clean)
                        ;(captures (spec :literal-refs) text (spec :noise))])})))

(defn- first-line

  [path]
  (when-let [f (try (file/open path :rb) ([_] nil))]
    (def head (try (file/read f 128) ([_] nil)))
    (file/close f)
    (when head
      (def text (string head))
      (def stop (string/find "\n" text))
      (if stop (string/slice text 0 stop) text))))

(defn claims?

  [spec path &opt full]
  (cond
    (some |(string/has-suffix? $ path) (spec :ext)) true
    (or (nil? full) (string/find "." path)) false
    (do
      (def marks (spec :shebang))
      (def line (and marks (first-line full)))
      (truthy? (and line
                    (string/has-prefix? "#!" line)
                    (some |(string/find $ line) marks))))))

(def specs

  [arduino/spec shell/spec c/spec clojure/spec css/spec go/spec html/spec
   janet-lang/spec javascript/spec (python/spec blank-noise) swift/spec
   visualize-lang/spec])

(defn languages

  []
  (map |($ :name) specs))

(def skip-dirs
  {".git" true ".hg" true ".svn" true
   "node_modules" true ".venv" true "venv" true
   "__pycache__" true ".build" true "build" true "dist" true
   "DerivedData" true "Pods" true "Carthage" true
   ".next" true ".cache" true "target" true "vendor" true})

(defn- worker-count

  []
  (def reported (when (dyn 'os/cpu-count) (os/cpu-count)))
  (max 1 (min 32 (or reported 8))))

(defn pruned-dirs

  [&opt extra-skips]
  (def skips (merge @{} skip-dirs))
  (each spec specs
    (each dir (or (spec :skip-dirs) []) (put skips dir true)))
  (each dir (or extra-skips []) (put skips dir true))
  skips)

(defn find-files

  [root &opt extra-skips]
  (trace/measure "scan-find-files"
  (def found @[])

  (def skips (pruned-dirs extra-skips))

  (defn walk [dir rel]
    (each entry (try (os/dir dir) ([_] []))
      (def full (string dir "/" entry))
      (def here (if (empty? rel) entry (string rel "/" entry)))
      (case (os/stat full :mode)
        :directory (unless (or (skips entry) (string/has-prefix? "." entry))
                     (walk full here))

        :file (unless (string/has-prefix? "." entry)
                (array/push found
                            {:path full :rel here
                             :spec (find |(claims? $ entry full) specs)})))))

  (walk root "")
  (sorted-by |($ :rel) found)))

(defn- text-lines [text]
  (+ (length (string/find-all "\n" text))
     (if (or (empty? text) (string/has-suffix? "\n" text)) 0 1)))

(defn- count-lines [path]
  (try (do
    (def f (file/open path :rb))
    (defer (file/close f)
      (var lines 0)
      (var tail 0)
      (var binary false)
      (var chunk nil)
      (while (and (not binary) (set chunk (file/read f 65536)))
        (if (peg/find '(range "\x00\x08" "\x0e\x1f") chunk)
          (set binary true)
          (do
            (+= lines (length (string/find-all "\n" chunk)))
            (set tail (if (string/has-suffix? "\n" chunk) 0 1)))))
      (unless binary (+ lines tail))))
    ([_] nil)))

(defn- read-one

  [[index job]]

  (def parseable (truthy? (job :spec)))
  (def text (when parseable (try (slurp (job :path)) ([_] nil))))

  (def st (try (os/stat (job :path)) ([_] nil)))
  (def stamp (when st [(st :modified) (st :size)]))
  [index
   (cond

     (not parseable)
     {:rel (job :rel) :stamp stamp :lines (count-lines (job :path))}

     (not text)
     {:rel (job :rel) :skipped true}

     true
     (let [found (parse (job :spec) text (job :rel))]
       {:rel (job :rel)
        :stamp stamp

        :lang ((job :spec) :name)

        :lines (text-lines text)
        :declares (found :declares)
        :imports (found :imports)
        :import-members (found :import-members)
        :refs (found :refs)

        :nodes (found :nodes)
        :edges (found :edges)
        :headings (found :headings)
        :dependencies (found :dependencies)
        :extension (found :extension)

        :aliases (found :aliases)
        :assets (found :assets)
        :asset-aliases (found :asset-aliases)}))])

(defn read-all

  [jobs &opt workers]
  (trace/measure "scan-read-all"
  (default workers (worker-count))
  (def total (length jobs))
  (if (zero? total)
    @[]
    (do
      (def sup (ev/thread-chan (max 8 total)))
      (def out (array/new-filled total))

      (def limit (min workers total))
      (var next-job 0)
      (var done 0)

      (defn launch []
        (when (< next-job total)
          (def index next-job)
          (++ next-job)

          (ev/thread read-one [index (jobs index)] :n sup)))

      (repeat limit (launch))
      (while (< done total)
        (def message (ev/take sup))
        (++ done)

        (when message
          (def [status value] message)
          (when (and (= status :ok) (indexed? value))
            (put out (value 0) (value 1))))
        (launch))
      out))))

(def resolve-relative names/resolve-relative)
(def safe-name names/safe-name)
(def node-name names/node-name)

(defn node-label

  [rel]
  (def cut (names/stem rel))
  (def ext (names/extension rel))
  (def name (string/join (string/split "/" cut) ".\n"))
  (if ext (string name "\n." ext) name))

(defn- unique-index [candidates &opt deduplicate]
  (def out @{})
  (eachp [key values] candidates
    (def values (if deduplicate (distinct values) values))
    (when (= 1 (length values)) (put out key (first values))))
  out)

(defn- nearby-owner [path candidates]
  (when (empty? candidates) (break nil))
  (def parts (string/split "/" path))
  (var level (dec (length parts)))
  (var target nil)
  (while (>= level 0)
    (def prefix (if (zero? level) "" (string (string/join (slice parts 0 level) "/") "/")))
    (def local (filter |(string/has-prefix? prefix $) candidates))
    (def direct (filter |(not (string/find "/" (string/slice $ (length prefix)))) local))
    (def local (if (empty? direct) local direct))
    (unless (empty? local)
      (when (= 1 (length local)) (set target (first local)))
      (break))
    (-- level))
  target)

(defn- link-project-files [file files]
  (if (nil? (file :dependencies))
    file
    (do
      (def local (tabseq [name :in (file :headings)] name true))
      (def kept (merge @{} local))
      (def edges @[])
      (each [from fallback path] (file :dependencies)
        (def target (if (local fallback) fallback (or (files path) fallback)))
        (when (= target fallback) (put kept fallback true))
        (unless (= from target) (array/push edges [from target])))
      (merge file {:nodes (filter |(kept $) (file :nodes)) :edges edges}))))

(defn build

  [parsed]
  (trace/measure "scan-build"
  (def live (filter |(and $ (not ($ :skipped))) parsed))
  (def files (tabseq [file :in live :when (empty? (or (file :nodes) []))]
                    (file :rel) (node-name (file :rel))))
  (def live (map |(link-project-files $ files) live))

  (def owners @{})
  (def swift-owners @{})
  (each file live
    (each name (or (file :declares) [])
      (put owners name (array/push (or (owners name) @[]) (file :rel)))
      (when (= "swift" (file :lang))
        (put swift-owners name (array/push (or (swift-owners name) @[]) (file :rel))))))
  (def resolved (unique-index owners))

  (defn declared [file] (or (file :nodes) []))
  (defn describes? [file] (not (empty? (declared file))))

  (def ours @{})
  (each file live
    (if (describes? file)
      (each name (declared file) (put ours name true))
      (put ours (node-name (file :rel)) true)))

  (def by-leaf @{})
  (each file live
    (def full (node-name (file :rel)))
    (def leaf (last (string/split "." (node-name (names/stem (file :rel))))))
    (put by-leaf leaf (array/push (or (by-leaf leaf) @[]) full)))
  (def from-leaf (unique-index by-leaf))

  (def by-tail @{})
  (each file live
    (def full (node-name (file :rel)))
    (def stem (node-name (names/stem (file :rel))))
    (def parts (string/split "." stem))

    (for i 1 (length parts)
      (def tail (string/join (slice parts i) "."))
      (unless (empty? tail)
        (put by-tail tail (array/push (or (by-tail tail) @[]) full)))))
  (def from-tail (unique-index by-tail true))

  (def by-package @{})
  (each file live
    (def full (node-name (file :rel)))
    (def stem (node-name (names/stem (file :rel))))
    (when (string/has-suffix? ".__init__" stem)
      (def pkg (string/slice stem 0 (- (length stem) (length ".__init__"))))
      (def parts (string/split "." pkg))
      (for i 0 (length parts)
        (def key (string/join (slice parts i) "."))
        (unless (empty? key)
          (put by-package key
               (array/push (or (by-package key) @[]) full))))))
  (def from-package (unique-index by-package true))

  (defn- own-package? [here target]
    (and (string/has-suffix? ".__init__.py" target)
         (string/has-prefix?
           (string (string/slice target 0 (- (length target)
                                             (length ".__init__.py"))) ".")
           here)))

  (def from-package-exact @{})
  (each file live
    (def full (node-name (file :rel)))
    (def stem (node-name (names/stem (file :rel))))
    (when (string/has-suffix? ".__init__" stem)
      (put from-package-exact
           (string/slice stem 0 (- (length stem) (length ".__init__"))) full)))

  (def importable-by
    {"python" {"py" true}
     "janet" {"janet" true "jimage" true "so" true "dll" true}})

  (def pruned (pruned-dirs))
  (defn pruned? [name]
    (var hit false)
    (each part (string/split "." name)

      (when (or (get pruned part) (get pruned (string "." part)))
        (set hit true)))
    hit)

  (defn importable? [lang target]
    (def allowed (get importable-by lang))
    (or (nil? allowed)
        (truthy? (get allowed (names/extension target)))))

  (def by-stem @{})
  (each file live
    (def full (node-name (file :rel)))
    (def key (node-name (names/stem (file :rel))))
    (put by-stem key (array/push (or (by-stem key) @[]) full)))
  (def from-stem (unique-index by-stem))

  (def sizes @{})
  (each file live
    (unless (describes? file)
      (put sizes (node-name (file :rel)) (file :lines))))

  (def stamps @{})
  (each file live
    (if (describes? file)
      (each name (declared file) (put stamps name (file :stamp)))
      (put stamps (node-name (file :rel)) (file :stamp))))

  (def aliases @{})
  (def asset-paths @{})
  (eachp [path node] files
    (def parts (string/split "/" path))
    (for i 0 (length parts)
      (def tail (string/join (slice parts i) "/"))
      (put asset-paths tail (array/push (or (asset-paths tail) @[]) node))))

  (defn asset-target [file url]
    (def rooted (string/has-prefix? "/" url))
    (def path (if rooted (string/slice url 1) url))
    (or (and rooted (files path))
        (files (names/resolve-relative (file :rel) path true))
        (when rooted
          (def candidates (asset-paths path))
          (when (and candidates (= 1 (length candidates))) (first candidates)))))

  (defn asset-external [file url]
    (names/external
      (names/from-path (file :rel)
        (if (string/has-prefix? "/" url)
          (string "./" (string/slice url 1))
          (if (string/has-prefix? "." url) url (string "./" url))))))

  (each file live
    (eachp [name target] (or (file :aliases) {})
      (put aliases name target))
    (eachp [name url] (or (file :asset-aliases) {})
      (put aliases name (or (asset-target file url) (asset-external file url)))))

  (def pairs @{})
  (def externals @{})

  (defn resolve-import [file name]
    (def here (node-name (file :rel)))

    (def name (or (get aliases name) name))
    (when (names/external? name) (break name))

    (def speculative? (string/has-suffix? "." name))
    (def name (if speculative? (slice name 0 -2) name))
    (def mapped (or (get aliases name) name))
    (def python? (= "python" (file :lang)))

    (defn package-target [wanted]
      (if python? (from-package-exact wanted) (from-package wanted)))

    (defn language-target [wanted]
      (when (= "janet" (file :lang))
        (find |(ours $) [(string wanted ".janet")
                        (string wanted ".init.janet")])))

    (defn beside-of [wanted]
      (let [parts (string/split "." (node-name (names/stem (file :rel))))]

        (var floor
          (do
            (var d (- (length parts) 1))
            (while (and (> d 1)
                        (from-package (string/join (slice parts 0 d) ".")))
              (-- d))

            (max 1 (- d 1))))
        (var found nil)
        (var depth (- (length parts) 1))
        (when python?
          (for i 1 (inc depth)
            (when (string/has-suffix? ".__init__.py"
                    (or (from-package-exact (string/join (slice parts 0 i) ".")) ""))
              (set depth (min depth (dec i)))))
          (set floor (min floor depth)))
        (while (and (nil? found) (>= depth floor) (> depth 0))
          (def candidate (string (string/join (slice parts 0 depth) ".")
                                 "." wanted))

          (defn ok [t] (and t (importable? (file :lang) t) t))
          (set found (or (language-target candidate)
                         (ok (from-stem candidate))
                         (ok (and (ours candidate) candidate))

                         (and (or python? (not speculative?))
                              (ok (from-package-exact candidate)))))
          (-- depth))
        found))
    (def beside (beside-of mapped))

    (defn ok [t] (and t (importable? (file :lang) t) t))
    (def target (or (language-target mapped)
                    (ok (from-stem mapped))
                    (ok (and (ours mapped) mapped))
                    beside

                    (ok (if speculative?
                          (from-package-exact mapped)
                          (package-target mapped)))
                    (when (and (not speculative?) (not python?))
                      (or

                        (and (or (not (index-of (file :lang) ["python" "janet"]))
                                 (not (string/find "." mapped)))
                             (ok (from-tail mapped)))
                        (and (or (not (index-of (file :lang) ["python" "janet"]))
                                 (not (string/find "." mapped)))
                             (ok (from-leaf (last (string/split "." mapped)))))))))
    (cond
      target (unless (own-package? here target) target)

      speculative? nil

      (pruned? mapped) nil

      (or (empty? mapped)
          (string/has-prefix? (string mapped ".") here)) nil

      (let [parts (string/split "." name)
            prefix (string/join (slice parts 0 -2) ".")]
        (and (or (not python?) (index-of name (file :import-members)))
             (> (length parts) 1)
             (not (empty? prefix))
             (or (get externals (names/external prefix))
                 (from-stem prefix)
                 (and (ours prefix) prefix)
                 (beside-of prefix)
                 (and (not python?) (from-tail prefix))
                 (package-target prefix))))
      nil

      (names/external name)))

  (each file live
    (each [from to] (or (file :edges) [])
      (unless (= from to) (put pairs [from to] true))))
  (each file live
    (def here (node-name (file :rel)))
    (each url (or (file :assets) [])
      (def found (asset-target file url))
      (def target (or found (asset-external file url)))
      (when (or found (not (pruned? target)))
        (when (names/external? target) (put externals target true))
        (unless (= here target) (put pairs [here target] true))))
    (each name (or (file :refs) [])
      (when-let [target (if (= "swift" (file :lang))
                         (nearby-owner (file :rel) (or (swift-owners name) []))
                         (resolved name))]
        (unless (= target (file :rel))
          (put pairs [here (node-name target)] true))))

    (each name (or (file :imports) [])
      (when-let [target (resolve-import file name)]
        (when (names/external? target) (put externals target true))
        (unless (= here target) (put pairs [here target] true)))))

  (def nodes @[])
  (each file live
    (if (describes? file)

      (each name (declared file)
        (def rows (string/join (string/split "." name) ".\n"))
        (def ext (file :extension))
        (array/push nodes {:name name
                           :file (file :rel)
                           :label (if ext (string rows "\n." ext) rows)
                           :ours true}))
      (array/push nodes {:name (node-name (file :rel))
                         :file (file :rel)
                         :label (node-label (file :rel))
                         :ours true})))

  (each name (sorted (keys externals))
    (array/push nodes {:name name :label name :ours false}))

  (def edges (sorted (keys pairs)))

  {:nodes nodes :edges edges :sizes sizes :stamps stamps :ours ours}))

(defn scan

  [root &opt workers extra-skips]
  (trace/measure "scan-scan"
  (build (read-all (find-files root extra-skips) workers))))

(defn fingerprint

  [root &opt yield? extra-skips excluded]
  (trace/measure "scan-fingerprint"
  (def entries @[])
  (var since 0)
  (each job (find-files root extra-skips)
    (def stats (os/stat (job :path)))
    (when (and stats (not= excluded (job :path)))
      (array/push entries [(job :rel) (stats :modified) (stats :size)
                           (stats :changed) (stats :inode)]))
    (when yield?
      (++ since)
      (when (>= since 200) (set since 0) (ev/sleep 0))))
  (tuple ;(sorted entries))))
