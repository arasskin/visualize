(def- line-start '(+ (> -1 "\n") (! (> -1 1))))
(def- space '(any (set " \t")))

(def- ident-start '(+ (range "AZ") (range "az") "_"))
(def- ident-rest '(any (+ (range "AZ") (range "az") (range "09") "_")))
(def- ident ~(* ,ident-start ,ident-rest))

(def- word-end '(not (+ (range "AZ") (range "az") (range "09") "_")))

(def- kinds '(+ "class" "struct" "enum" "union" "namespace"))

(def- width '(+ "long long" "long" "int" "short" "char"))
(def- return-type
  ~(* (opt (* (+ "static" "inline" "virtual" "extern") (some (set " \t"))))
      (opt (* "const" (some (set " \t"))))
      (+ (* (+ "unsigned" "signed")
            (opt (* (some (set " \t")) ,width)))
         "void" "long long" "long" "int" "char" "bool" "boolean" "byte"
         "word" "float" "double" "short" "size_t" "uint8_t" "uint16_t"
         "uint32_t" "int8_t" "int16_t" "int32_t" "String")
      (any (set " \t*&"))))

(def- runtime-names '(+ "setup" "loop"))

(def spec
  {:name "arduino"

   :ext [".ino" ".pde"]

   :skip-dirs ["build" ".pio" "libraries" ".vscode"]

   :noise ~(+ (* "R\"" (any (if-not "\"" 1)) (opt "\""))
              (* `"` (any (+ (* "\\" 1) (if-not (+ `"` "\n") 1))) `"`)
              (* "'" (any (+ (* "\\" 1) (if-not (+ "'" "\n") 1))) "'")
              (* "//" (any (if-not "\n" 1)))
              (* "/*" (any (if-not "*/" 1)) (opt "*/")))

   :comments ~(+ (* "//" (any (if-not "\n" 1)))
                 (* "/*" (any (if-not "*/" 1)) (opt "*/")))

   :imports-are :paths
   :imports ~(* ,line-start ,space "#" ,space "include" ,space
                (+ (* "<" (<- (some (if-not (+ ">" "\n") 1))) ">")
                   (* `"` (<- (some (if-not (+ `"` "\n") 1))) `"`)))

   :declares ~(* ,line-start ,space
                 (+ (* (opt (* "typedef" (some (set " \t"))))
                       ,kinds ,word-end ,space (<- ,ident))
                    (* ,return-type (! ,runtime-names) (<- ,ident) ,space "(")))

   :refs ~(<- ,ident)})
