(def- line-start '(+ (> -1 "\n") (! (> -1 1))))
(def- space '(any (set " \t")))
(def- path '(some (+ (range "AZ") (range "az") (range "09") "_" "-" "." "/")))

(def spec
  {:name "go"
   :ext [".go"]

   :skip-dirs ["vendor" "testdata"]

   :noise ~(+ (* "`" (any (if-not "`" 1)) "`")
              (* `"` (any (+ (* "\\" 1) (if-not (+ `"` "\n") 1))) `"`)
              (* "//" (any (if-not "\n" 1)))
              (* "/*" (any (if-not "*/" 1)) (opt "*/")))

   :comments ~(+ (* "//" (any (if-not "\n" 1)))
                 (* "/*" (any (if-not "*/" 1)) (opt "*/")))

   :imports-are :modules
   :imports ~(* ,line-start ,space
                (opt (* "import" ,space))
                (opt (* (+ "_" "." (some (+ (range "AZ") (range "az")
                                            (range "09") "_")))
                        (some (set " \t"))))
                `"` (<- ,path) `"`)})
