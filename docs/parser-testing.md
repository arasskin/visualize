Parser testing has two layers. `src/test/scan.janet` keeps focused extraction and resolution regressions. `src/test/parsers.janet` runs the multi-file projects defined in `src/test/fixtures/parsers.janet` through discovery, parsing and graph construction. Both run in `./src/test/run`.

Each corpus case specifies source files and an exact, hand-written edge set. Expected nodes include all discovered files and explicitly expected external dependencies; `.visualize` cases supply their logical nodes. Comparing the whole graph catches unexpected dependencies as well as missing ones. Cases can also specify exact extracted imports and files that discovery must ignore.

The runner creates temporary projects and removes them after each case. It checks:

- LF, CRLF and missing final newlines against the same expected graph.
- Normal and reversed parsed-file order against the same expected graph.
- One parsing worker and four workers against the same expected graph.
- Every byte prefix of each parsed source, both alone and followed by a dangling backslash, for parser exceptions or missing results. These simulate files observed during editing; their partial dependency graphs are not asserted.
- Coverage of every registered language, so adding a parser without a corpus case fails the suite.

The corpus covers all 12 parsers:

| Parser | Cases exercised |
| --- | --- |
| Python | Nested packages, aliases, multiline imports, relative imports, docstrings, external/local name collisions |
| JavaScript/TypeScript | Multiline imports and reexports, literal dynamic imports, CommonJS, computed imports, quoted examples |
| Janet | Relative imports, aliases, quoted paths, multiline documentation strings, same-stem C files, init modules, literal FFI symbol lookups |
| C | FFI export definitions, pointer returns, multiline signatures, static functions, prototypes, duplicate symbols, strings and comments |
| Go | Grouped imports, aliases, blank/dot imports, raw strings, ordinary string arguments |
| Clojure/ClojureDart | Nested source roots, munged namespaces, macro requires, Dart libraries, strings and comments, generated directories |
| Swift | Cross-file types and free-function calls, member-call exclusions, extensions, sibling worktrees, nested directories, duplicate declarations, language collisions, strings and comments |
| Arduino | Includes, cross-tab calls, ambiguous/non-code references and unparsed headers |
| HTML | Import maps, local assets, query strings/fragments, attribute whitespace, data attributes, comments and external URLs |
| CSS | Imports, fonts, relative URLs, query strings/fragments, quoted content and embedded/external data |
| Shell | Extensionless launchers, directory aliases, sourced files, hidden-path exclusions, config-file collisions and compiler continuations |
| Visualize | Logical tasks, exact project-relative file links and missing-file fallback nodes |

Janet module resolution prefers `.janet` and then `/init.janet` over unrelated files with the same stem. Literal `ffi/lookup` names link to unique C function definitions in the project. C support currently indexes those exports; it does not trace C includes or calls, preprocess macros, infer computed FFI symbol names, or determine which library provides a symbol defined in multiple files. Static functions and prototypes do not provide FFI targets. Native symbols use a separate name space from ordinary language declarations.

Python imports distinguish module names from imported members. Absolute imports do not search inside enclosing regular packages or fall back to unrelated filenames elsewhere in the tree. This keeps `import html` separate from a package's `retailers/html.py`, while qualified and relative imports still reach that file. Root modules and siblings of standalone scripts can still shadow library names. Package boundaries come from `__init__.py`; runtime changes to `sys.path`, custom import hooks, and the execution mode of a script inside a package are not modeled.

Swift references consider only Swift declarations. Resolution starts in the referencing file's directory and walks toward the scan root. At each level, declarations directly in that directory take precedence over descendants; otherwise the enclosing subtree must contain exactly one candidate. An ambiguous local match stays unresolved instead of falling through to another worktree. This is a directory-based approximation, not Xcode target or Swift module analysis. Sibling worktrees no longer erase local dependencies by declaring the same names. The scanner recognizes unindented free-function declarations and direct calls; private/fileprivate functions and member calls do not create free-function dependencies. Variable shadowing, higher-order function references, and qualified nested-type resolution are not modeled.

To add a regression, reduce the failing project to the files necessary to distinguish the correct graph from the incorrect one. Add it to `fixtures/parsers.janet` with the expected edges. Include competing files when name resolution matters, and inert examples when false positives matter. Keep expected results independent of current parser output. The fixtures are parsed as text; the suite does not execute their programs or require their language toolchains.

For only the corpus, after building:

```sh
external-src/janet/janet -e '(import ./src/test/harness :as t) (import ./src/test/parsers) (os/exit (t/report))'
```

These are lightweight static dependency parsers, not language implementations. Passing the corpus does not establish complete syntax support. Further cases should cover Clojure reader conditionals and discarded forms, JavaScript regular expressions and template interpolation, Python continuation/semicolon forms, and HTML raw-text elements and `srcset`. Computed module names and runtime-generated dependencies require a separate policy; the tests do not assume they can be resolved statically.
