# JavaScript and TypeScript: imports are authoritative, like Python's.
#
# One spec covers .js/.jsx/.ts/.tsx because the import syntax is identical
# across them -- the type-level differences TypeScript adds are invisible to a
# dependency scan, and `import type { X } from './y'` is still a dependency on
# './y' as far as the graph is concerned.
#
# RELATIVE SPECIFIERS ARE THE INTERESTING ONES. `./store` and `../lib/api`
# name files in the project and become internal edges; `react` and
# `@scope/pkg` name packages and become externals, which is what lets
# (box react) and (hide lodash) work. The leading `./` and `../` are kept in
# the module name so the two cannot be confused.

(def- line-start '(+ (> -1 "\n") (! (> -1 1))))
(def- space '(any (set " \t")))
# What can appear inside a module specifier: a path, a scope, a package name.
(def- specifier '(some (+ (range "AZ") (range "az") (range "09")
                          "_" "-" "." "/" "@")))
(def- quoted ~(+ (* `"` (<- ,specifier) `"`)
                 (* "'" (<- ,specifier) "'")))

(def spec
  {:name "javascript"
   :ext [".js" ".jsx" ".mjs" ".cjs" ".ts" ".tsx"]

   :skip-dirs ["node_modules" "dist" "build" ".next" "coverage" "out"
               ".turbo" ".parcel-cache"]

   # Template literals are included: they can span lines and contain anything,
   # including text that looks like an import.
   :noise ~(+ (* "`" (any (+ (* "\\" 1) (if-not "`" 1))) "`")
              (* `"` (any (+ (* "\\" 1) (if-not (+ `"` "\n") 1))) `"`)
              (* "'" (any (+ (* "\\" 1) (if-not (+ "'" "\n") 1))) "'")
              (* "//" (any (if-not "\n" 1)))
              (* "/*" (any (if-not "*/" 1)) (opt "*/")))

   # Comments only. The module specifier is always a quoted string, so the
   # :noise pass would erase every import before it could be matched.
   :comments ~(+ (* "//" (any (if-not "\n" 1)))
                 (* "/*" (any (if-not "*/" 1)) (opt "*/")))

   # Four shapes, all ending in the specifier:
   #
   #   import x from './y'        import './side-effect'
   #   export { x } from './y'    const x = require('./y')
   #
   # The `from` form skips whatever sits between the keyword and `from`
   # (braces, names, `* as ns`, `type`) without trying to understand it --
   # the graph wants the module, not the bindings.
   :imports ~(+ (* ,line-start ,space
                   (+ "import" "export")
                   (+ (* (some (if-not (+ "from" "\n") 1)) "from" ,space)
                      ,space)
                   ,quoted)
                # `require('x')` anywhere, not just at line start: it is an
                # expression and shows up inside assignments and calls.
                (* "require" ,space "(" ,space ,quoted))})
