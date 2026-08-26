# Python: imports are authoritative, so the graph writes itself.
#
# The opposite of Swift. Python states its dependencies in the source --
# `import otto.store` names a module and means it -- so this spec declares
# only :imports and leaves :declares and :refs out entirely. The engine
# handles both shapes; see src/parser.janet.
#
# The module name is kept WHOLE and dotted (`otto.store`, not `otto`), because
# the graph's prefix matching is what turns that into structure: `~.store`
# selects it, `(box ~.store)` boxes it. Truncating to the top package would
# collapse every module in a project into a single node.

(import ../parser)

(def- line-start '(+ (> -1 "\n") (! (> -1 1))))
(def- ident '(some (+ (range "AZ") (range "az") (range "09") "_")))
(def- dotted ~(* ,ident (any (* "." ,ident))))
(def- space '(some (set " \t")))

# Strings and comments, blanked before the import scan so that an `import`
# inside a docstring is not read as one. Triple-quoted first, so a docstring
# is not read as an empty '' followed by loose text; both quote styles, since
# Python treats them alike.
(def- noise
  ~(+ (* `"""` (any (if-not `"""` 1)) `"""`)
      (* "'''" (any (if-not "'''" 1)) "'''")
      (* `"` (any (+ (* "\\" 1) (if-not (+ `"` "\n") 1))) `"`)
      (* "'" (any (+ (* "\\" 1) (if-not (+ "'" "\n") 1))) "'")
      (* "#" (any (if-not "\n" 1)))))

# `from X import a, b` and `import X, Y` -- the module, and the names after
# it. Both forms, with the parenthesised list read to its closing paren so a
# multi-line import is one match rather than a first line and some orphans.
(def- import-line
  ~(* ,line-start (any (set " \t"))
      (+ (* "from" ,space (<- ,dotted) ,space "import" ,space
            (+ (* "(" (<- (any (if-not ")" 1))) ")")
               (<- (any (if-not "\n" 1)))))
         (* "import" ,space (<- (any (if-not "\n" 1)))))))

# The names in an import list, with `as` aliases and trailing commas
# discarded. `a, b as c, d` gives a, b and d -- the ALIAS is a local name and
# names no file, while the thing it renames does.
# Every import in the file, each one's captures grouped so the two forms stay
# distinguishable -- two captures is `from X import ...`, one is `import X`.
(def- all-imports
  ~(any (+ (/ (* (constant :hit) ,import-line) ,(fn [_ & caps] caps))
           1)))

(defn- listed [text]
  (seq [piece :in (string/split "," (or text ""))
        :let [word (first (string/split " " (string/trim piece)))]
        :when (and word (not (empty? word)) (not= word "*"))]
    word))

(defn- parse [text path]
  (def clean (parser/blank-noise noise text))
  # EVERY IMPORT IN ONE PASS. An earlier version retried the pattern at each
  # byte from a `while` loop, which is what `peg/find-all` does internally in
  # C -- and doing it from Janet cost seven times the whole scan's budget
  # (1115 ms against 155 ms on a project of this size).
  (def out @[])
  (each hit (peg/match all-imports clean)
    (if (= 2 (length hit))
      # `from X import a, b`: the module itself, and X.a for each name --
      # one of which may be a submodule and one of which may be a class.
      # See the note in the spec.
      (let [[module names] hit]
        (array/push out module)
        (each name (listed names)
          (array/push out (string module "." name))))
      # `import a, b` -- each is a module in its own right.
      (each name (listed (first hit))
        (array/push out name))))

  # EVERY PACKAGE ALONG THE WAY, marked so the scan can tell them from what
  # the file actually wrote. Importing `otto.product_reads.shopify` runs
  # `otto/product_reads/__init__.py` first -- python cannot reach a submodule
  # without importing its parents -- so each is a real dependency, and
  # reporting only the leaf lost the edge to `otto.product_reads` from every
  # retailer reading through it.
  #
  # A PREFIX IS INFERRED, NOT WRITTEN: the source never says `otto` in
  # `import otto.mcp.cart`. So one that matches no file must not become
  # `?.otto` -- a node on the drawing that nothing in the tree asked for.
  # Marked with a trailing "." (a name no python module can have), the scan
  # drops it when it resolves to nothing; see `speculative?` in scan.janet.
  (def whole @[])
  (each name out
    (array/push whole name)
    (def parts (string/split "." name))
    (for i 1 (length parts)
      (array/push whole (string (string/join (slice parts 0 i) ".") "."))))
  {:imports (distinct whole)})

(def spec
  {:name "python"
   :ext [".py"]

   # Virtualenvs and caches hold .py files that are nobody's dependency graph.
   :skip-dirs [".venv" "venv" "__pycache__" ".tox" ".eggs" "site-packages"
               "node_modules" ".mypy_cache" ".pytest_cache"]


   # `import os`, `import os.path`, `from otto.store import Cart`.
   #
   # A NAME AFTER `import` MAY BE A MODULE, and half of them here are:
   # `from otto.mcp import cart` names the file otto/mcp/cart.py, and
   # `from otto import store_cart, store_order` names two more. The other
   # half are classes and functions -- `from otto.store import Cart` -- and
   # NOTHING IN THE SYNTAX TELLS THEM APART. Python itself decides by
   # looking: a submodule if one exists, an attribute otherwise.
   #
   # So both readings are reported, `otto.mcp` and `otto.mcp.cart`, and the
   # scan keeps whichever names a file it actually has (see `build` in
   # scan.janet -- a name matching nothing becomes an external, and an
   # external nobody can resolve is dropped rather than drawn, so a class
   # costs nothing). Capturing only the module was losing every submodule
   # import in the tree; capturing only the symbol would lose every class.
   #
   # THE PARENTHESISED FORM SPANS LINES, which is how a long import list is
   # written and how most of them are written here. The list is read to its
   # closing paren rather than to the end of the line.
   #
   # A relative `from . import x` captures nothing: the leading dot is not
   # part of `ident`, so the pattern simply fails and the line is skipped.
   # Resolving it would mean knowing the importing file's package, which is
   # the one thing a per-file scan does not have.
   # The strings and comments blanked before the scan; see the def above.
   :noise noise

   :imports-are :modules
   :parse parse})
