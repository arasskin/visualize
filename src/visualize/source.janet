# The source tree, read: every file, every dependency, every line count.
#
# THE PARSING STEP, WHOLE. What languages this program knows and how a tree
# becomes a graph both live here, and nothing above this line has to know
# either. src/visualize/graph.janet asks for a graph and gets one; it cannot
# name a parser, and does not have to be edited when a language is added.
#
# That split is why the specs list moved out of graph. A module that draws a
# picture was importing six parsers to hand them straight to the scanner --
# so adding a language meant editing the renderer, and reading the renderer
# meant scrolling past a list of languages.

(import ./scan)
(import ./parsers/visualize-bash :as bash)
(import ./parsers/go :as go)
(import ./parsers/janet :as janet-lang)
(import ./parsers/javascript :as javascript)
(import ./parsers/python :as python)
(import ./parsers/swift :as swift)

(def specs
  ``Every language this program can read, in name order.

  A LIST, not a directory scan. This used to be src/parsers.janet: a loader
  that walked the parsers directory at runtime, dofile'd whatever it found,
  unwrapped a `spec` export through two possible shapes, and tolerated a
  broken file by skipping that language -- a plugin system for six files
  that ship in this repo and change when someone edits this line anyway.
  Adding a language is now an import and an entry here, which is the same
  amount of editing the loader was avoiding, minus the machinery.``
  [bash/spec go/spec janet-lang/spec javascript/spec python/spec swift/spec])

(defn languages
  "Their names, for the startup banner."
  []
  (map |($ :name) specs))

# The scan's output for a given source tree never varies -- same files, same
# graph, every time. It is fast, but it is still pointless to redo per edit
# when only the post-processing changes. `forget` is how you say the SOURCE
# changed and this is stale.
#
# THE CACHE LIVES WITH THE SCAN, not with the renderer that happened to want
# one. A drawing is a pure function of the graph and the config; which of
# those was cached is not the drawing's business.
(var- cached nil)

(defn graph-of
  ``The dependency graph of `root`, scanned once and remembered.

  Returns what scan/scan returns -- {:nodes :edges :sizes :ours} or a table
  carrying :error.``
  [root]
  (unless cached
    (set cached (scan/scan root specs)))
  cached)

(defn forget
  "Drop the cached scan, so the next read re-walks the source tree."
  []
  (set cached nil))

(defn fingerprint-of
  ``What the watcher compares to notice the tree changed.

  Here rather than in the watcher because it is the same question the scan
  asks -- which files does this tree hold -- and the parser list is the
  thing that answers it.``
  [root]
  (scan/find-files root specs))
