(def- upper '(range "AZ"))
(def- ident-rest '(any (+ (range "AZ") (range "az") (range "09") "_")))

(def- boundary '(+ (! (> -1 1))
                   (! (> -1 (+ (range "AZ") (range "az") (range "09") "_")))))

(def- kinds '(+ "class" "struct" "enum" "protocol" "actor" "typealias"))

(def- word-end '(not (+ (range "AZ") (range "az") (range "09") "_")))

(def- line-start '(+ (> -1 "\n") (! (> -1 1))))

(def- modifier '(some (+ (range "AZ") (range "az") (range "09") "_" "@" "(" ")")))

(def spec
  {:name "swift"
   :ext [".swift"]

   :skip-dirs [".build" "build" "DerivedData" "Pods" "Carthage" ".swiftpm"
               "xcuserdata"]

   :noise ~(+ (* `"""` (any (if-not `"""` 1)) `"""`)
              (* `"` (any (+ (* "\\" 1) (if-not (+ `"` "\n") 1))) `"`)
              (* "//" (any (if-not "\n" 1)))
              (* "/*" (any (if-not "*/" 1)) (opt "*/")))

   :declares ~(* ,line-start
                 (! (* "import" ,word-end))
                 (any (* (! (* ,kinds ,word-end)) ,modifier (some (set " \t"))))
                 ,kinds ,word-end
                 (some (set " \t"))
                 (<- (* ,upper ,ident-rest)))

   :imports-are :modules
   :imports ~(* ,line-start
                "import" (some (set " \t"))

                (opt (* ,modifier (some (set " \t")) (> 0 ,upper)))
                (<- (* ,upper ,ident-rest)))

   :refs ~(* ,boundary (<- (* ,upper ,ident-rest)))})
