(import ./trace)

(import ./parser)
(import ./names)
(import ./parsers/arduino :as arduino)
(import ./parsers/visualize-bash :as bash)
(import ./parsers/clojure :as clojure)
(import ./parsers/css :as css)
(import ./parsers/go :as go)
(import ./parsers/janet :as janet-lang)
(import ./parsers/html :as html)
(import ./parsers/javascript :as javascript)
(import ./parsers/python :as python)
(import ./parsers/swift :as swift)
(import ./parsers/visualize-lang :as visualize-lang)

(def specs

  [arduino/spec bash/spec clojure/spec css/spec go/spec html/spec
   janet-lang/spec javascript/spec python/spec swift/spec
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
                             :spec (find |(parser/claims? $ entry full) specs)})))))

  (walk root "")
  (sorted-by |($ :rel) found)))

(defn- read-one

  [[index job]]

  (def parseable (truthy? (job :spec)))
  (def text (when parseable (try (slurp (job :path)) ([_] nil))))

  (def st (try (os/stat (job :path)) ([_] nil)))
  (def stamp (when st [(st :modified) (st :size)]))
  [index
   (cond

     (not parseable)
     {:rel (job :rel) :stamp stamp}

     (not text)
     {:rel (job :rel) :skipped true}

     true
     (let [found (parser/run (job :spec) text (job :rel))]
       {:rel (job :rel)
        :stamp stamp

        :lang ((job :spec) :name)

        :lines (length (string/split "\n" (string/trimr text "\n")))
        :declares (found :declares)
        :imports (found :imports)
        :refs (found :refs)

        :nodes (found :nodes)
        :edges (found :edges)
        :extension (found :extension)

        :aliases (found :aliases)}))])

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

