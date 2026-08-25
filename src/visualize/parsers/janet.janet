# Janet: imports are authoritative, and the tool can graph itself.
#
# `(import ./visualize/color :as c)` and `(use ./thing)` both name a module. The
# path is kept as written, leading `./` and all, because that is what
# distinguishes a module in this project from one in the tree of installed
# libraries -- the same reason the JavaScript spec keeps `./store` whole.
#
# A .janet file's own `spec` export is why this file exists at all: with it in
# place, `janet src/core.janet .` draws the dependency graph of visualize.

(def- line-start '(+ (> -1 "\n") (! (> -1 1))))
(def- space '(any (set " \t")))
# Janet identifiers are permissive -- `string/has-prefix?`, `->>`, `my-thing`
# -- but a module path is a subset: names, slashes, dots and dashes.
(def- path '(some (+ (range "AZ") (range "az") (range "09") "_" "-" "." "/")))

(def spec
  {:name "janet"
   :ext [".janet"]

   :skip-dirs ["jpm_tree" "build"]

   # Long strings are delimited by runs of backticks and may contain anything,
   # including text that looks like an import -- this file's own header is
   # full of it. Matched first, and only against a single backtick run, since
   # that covers every form the tree actually uses.
   :noise ~(+ (* "``" (any (if-not "``" 1)) "``")
              (* "`" (any (if-not "`" 1)) "`")
              (* `"` (any (+ (* "\\" 1) (if-not (+ `"` "\n") 1))) `"`)
              (* "#" (any (if-not "\n" 1))))

   # Comments only: an import path here is a bare symbol rather than a string,
   # so this could fall back to :noise -- but a `#` inside a long string would
   # then be read as a comment. Kept explicit for that reason.
   :comments ~(* "#" (any (if-not "\n" 1)))

   # `(import ./x)`, `(import ./x :as y)`, `(use ./x)`. Anchored to a line
   # start with only whitespace and the open paren before it: an `import`
   # deeper in an expression is not a top-level dependency.
   :imports-are :paths
   :imports ~(* ,line-start ,space
                "(" ,space (+ "import" "use") (some (set " \t"))
                (opt "\"")
                (<- ,path))})
