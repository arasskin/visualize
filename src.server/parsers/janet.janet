(def- line-start '(+ (> -1 "\n") (! (> -1 1))))
(def- space '(any (set " \t")))

(def- path '(some (+ (range "AZ") (range "az") (range "09") "_" "-" "." "/")))

(def- whitespace '(any (set " \t\r\n")))
(def- symbol-name '(some (+ (range "AZ") (range "az") (range "09") "_")))
(def- native-reference
  ~{:main (* "(" ,whitespace "ffi/lookup" (some (set " \t\r\n"))
             :form (some (set " \t\r\n"))
             `"` (/ (<- ,symbol-name) ,|(string "ffi:" $)) `"` ,whitespace ")")
    :form (+ :string
             (* "(" (any (* ,whitespace :form)) ,whitespace ")")
             (* "[" (any (* ,whitespace :form)) ,whitespace "]")
             (* "{" (any (* ,whitespace :form)) ,whitespace "}")
             (some (if-not (set " \t\r\n()[]{}\"#") 1)))
    :string (* `"` (any (+ (* "\\" 1) (if-not `"` 1))) `"`)})

(def spec
  {:name "janet"
   :ext [".janet"]

   :skip-dirs ["jpm_tree" "build"]

   :noise ~(+ (* "``" (any (if-not "``" 1)) "``")
              (* "`" (any (if-not "`" 1)) "`")
              (* `"` (any (+ (* "\\" 1) (if-not (+ `"` "\n") 1))) `"`)
              (* "#" (any (if-not "\n" 1))))

   :comments ~(* "#" (any (if-not "\n" 1)))

   :literal-refs native-reference

   :imports-are :paths
   :imports ~(* ,line-start ,space
                "(" ,space (+ "import" "use") (some (set " \t"))
                (opt "\"")
                (<- ,path))})
