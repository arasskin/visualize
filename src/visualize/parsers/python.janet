(import ../parser)

(def- line-start '(+ (> -1 "\n") (! (> -1 1))))
(def- ident '(some (+ (range "AZ") (range "az") (range "09") "_")))
(def- dotted ~(* ,ident (any (* "." ,ident))))
(def- space '(some (set " \t")))

(def- noise
  ~(+ (* `"""` (any (if-not `"""` 1)) `"""`)
      (* "'''" (any (if-not "'''" 1)) "'''")
      (* `"` (any (+ (* "\\" 1) (if-not (+ `"` "\n") 1))) `"`)
      (* "'" (any (+ (* "\\" 1) (if-not (+ "'" "\n") 1))) "'")
      (* "#" (any (if-not "\n" 1)))))

(def- import-line
  ~(* ,line-start (any (set " \t"))
      (+ (* "from" ,space (<- ,dotted) ,space "import" ,space
            (+ (* "(" (<- (any (if-not ")" 1))) ")")
               (<- (any (if-not "\n" 1)))))
         (* "import" ,space (<- (any (if-not "\n" 1)))))))

(def- all-imports
  ~(any (+ (/ (* (constant :hit) ,import-line) ,(fn [_ & caps] caps))
           1)))

(defn- listed [text]
  (seq [piece :in (string/split "," (or text ""))
        :let [word (first (string/split " " (string/trim piece)))]
        :when (and word (not (empty? word)) (not= word "*"))]
    word))

(defn- parse [text path]
  (def clean (parser/blank-noise noise text))

  (def out @[])
  (each hit (peg/match all-imports clean)
    (if (= 2 (length hit))

      (let [[module names] hit]
        (array/push out module)
        (each name (listed names)
          (array/push out (string module "." name))))

      (each name (listed (first hit))
        (array/push out name))))

  (def whole @[])
  (each name out
    (array/push whole name)
    (def parts (string/split "." name))
    (for i 1 (length parts)
      (array/push whole (string (string/join (slice parts 0 i) ".") "."))))
  {:imports (distinct whole)})

(def spec
  {:name "python"
   :ext [".py"]

   :skip-dirs [".venv" "venv" "__pycache__" ".tox" ".eggs" "site-packages"
               "node_modules" ".mypy_cache" ".pytest_cache"]

   :noise noise

   :imports-are :modules
   :parse parse})
