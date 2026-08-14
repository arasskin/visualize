# Python: imports are authoritative, so the graph writes itself.
#
# The opposite of Swift. Python states its dependencies in the source --
# `import otto.store` names a module and means it -- so this spec declares
# only :imports and leaves :declares and :refs out entirely. The engine
# handles both shapes; see visualize/parser.janet.
#
# The module name is kept WHOLE and dotted (`otto.store`, not `otto`), because
# the graph's prefix matching is what turns that into structure: `~.store`
# selects it, `(group ~.store)` boxes it. Truncating to the top package would
# collapse every module in a project into a single node.

(def- line-start '(+ (> -1 "\n") (! (> -1 1))))
(def- ident '(some (+ (range "AZ") (range "az") (range "09") "_")))
(def- dotted ~(* ,ident (any (* "." ,ident))))
(def- space '(some (set " \t")))

(def spec
  {:name "python"
   :ext [".py"]

   # Virtualenvs and caches hold .py files that are nobody's dependency graph.
   :skip-dirs [".venv" "venv" "__pycache__" ".tox" ".eggs" "site-packages"
               "node_modules" ".mypy_cache" ".pytest_cache"]

   # Triple-quoted strings first, so a docstring is not read as an empty ''
   # followed by loose text. Both quote styles, since Python treats them alike.
   :noise ~(+ (* `"""` (any (if-not `"""` 1)) `"""`)
              (* "'''" (any (if-not "'''" 1)) "'''")
              (* `"` (any (+ (* "\\" 1) (if-not (+ `"` "\n") 1))) `"`)
              (* "'" (any (+ (* "\\" 1) (if-not (+ "'" "\n") 1))) "'")
              (* "#" (any (if-not "\n" 1))))

   # `import os`, `import os.path`, `from otto.store import Cart`.
   #
   # The `from` form captures the MODULE and stops before `import`, so the
   # symbols being imported never become nodes -- `Cart` is a class inside
   # otto.store, not a thing the graph has an opinion about.
   #
   # A relative `from . import x` captures nothing: the leading dot is not
   # part of `ident`, so the pattern simply fails and the line is skipped.
   # Resolving it would mean knowing the importing file's package, which is
   # the one thing a per-file scan does not have.
   :imports ~(* ,line-start
                (any (set " \t"))
                (+ (* "from" ,space (<- ,dotted) ,space "import")
                   (* "import" ,space (<- ,dotted))))})