(defn build

  [parsed]
  (trace/measure "scan-build"
  (def live (filter |(and $ (not ($ :skipped))) parsed))

  (def owners @{})
  (each file live
    (each name (or (file :declares) [])
      (put owners name (array/push (or (owners name) @[]) (file :rel)))))
  (def resolved @{})
  (eachp [name files] owners
    (when (= 1 (length files)) (put resolved name (first files))))

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
    (def leaf (last (string/split "." (names/stem full))))
    (put by-leaf leaf (array/push (or (by-leaf leaf) @[]) full)))
  (def from-leaf @{})
  (eachp [leaf names] by-leaf
    (when (= 1 (length names)) (put from-leaf leaf (first names))))

  (def by-tail @{})
  (each file live
    (def full (node-name (file :rel)))
    (def stem (names/stem full))
    (def parts (string/split "." stem))

    (for i 1 (length parts)
      (def tail (string/join (slice parts i) "."))
      (unless (empty? tail)
        (put by-tail tail (array/push (or (by-tail tail) @[]) full)))))
  (def from-tail @{})
  (eachp [tail names] by-tail
    (when (= 1 (length (distinct names))) (put from-tail tail (first names))))

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

  (defn- own-package? [here target]
    (and (string/has-suffix? ".__init__.py" target)
         (string/has-prefix?
           (string (string/slice target 0 (- (length target)
                                             (length ".__init__.py"))) ".")
           here)))

  (def from-package-exact @{})
  (each file live
    (def full (node-name (file :rel)))
    (def stem (names/stem full))
    (when (string/has-suffix? ".__init__" stem)
      (put from-package-exact
           (string/slice stem 0 (- (length stem) (length ".__init__"))) full)))

  (def importable-by
    {"python" {"py" true}})

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
    (def key (names/stem full))
    (put by-stem key (array/push (or (by-stem key) @[]) full)))
  (def from-stem @{})
  (eachp [key names] by-stem
    (when (= 1 (length names)) (put from-stem key (first names))))

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
  (each file live
    (eachp [name target] (or (file :aliases) {})
      (put aliases name target)))

  (def pairs @{})
  (def externals @{})

  (each file live
    (each [from to] (or (file :edges) [])
      (unless (= from to) (put pairs [from to] true))))
  (each file live
    (def here (node-name (file :rel)))
    (each name (or (file :refs) [])
      (when-let [target (resolved name)]
        (unless (= target (file :rel))
          (put pairs [here (node-name target)] true))))

    (each name (or (file :imports) [])

      (def declared-external (names/external? name))
      (when declared-external
        (put externals name true)
        (unless (= name here) (put pairs [here name] true)))
      (unless declared-external

      (def speculative? (string/has-suffix? "." name))
      (def name (if speculative? (slice name 0 -2) name))
      (def mapped (or (get aliases name) name))

      (defn beside-of [wanted]
        (let [parts (string/split "." (names/stem (node-name (file :rel))))]

          (def floor
            (do
              (var d (- (length parts) 1))
              (while (and (> d 1)
                          (from-package (string/join (slice parts 0 d) ".")))
                (-- d))

              (max 1 (- d 1))))
          (var found nil)
          (var depth (- (length parts) 1))
          (while (and (nil? found) (>= depth floor) (> depth 0))
            (def candidate (string (string/join (slice parts 0 depth) ".")
                                   "." wanted))

            (defn ok [t] (and t (importable? (file :lang) t) t))
            (set found (or (ok (from-stem candidate))
                           (ok (and (ours candidate) candidate))

                           (and (not speculative?)
                                (ok (from-package-exact candidate)))))
            (-- depth))
          found))
      (def beside (beside-of mapped))

      (defn ok [t] (and t (importable? (file :lang) t) t))
      (def target (or (ok (from-stem mapped))
                      (ok (and (ours mapped) mapped))
                      beside

                      (ok (if speculative?
                            (from-package-exact mapped)
                            (from-package mapped)))
                      (when (not speculative?)
                        (or

                          (ok (from-tail mapped))

                          (ok (from-leaf (last (string/split "." mapped))))))))
      (cond
        target (unless (or (= target here) (own-package? here target))
                 (put pairs [here target] true))

        speculative? nil

        (pruned? mapped) nil

        (or (empty? mapped)
            (string/has-prefix? (string mapped ".") here)) nil

        (let [parts (string/split "." name)
              prefix (string/join (slice parts 0 -2) ".")]
          (and (> (length parts) 1)
               (not (empty? prefix))
               (or (from-stem prefix)
                   (and (ours prefix) prefix)
                   (beside-of prefix)
                   (from-tail prefix)
                   (from-package prefix))))
        nil

        (do (put externals (names/external name) true)
            (unless (= name here)
              (put pairs [here (names/external name)] true)))))))

  (def nodes @[])
  (each file live
    (if (describes? file)

      (each name (declared file)
        (def rows (string/join (string/split "." name) ".\n"))
        (def ext (file :extension))
        (array/push nodes {:name name
                           :label (if ext (string rows "\n." ext) rows)
                           :ours true}))
      (array/push nodes {:name (node-name (file :rel))
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

  [root &opt yield? extra-skips]
  (trace/measure "scan-fingerprint"
  (def entries @[])
  (var since 0)
  (each job (find-files root extra-skips)
    (def stats (os/stat (job :path)))
    (when stats
      (array/push entries [(job :rel) (stats :modified) (stats :size)
                           (stats :changed) (stats :inode)]))
    (when yield?
      (++ since)
      (when (>= since 200) (set since 0) (ev/sleep 0))))
  (tuple ;(sorted entries))))

(defn watch

  [root changed &opt every skips-of]
  (default every 0.7)
  (var running true)

  (defn skips [] (if skips-of (skips-of) []))
  (var last (fingerprint root false (skips)))
  (ev/go
    (fn []
      (while running
        (ev/sleep every)
        (when running

          (def now (try (fingerprint root true (skips)) ([_] nil)))
          (when (and now (not= now last))
            (set last now)

            (try (changed) ([err] (eprintf "watch: %s" (string err)))))))))
  (fn [] (set running false)))
