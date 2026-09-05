(import ../names)

(def- attr-char '(if-not (+ (set " \t\n\"'<>") -1) 1))
(def- value ~(some ,attr-char))

(def- quoted ~(+ (* `"` (<- ,value) `"`)
                 (* "'" (<- ,value) "'")
                 (<- ,value)))

(def- fetching ~(+ "src" "href" "poster" "data" "srcset"))

(defn- import-map [text]
  (def maps @{})

  (def blocks
    (peg/match ~(any (+ (* "<script" (<- (any (if-not ">" 1))) ">"
                           (<- (any (if-not "</script" 1))))
                        1))
               text))
  (each [attrs block] (partition 2 (or blocks []))
    (when (string/find "importmap" (string/ascii-lower attrs))
    (each [name target]
      (partition 2 (or (peg/match
                         ~(any (+ (* `"` (<- (some (if-not `"` 1))) `"`
                                     (any (set " \t\n")) ":" (any (set " \t\n"))
                                     `"` (<- (some (if-not `"` 1))) `"`)
                                  1))
                         block) []))

      (unless (or (string/has-suffix? "/" name) (string/has-suffix? "/" target))
        (put maps name target)))))
  maps)

(defn- site-path [url]
  (def clean (first (string/split "?" (first (string/split "#" url)))))
  (cond
    (empty? clean) clean
    (string/has-prefix? "/" clean) (string "./" (string/slice clean 1))
    (string/has-prefix? "." clean) clean
    (string "./" clean)))

(defn- parse [text path]

  (def found @[])
  (def tags (peg/match ~(any (+ (<- (* "<" (some (if-not ">" 1)) ">")) 1)) text))
  (each tag (or tags [])
    (def name (first (or (peg/match ~(* "<" (? "/") (<- (some (range "az" "AZ")))) tag) [])))

    (when (and name (not= (string/ascii-lower name) "a"))
      (each hit (or (peg/match ~(any (+ (* (+ ,;(map |(string $ "=") ["src" "href" "poster" "data"]))
                                           ,quoted)
                                        1))
                               tag) [])
        (array/push found hit))))

  (def keep
    (filter (fn [ref]
              (and (not (empty? ref))
                   (not (string/find "://" ref))
                   (not (string/has-prefix? "#" ref))
                   (not (string/has-prefix? "//" ref))
                   (not (string/has-prefix? "data:" ref))
                   (not (string/has-prefix? "mailto:" ref))
                   (not (string/has-prefix? "tel:" ref))
                   (not (string/find "{{" ref))

                   (not (string/find "${" ref))
                   (not (string/find "<%" ref))
                   (not (string/find "{%" ref))))
            found))

  {:aliases (let [out @{}]
              (eachp [name target] (import-map text)
                (put out (names/safe-name name)
                     (names/from-path path (site-path target))))
              out)
   :imports (map |(names/from-path path $)
                 (distinct
              (map (fn [ref]
                     (def clean (first (string/split "?" (first (string/split "#" ref)))))
                     (cond

                       (string/has-prefix? "/" clean) (string "./" (string/slice clean 1))
                       (string/has-prefix? "." clean) clean
                       (string "./" clean)))
                   keep)))})

(def spec
  {:name "html"
   :ext [".html" ".htm"]

   :skip-dirs ["node_modules" "dist" "build" "coverage" "_site"]
   :parse parse})
