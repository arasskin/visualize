(def- line-start '(+ (> -1 "\n") (! (> -1 1))))
(def- space '(any (set " \t\r\n")))
(def- ident '(* (+ (range "AZ") (range "az") "_")
               (any (+ (range "AZ") (range "az") (range "09") "_"))))

(def spec
  {:name "c"
   :ext [".c"]
   :noise ~(+ (* `"` (any (+ (* "\\" 1) (if-not (+ `"` "\n") 1))) `"`)
              (* "'" (any (+ (* "\\" 1) (if-not (+ "'" "\n") 1))) "'")
              (* "//" (any (if-not "\n" 1)))
              (* "/*" (any (if-not "*/" 1)) (opt "*/")))
   :declares ~{:main (* ,line-start (any (set " \t"))
                       (+ (* "static" (some (set " \t\r\n")) :private)
                          (* ,ident (some (set " \t\r\n*")) :signature)))
               :signature (+ (* (/ (<- ,ident) ,|(string "ffi:" $))
                                ,space :parameters ,space "{")
                             (* ,ident (some (set " \t\r\n*")) :signature))
               :private (+ (* ,ident ,space :parameters ,space "{")
                           (* ,ident (some (set " \t\r\n*")) :private))
               :parameters (* "(" (any (+ :parameters (if-not (set "();{}") 1))) ")")}})
