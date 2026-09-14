(import ../../src.server/scan)
(import ./fixtures/parsers :as fixtures)
(import ./harness :as t)

(defn- remove-tree [path]
  (each entry (os/dir path)
    (def child (string path "/" entry))
    (if (= :directory (os/stat child :mode)) (remove-tree child) (os/rm child)))
  (os/rmdir path))

(defn- write-file [root path text]
  (var dir root)
  (each part (slice (string/split "/" path) 0 -2)
    (set dir (string dir "/" part))
    (unless (os/stat dir) (os/mkdir dir)))
  (spit (string root "/" path) text))

(defn- graph-shape [graph]
  {:nodes (sorted (map |($ :name) (graph :nodes)))
   :edges (sorted (graph :edges))})

(def covered @{})

(eachp [index fixture] fixtures/cases
  (t/test (fixture :name)
    (def root (string "/tmp/vz-parser-corpus-" (os/getpid) "-" index))
    (os/mkdir root)
    (defer (remove-tree root)
      (def paths (sorted (filter |(not (index-of $ (or (fixture :ignored) [])))
                                 (keys (fixture :files)))))
      (def expected-edges (sorted (fixture :edges)))
      (def expected-nodes
        (sorted (distinct
          [;(or (fixture :nodes) (map scan/node-name paths))
           ;(filter |(string/has-prefix? "?." $) (mapcat identity expected-edges))])))
      (def expected {:nodes expected-nodes :edges expected-edges})
      (each variant [:lf :crlf :no-final-newline]
        (eachp [path source] (fixture :files)
          (write-file root path
            (case variant
              :crlf (string/replace-all "\n" "\r\n" source)
              :no-final-newline (if (string/has-suffix? "\n" source) (string/slice source 0 -2) source)
              source)))
        (def jobs (scan/find-files root))
        (when (= variant :lf)
          (each job jobs
            (when-let [spec (job :spec)]
              (put covered (spec :name) true)
              (def source (get-in fixture [:files (job :rel)]))
              (def failures @[])
              (for end 0 (+ 1 (length source))
                (each suffix ["" "\\"]
                  (try
                    (let [result (scan/parse spec (string (string/slice source 0 end) suffix) (job :rel))]
                      (unless (or (table? result) (struct? result))
                        (array/push failures [end suffix "parser returned no result"])))
                    ([e] (array/push failures [end suffix (string e)])))))
              (t/is= [] failures (string "every incomplete prefix of " (job :rel) " is safe to scan")))))
        (t/is= paths (map |($ :rel) jobs) (string variant " discovers the exact source files"))
        (def parsed (scan/read-all jobs 1))
        (t/is= expected (graph-shape (scan/build parsed)) (string variant " exact graph"))
        (t/is= expected (graph-shape (scan/build (reverse parsed))) (string variant " independent of file order"))
        (t/is= expected (graph-shape (scan/scan root 4)) (string variant " parallel scan"))
        (eachp [path imports] (or (fixture :imports) {})
          (def file (find |(= ($ :rel) path) parsed))
          (t/is= (sorted imports) (sorted (or (get file :imports) []))
                 (string variant " extracted imports for " path)))))))

(t/test "the project corpus exercises every registered parser"
  (t/is= (sorted (scan/languages)) (sorted (keys covered))))
