# Swift: declarations and references, because Swift has no per-file imports.
#
# Files in one Swift module see each other with nothing written down. An
# import scrape would draw SwiftUI, WebKit and Foundation and miss every edge
# between the project's own files -- which is the entire structure worth
# looking at. So the edges here are SYMBOL REFERENCES: each file declares some
# types, and a file that mentions another file's type depends on it.
#
# `import` lines are still read, so the frameworks appear as nodes and can be
# grouped and hidden like anything else. That is what makes "what does this
# app actually link against" a question you can answer by looking.

# Quoted, not called: `(range "AZ")` is PEG syntax here, and unquoted it would
# be Janet's own `range` function being handed a string.
(def- upper '(range "AZ"))
(def- ident-rest '(any (+ (range "AZ") (range "az") (range "09") "_")))
# A capitalised word only counts when something that is not an identifier
# character precedes it, so `FooBar` yields one name rather than two and
# `x.Foo` is not a fresh mention of Foo... except after a dot, which is how
# `Foundation.Data` names Data. Start-of-text counts as a boundary.
(def- boundary '(+ (! (> -1 1))
                   (! (> -1 (+ (range "AZ") (range "az") (range "09") "_")))))

# The kinds another file can refer to BY NAME. A `let` or `func` at file scope
# is not a type, and graphing every free function buries the structure in
# noise.
#
# `extension` IS ABSENT ON PURPOSE, and it is the one kind a reader expects to
# find here. Measured on otto-ios: a file with `private extension Color` owned
# `Color`, which invented edges from every file that merely used a SwiftUI
# colour. The obvious fix -- "an extension declares only when nobody else
# does" -- fails on the same line, because `extension Color` and
# `extension OurWidget` are textually identical, and telling them apart needs
# to know Color is SwiftUI's. That is a type checker's job and the line this
# tool does not cross. So an extension never declares. Losing an edge is the
# price of never inventing one.
(def- kinds '(+ "class" "struct" "enum" "protocol" "actor" "typealias"))

# A keyword only counts as one when a word boundary follows, so `structure`
# is not read as `struct`.
(def- word-end '(not (+ (range "AZ") (range "az") (range "09") "_")))

# The start of a line, including the file's very first line: either a newline
# sits just behind us, or nothing does. `(> -1 x)` is Janet's lookbehind, so
# `(! (> -1 1))` is "there is no byte before this one" -- position zero.
#
# Anchoring matters more than it looks. Without it the sweep can begin
# mid-line, and `import struct Foundation.Data` matches the declaration
# pattern starting at `struct` -- handing the Foundation framework node to
# whichever file imported it.
(def- line-start '(+ (> -1 "\n") (! (> -1 1))))

# One modifier token: `public`, `@MainActor`, `indirect`, `private(set)`.
(def- modifier '(some (+ (range "AZ") (range "az") (range "09") "_" "@" "(" ")")))

(def spec
  {:name "swift"
   :ext [".swift"]

   # Build output and dependency checkouts hold .swift files that are nobody's
   # dependency graph.
   :skip-dirs [".build" "build" "DerivedData" "Pods" "Carthage" ".swiftpm"
               "xcuserdata"]

   # Ordered longest-first so a `"""` is not eaten as an empty `""` followed
   # by a stray quote.
   :noise ~(+ (* `"""` (any (if-not `"""` 1)) `"""`)
              (* `"` (any (+ (* "\\" 1) (if-not (+ `"` "\n") 1))) `"`)
              (* "//" (any (if-not "\n" 1)))
              (* "/*" (any (if-not "*/" 1)) (opt "*/")))

   # A declaration, after any modifier soup (public, final, @MainActor,
   # indirect, ...). Anchored to the start of a line so that a keyword
   # appearing inside an expression does not count, and the modifiers are
   # skipped by allowing any run of non-keyword words before the keyword
   # itself.
   # `import` is excluded as a modifier, not by accident: `import struct
   # Foundation.Data` contains the word `struct`, and without this the line
   # declares `Foundation` -- handing the framework node to whichever file
   # imported it and inventing an edge from everything that mentions it.
   :declares ~(* ,line-start
                 (! (* "import" ,word-end))
                 (any (* (! (* ,kinds ,word-end)) ,modifier (some (set " \t"))))
                 ,kinds ,word-end
                 (some (set " \t"))
                 (<- (* ,upper ,ident-rest)))

   # `import Foundation` and `import struct Foundation.Data`. The submodule
   # form takes the FIRST component: the node is the framework, not the symbol.
   :imports ~(* ,line-start
                "import" (some (set " \t"))
                # The optional kind in `import struct Foundation.Data`. Only
                # skipped when a capitalised name still follows, so plain
                # `import Foundation` keeps its own name.
                (opt (* ,modifier (some (set " \t")) (> 0 ,upper)))
                (<- (* ,upper ,ident-rest)))

   # Every capitalised word, which is the candidate set. Swift convention
   # makes this a good filter on its own: types are UpperCamelCase and values
   # are lower, so a capitalised token is a type, an enum case written in
   # full, or a framework name. Anything no file declares is dropped
   # downstream, so a false positive here costs nothing.
   :refs ~(* ,boundary (<- (* ,upper ,ident-rest)))})
