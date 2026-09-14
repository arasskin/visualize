(def- line-start '(+ (> -1 "\n") (! (> -1 1))))
(def- space '(any (set " \t\r\n")))
(def- boundary '(not (> -1 (+ (range "AZ") (range "az") (range "09") "_" "$" "."))))

(def- specifier '(some (+ (range "AZ") (range "az") (range "09")
                          "_" "-" "." "/" "@")))
(def- quoted ~(+ (* `"` (<- ,specifier) `"`)
                 (* "'" (<- ,specifier) "'")))

(def spec
  {:name "javascript"
   :ext [".js" ".jsx" ".mjs" ".cjs" ".ts" ".tsx"]

   :skip-dirs ["node_modules" "dist" "build" ".next" "coverage" "out"
               ".turbo" ".parcel-cache"]

   :noise ~(+ (* "`" (any (+ (* "\\" 1) (if-not "`" 1))) "`")
              (* `"` (any (+ (* "\\" 1) (if-not (+ `"` "\n") 1))) `"`)
              (* "'" (any (+ (* "\\" 1) (if-not (+ "'" "\n") 1))) "'")
              (* "//" (any (if-not "\n" 1)))
              (* "/*" (any (if-not "*/" 1)) (opt "*/")))

   :comments ~(+ (* "//" (any (if-not "\n" 1)))
                 (* "/*" (any (if-not "*/" 1)) (opt "*/")))

   :imports-are :paths
   :imports ~(+ (* ,line-start ,space
                   (+ "import" "export") (not (+ (range "AZ") (range "az") (range "09") "_" "$"))
                   (+ (* (some (if-not (+ "from" ";" "'" `"` "`") 1)) "from" ,space)
                      ,space)
                   ,quoted)

                (* ,boundary (+ "require" "import") ,space "(" ,space ,quoted ,space (+ ")" ",")))})
