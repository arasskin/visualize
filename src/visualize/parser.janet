# What a language is, as data.
#
# THIS FILE NAMES NO LANGUAGE. It defines the shape a parser spec has and the
# one function that runs a spec against a file's text; `visualize/parsers/*.janet` are
# the specs themselves. Adding a language means adding a file there and
# nothing here, which is the whole point of the split -- the scan engine, the
# graph, the config language and the page are all language-agnostic, and this
# is the seam they meet the source through.
#
# A SPEC IS A STRUCT with these keys:
#
#   :name      what to call it, for errors and the parser list
#   :ext       file extensions it claims, e.g. [".swift"]
#   :skip-dirs extra directories to ignore beyond the global set
#   :noise     a PEG matching comments and string literals, blanked before
#              :declares and :refs run. Optional but almost always wanted --
#              see `blank-noise` below for why it matters more than it looks.
#   :comments  a PEG matching comments ONLY, blanked before :imports runs.
#              Needed because in most languages the import path IS a string
#              literal, so the :noise pass would erase the very thing the
#              import pattern is looking for -- see `run` below.
#   :declares  a PEG whose captures are the names this file DEFINES
#   :imports   a PEG whose captures are the modules this file imports
#   :refs      a PEG whose captures are the names this file MENTIONS
#   :parse     an escape hatch: a function (text path) -> the same struct
#              `run` returns. When present, the PEGs above are ignored. For a
#              language that needs a real compiler or tree-sitter rather than
#              a regex-grade scan.
#
# The three PEGs answer three questions and any of them may be absent. A
# language with no imports (Swift, within a module) simply omits :imports.
#
# WHY DECLARES AND REFS RATHER THAN JUST IMPORTS. Python says what it depends
# on: `import otto.store` names a module and the graph writes itself. Swift
# does not -- files in one module see each other with nothing written down, so
# scraping imports draws SwiftUI and Foundation and misses every edge between
# the project's own files, which is the entire structure worth looking at. So
# the general model is the harder one: a file DECLARES some names, and a file
# that MENTIONS another's name depends on it. A language whose imports are
# authoritative just leaves :declares and :refs out and gets the easy path.

(defn- captures
  ``Every capture a PEG makes across the whole text, deduplicated.

  `peg/match` matches once at one position; the scan wants every hit, so the
  pattern is swept across the text here rather than in each spec -- a spec
  author writes only the interesting part.

  The sweep adds NO capture of its own. Each spec already marks the one piece
  it wants with `(<- ...)` -- the type name, not the modifiers in front of it
  -- and wrapping the whole pattern in another capture would return the
  matched line as well as the name inside it.``
  [pattern text]
  (if-not pattern
    @[]
    (distinct (or (peg/match ~(any (+ ,pattern 1)) text) @[]))))

(defn blank-noise
  ``Source with comments and string literals replaced by spaces.

  THIS MATTERS MORE THAN IT LOOKS. A file that embeds a JavaScript program in
  a string literal contains capitalised words -- HTMLInputElement, Event,
  Object -- that are not references to anything in the project. Left in, they
  invent edges to whichever file happens to declare a name that collides, and
  the graph is quietly, confidently wrong.

  Replaced with a SPACE rather than deleted, so a token can never be glued to
  its neighbour: `Foo"bar"Baz` must not become `FooBaz`, which is a reference
  to something nobody declared.``
  [pattern text]
  (if-not pattern
    text
    (do
      # Each match contributes its own length in spaces, so every byte offset
      # after it is unchanged -- which keeps any future line-number work honest.
      (def out (buffer/new (length text)))
      (def scan (peg/compile ~(any (+ (/ (capture ,pattern) ,|(string/repeat " " (length $)))
                                      (capture 1)))))
      (each piece (or (peg/match scan text) @[])
        (buffer/push-string out piece))
      (string out))))

(defn run
  ``Run a spec against one file's text.

  Returns {:declares [...] :imports [...] :refs [...]} -- three lists of
  names, which is all the graph builder ever asks a parser for. Everything
  downstream is the same for every language.

  A spec supplying :parse takes over completely; that is the escape hatch for
  a language a PEG cannot honestly read.``
  [spec text &opt path]
  (if-let [custom (spec :parse)]
    (custom text path)
    (let [# Declarations and references are read from source with BOTH
          # comments and string literals blanked: a capitalised word inside a
          # string is not a reference to anything.
          clean (blank-noise (spec :noise) text)
          # Imports are read from source with only the COMMENTS blanked,
          # because in most languages the module path is itself a string
          # literal -- `import "fmt"`, `from './store'`. Blanking strings
          # first would erase every import in the file.
          #
          # A spec with no :comments falls back to :noise, which is right for
          # a language whose imports are bare words (Python, Swift) and where
          # the distinction therefore does not arise.
          importable (blank-noise (or (spec :comments) (spec :noise)) text)]
      {:declares (captures (spec :declares) clean)
       :imports (captures (spec :imports) importable)
       :refs (captures (spec :refs) clean)})))

(defn- first-line
  ``The first line of a file, or nil -- read as a chunk rather than whole.

  A tree holds extensionless files that are nobody's source: binaries,
  LICENSE, a compiled runtime. Reading each one to check two characters
  would cost the scan its speed, so this takes 128 bytes and stops. That is
  more than any shebang and less than a page.``
  [path]
  (when-let [f (try (file/open path :rb) ([_] nil))]
    (def head (try (file/read f 128) ([_] nil)))
    (file/close f)
    (when head
      (def text (string head))
      (def stop (string/find "\n" text))
      (if stop (string/slice text 0 stop) text))))

(defn claims?
  ``Does this spec claim this file?

  By extension, and failing that BY SHEBANG for a file that has none. A shell
  script is as often `build` as `build.sh`, and an extension rule alone reads
  a repository's own scripts as data. `path` is the name; `full` is where to
  read it, and without it the shebang test is skipped -- callers that only
  have a filename keep the old behaviour.

  The shebang is consulted ONLY when there is no extension. A `.py` file
  beginning `#!/bin/sh` is a Python file someone made executable oddly, and
  the extension is the better evidence.``
  [spec path &opt full]
  (cond
    (some |(string/has-suffix? $ path) (spec :ext)) true
    (or (nil? full) (string/find "." path)) false
    (do
      (def marks (spec :shebang))
      (def line (and marks (first-line full)))
      (truthy? (and line
                    (string/has-prefix? "#!" line)
                    (some |(string/find $ line) marks))))))
