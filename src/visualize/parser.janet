(import ./names)

(defn- name-imports

  [spec found path]
  (when (empty? found) (break found))
  (case (spec :imports-are)
    :paths   (map |(names/from-path (or path "") $) found)
    :modules (map |(names/from-module $) found)
    (errorf "parser spec '%s' has :imports but no :imports-are"
            (or (spec :name) "?"))))

(defn- captures

  [pattern text]
  (if-not pattern
    @[]
    (distinct (or (peg/match ~(any (+ ,pattern 1)) text) @[]))))

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

(defn run

  [spec text &opt path]
  (if-let [custom (spec :parse)]
    (custom text path)
    (let [

          clean (blank-noise (spec :noise) text)

          importable (blank-noise (or (spec :comments) (spec :noise)) text)]
      {:declares (captures (spec :declares) clean)

       :imports (name-imports spec (captures (spec :imports) importable) path)
       :refs (captures (spec :refs) clean)})))

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
