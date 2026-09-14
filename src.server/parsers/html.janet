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
  (first (string/split "?" (first (string/split "#" url)))))

(defn- local-url? [ref]
  (and (not (empty? (site-path ref)))
       (not (string/find ":" ref))
       (not (string/has-prefix? "//" ref))
       (not (string/find "{{" ref))
       (not (string/find "${" ref))
       (not (string/find "<%" ref))
       (not (string/find "{%" ref))))

(defn- parse [text path]

  (def text (peg/replace-all ~(* "<!--" (any (if-not "-->" 1)) (opt "-->")) " " text))
  (def found @[])
  (def tags (peg/match ~(any (+ (<- (* "<" (some (if-not ">" 1)) ">")) 1)) text))
  (each tag (or tags [])
    (def name (first (or (peg/match ~(* "<" (? "/") (<- (some (range "az" "AZ")))) tag) [])))

    (when (and name (not= (string/ascii-lower name) "a"))
      (each hit (or (peg/match ~(any (+ (* (some (set " \t\r\n"))
                                           (+ "src" "href" "poster" "data")
                                           (any (set " \t\r\n")) "=" (any (set " \t\r\n"))
                                           ,quoted)
                                        1))
                               tag) [])
        (array/push found hit))))

  {:asset-aliases (let [out @{}]
                   (eachp [name target] (import-map text)
                     (when (local-url? target)
                       (put out (names/safe-name name) (site-path target))))
                   out)
   :assets (distinct (map site-path (filter local-url? found)))})

(def spec
  {:name "html"
   :ext [".html" ".htm"]

   :skip-dirs ["node_modules" "dist" "build" "coverage" "_site"]
   :parse parse})
