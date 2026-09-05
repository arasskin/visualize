(def- line-start '(+ (> -1 "\n") (! (> -1 1))))
(def- space '(any (set " \t")))

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
                   (+ "import" "export")
                   (+ (* (some (if-not (+ "from" "\n") 1)) "from" ,space)
                      ,space)
                   ,quoted)

                (* "require" ,space "(" ,space ,quoted))})
