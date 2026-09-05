(import ../names)

(defn- munge-ns

  [sym]
  (string/replace-all "-" "_" sym))

(defn- lib-name

  [text]
  (var name text)

  (var platform false)
  (when (string/has-prefix? "package:" name)
    (set platform true)
    (set name (string/slice name (length "package:"))))
  (when (string/has-prefix? "dart:" name)
    (set platform true))
  (when (string/has-suffix? ".dart" name)
    (set name (string/slice name 0 (- (length name) (length ".dart")))))
  (def dotted (string/replace-all ":" "." (string/replace-all "/" "." name)))
  (if platform (names/external dotted) dotted))

(defn- ws? [b] (or (= b 32) (= b 9) (= b 10) (= b 13) (= b 44)))
(defn- open? [b] (or (= b 40) (= b 91) (= b 123)))
(defn- close? [b] (or (= b 41) (= b 93) (= b 125)))

(defn- blank-comments

  [text]
  (def out (buffer text))
  (def n (length text))
  (var i 0)
  (var in-string false)
  (while (< i n)
    (def b (get text i))
    (cond
      in-string
      (do (when (= b 92) (++ i))
          (when (= b 34) (set in-string false)))
      (= b 34) (set in-string true)
      (= b 59)
      (while (and (< i n) (not= (get text i) 10))
        (put out i 32)
        (++ i)))
    (++ i))
  (string out))

(defn- read-token

  [text i]
  (def n (length text))
  (var j i)
  (while (and (< j n)
              (not (ws? (get text j)))
              (not (open? (get text j)))
              (not (close? (get text j))))
    (++ j))
  [(string/slice text i j) j])

(defn- skip-form

  [text i]
  (def n (length text))
  (var depth 0)
  (var j i)
  (var in-string false)
  (while (< j n)
    (def b (get text j))
    (cond
      in-string (do (when (= b 92) (++ j))
                    (when (= b 34) (set in-string false)))
      (= b 34) (set in-string true)
      (open? b) (++ depth)
      (close? b) (do (-- depth) (when (zero? depth) (break))))
    (++ j))
  (inc j))

(defn- read-string-at

  [text i]
  (def n (length text))
  (def out @"")
  (var j (inc i))
  (while (< j n)
    (def b (get text j))
    (cond
      (= b 92) (do (++ j) (buffer/push-byte out (get text j)))
      (= b 34) (break)
      (buffer/push-byte out b))
    (++ j))
  [(string out) (inc j)])

(defn- parse [text path]
  (def clean (blank-comments text))
  (def n (length clean))
  (def out @[])

  (each word ["(:require" "(:use"]
    (var from 0)
    (while (def at (string/find word clean from))
      (def end (skip-form clean at))

      (var i (+ at (length word)))
      (while (< i (min end n))
        (def b (get clean i))
        (cond
          (ws? b) (++ i)
          (close? b) (++ i)
          (open? b)
          (do

            (var j (inc i))
            (while (and (< j n) (ws? (get clean j))) (++ j))
            (if (= (get clean j) 34)
              (let [[lib _] (read-string-at clean j)]
                (unless (empty? lib) (array/push out (lib-name lib))))
              (let [[sym _] (read-token clean j)]
                (unless (or (empty? sym) (string/has-prefix? ":" sym))
                  (array/push out (munge-ns sym)))))
            (set i (skip-form clean i)))
          (= b 34)
          (let [[lib j] (read-string-at clean i)]
            (unless (empty? lib) (array/push out (lib-name lib)))
            (set i j))

          (let [[sym j] (read-token clean i)]
            (unless (or (empty? sym) (string/has-prefix? ":" sym))
              (array/push out (munge-ns sym)))
            (set i j))))
      (set from end)))
  {:imports (distinct out)})

(def spec
  {:name "clojure"
   :ext [".cljd" ".clj" ".cljc"]

   :skip-dirs [".cpcache" ".clj-kondo" ".lsp" "target" "cljd-out"]
   :imports-are :modules
   :parse parse})
