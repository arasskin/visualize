(def- line-start '(+ (> -1 "\n") (! (> -1 1))))
(def- space '(any (set " \t")))

(def- path '(some (+ (range "AZ") (range "az") (range "09") "_" "-" "." "/")))

(def spec
  {:name "janet"
   :ext [".janet"]

   :skip-dirs ["jpm_tree" "build"]

   :noise ~(+ (* "``" (any (if-not "``" 1)) "``")
              (* "`" (any (if-not "`" 1)) "`")
              (* `"` (any (+ (* "\\" 1) (if-not (+ `"` "\n") 1))) `"`)
              (* "#" (any (if-not "\n" 1))))

   :comments ~(* "#" (any (if-not "\n" 1)))

   :imports-are :paths
   :imports ~(* ,line-start ,space
                "(" ,space (+ "import" "use") (some (set " \t"))
                (opt "\"")
                (<- ,path))})
