(import ../names)

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
      (+ (* "from" ,space (<- (+ (* (some ".") (opt ,dotted)) ,dotted)) ,space "import" ,space
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

(defn- parse [text path blank-noise]
  (def clean (blank-noise noise text))

  (def out @[])
  (def modules @[])
  (def members @[])
  (each hit (peg/match all-imports clean)
    (if (= 2 (length hit))

      (let [[module names] hit]
        (def module (if (string/has-prefix? "." module)
          (let [tail (string/triml module ".")
                levels (- (length module) (length tail))]
            (names/from-path path (string "./" (string/repeat "../" (- levels 1))
                                          (string/replace-all "." "/" tail))))
          module))
        (array/push out module)
        (array/push modules module)
        (each name (listed names)
          (def member (string module "." name))
          (array/push out member)
          (array/push members member)))

      (each name (listed (first hit))
        (array/push out name)
        (array/push modules name))))

  (def whole @[])
  (each name out
    (array/push whole name)
    (def parts (string/split "." name))
    (for i 1 (length parts)
      (array/push whole (string (string/join (slice parts 0 i) ".") "."))))
  {:imports (distinct whole)
   :import-members (distinct (filter |(not (index-of $ modules)) members))})

(defn spec [blank-noise]
  {:name "python"
   :ext [".py"]

   :skip-dirs [".venv" "venv" "__pycache__" ".tox" ".eggs" "site-packages"
               "node_modules" ".mypy_cache" ".pytest_cache"]

   :noise noise

   :imports-are :modules
   :parse (fn [text path] (parse text path blank-noise))})
