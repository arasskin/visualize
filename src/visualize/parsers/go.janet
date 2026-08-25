# Go: imports are authoritative, and always quoted.
#
# Go's grammar makes this the easiest spec in the tree. Every import is a
# quoted path, and the two forms -- a single `import "fmt"` and a parenthesised
# block -- share the quoted path as the only thing that matters. So the pattern
# does not model the block at all: it takes every quoted import path, and the
# block falls out for free.
#
# The path is kept whole (`github.com/user/repo/pkg`), because that is what
# prefix matching needs: (hide github.com) drops every third-party package at
# once, and (box ~.internal) boxes the project's own.

(def- line-start '(+ (> -1 "\n") (! (> -1 1))))
(def- space '(any (set " \t")))
(def- path '(some (+ (range "AZ") (range "az") (range "09") "_" "-" "." "/")))

(def spec
  {:name "go"
   :ext [".go"]

   :skip-dirs ["vendor" "testdata"]

   # Raw strings use backticks and may span lines; they cannot contain escapes,
   # which is why they are matched before the interpreted form.
   :noise ~(+ (* "`" (any (if-not "`" 1)) "`")
              (* `"` (any (+ (* "\\" 1) (if-not (+ `"` "\n") 1))) `"`)
              (* "//" (any (if-not "\n" 1)))
              (* "/*" (any (if-not "*/" 1)) (opt "*/")))

   # Comments only. Every Go import path is a quoted string, so the :noise
   # pass above would blank the entire import block before it could be read.
   :comments ~(+ (* "//" (any (if-not "\n" 1)))
                 (* "/*" (any (if-not "*/" 1)) (opt "*/")))

   # Either `import "fmt"` on its own line, or a line inside an import block
   # -- which is just a quoted path, optionally preceded by an alias (`m
   # "math"`) or a dot/underscore import (`_ "driver"`).
   #
   # Anchoring to the line start is what keeps a quoted string elsewhere in
   # the file from being read as an import; the noise pass has already blanked
   # those, so this is belt and braces.
   :imports-are :modules
   :imports ~(* ,line-start ,space
                (opt (* "import" ,space))
                (opt (* (+ "_" "." (some (+ (range "AZ") (range "az")
                                            (range "09") "_")))
                        (some (set " \t"))))
                `"` (<- ,path) `"`)})
