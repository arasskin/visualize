# Clojure, and ClojureDart with it: the ns form is the whole story.
#
#   (ns icare.ui
#     (:require ["package:flutter/material.dart" :as m]
#               [icare.ui.shared :refer [scale-down-fade-animation]]
#               [cljd.flutter :as f]))
#
# TWO KINDS OF REQUIRE, told apart by their spelling. A SYMBOL names a
# namespace in the tree -- `icare.ui.shared` is `icare/ui/shared.cljd`,
# written from the source root the same way a python module is, so the
# scan's tail matching places it. A STRING names what the host platform
# provides -- `"package:flutter/material.dart"`, `"dart:ui"` -- which no
# tree will ever hold, so it becomes an external under a name a config can
# still group: `flutter.material`, `dart.ui`.
#
# THE DASH IS THE FILE'S UNDERSCORE. Clojure munges namespace names onto
# disk -- `icare.ui.normalized-ast` lives in `normalized_ast.cljd` -- and
# node names come from the disk, so the require is munged the same way
# before it goes looking.
#
# HAND-WALKED, NOT A PEG. Requires live inside nested, balanced forms where
# a `:refer [dart-time]` vector holds symbols that are NOT requires, and a
# string may hold anything at all; a grammar honest about all that is a
# parser, so this is one -- small, and reading only the require spans.

(import ../names)

(defn- munge-ns
  "A namespace symbol as the dotted node stem its file wears."
  [sym]
  (string/replace-all "-" "_" sym))

(defn- lib-name
  ``A string require as a groupable external name.

  `"package:flutter/material.dart"` -> `flutter.material` and `"dart:ui"`
  -> `dart.ui`: the wrapper words (`package:`, `.dart`) say nothing a node
  name needs, and what remains groups under its first segment -- `(hide
  ?.flutter)` takes every flutter package at once.``
  [text]
  (var name text)
  # `package:` AND `dart:` NAME WHAT THE PLATFORM SHIPS -- pub packages and
  # the dart runtime -- and no tree holds either, so they arrive already
  # wearing the external mark and the scan does not go looking. It went
  # looking once: `dart.ui` fell through to the leaf match and found
  # `icare/ui.cljd`, a cycle no clojure compiler would even accept. A bare
  # relative string (`"firebase_options.dart"`) stays unmarked: that one IS
  # a file beside the sources, and resolving it is the point.
  (var platform false)
  (when (string/has-prefix? "package:" name)
    (set platform true)
    (set name (string/slice name (length "package:"))))
  (when (string/has-prefix? "dart:" name)
    (set platform true))
  (when (string/has-suffix? ".dart" name)
    (set name (string/slice name 0 (- (length name) (length ".dart")))))
  (def dotted (string/replace-all ":" "." (string/replace-all "/" "." name)))
  (if platform (names/external dotted) dotted))

# One character wide, so the walkers below can ask cheaply.
(defn- ws? [b] (or (= b 32) (= b 9) (= b 10) (= b 13) (= b 44)))  # , is whitespace in clojure
(defn- open? [b] (or (= b 40) (= b 91) (= b 123)))                # ( [ {
(defn- close? [b] (or (= b 41) (= b 93) (= b 125)))               # ) ] }

(defn- blank-comments
  ``The text with `;` comments spaced out, strings left whole.

  The require spans are read from this, so a commented-out require -- and
  icare has one, sitting inside a live :require form -- produces nothing.
  Done by hand rather than by PEG because a `;` inside a string is not a
  comment, and a string require is exactly the thing that must survive.``
  [text]
  (def out (buffer text))
  (def n (length text))
  (var i 0)
  (var in-string false)
  (while (< i n)
    (def b (get text i))
    (cond
      in-string
      (do (when (= b 92) (++ i))          # \" inside a string
          (when (= b 34) (set in-string false)))
      (= b 34) (set in-string true)
      (= b 59)                            # ; -- blank to end of line
      (while (and (< i n) (not= (get text i) 10))
        (put out i 32)
        (++ i)))
    (++ i))
  (string out))

(defn- read-token
  "The symbol starting at `i`, and where it ended."
  [text i]
  (def n (length text))
  (var j i)
  (while (and (< j n)
              (not (ws? (get text j)))
              (not (open? (get text j)))
              (not (close? (get text j))))
    (++ j))
  [(string/slice text i j) j])

(defn- skip-form
  "Past the balanced form opening at `i`, strings respected."
  [text i]
  (def n (length text))
  (var depth 0)
  (var j i)
  (var in-string false)
  (while (< j n)
    (def b (get text j))
    (cond
      in-string (do (when (= b 92) (++ j))
                    (when (= b 34) (set in-string false)))
      (= b 34) (set in-string true)
      (open? b) (++ depth)
      (close? b) (do (-- depth) (when (zero? depth) (break))))
    (++ j))
  (inc j))

(defn- read-string-at
  "The contents of the string literal opening at `i`, and where it ended."
  [text i]
  (def n (length text))
  (def out @"")
  (var j (inc i))
  (while (< j n)
    (def b (get text j))
    (cond
      (= b 92) (do (++ j) (buffer/push-byte out (get text j)))
      (= b 34) (break)
      (buffer/push-byte out b))
    (++ j))
  [(string out) (inc j)])

(defn- parse [text path]
  (def clean (blank-comments text))
  (def n (length clean))
  (def out @[])
  # Every require span: `(:require ...)` and the older `(:use ...)`.
  (each word ["(:require" "(:use"]
    (var from 0)
    (while (def at (string/find word clean from))
      (def end (skip-form clean at))
      # Inside the span, each entry is one require: a vector or list whose
      # FIRST element is the name (the :as and :refer behind it are local
      # business), a bare string, or a bare symbol.
      (var i (+ at (length word)))
      (while (< i (min end n))
        (def b (get clean i))
        (cond
          (ws? b) (++ i)
          (close? b) (++ i)
          (open? b)
          (do
            # The entry's head, then past the whole entry.
            (var j (inc i))
            (while (and (< j n) (ws? (get clean j))) (++ j))
            (if (= (get clean j) 34)
              (let [[lib _] (read-string-at clean j)]
                (unless (empty? lib) (array/push out (lib-name lib))))
              (let [[sym _] (read-token clean j)]
                (unless (or (empty? sym) (string/has-prefix? ":" sym))
                  (array/push out (munge-ns sym)))))
            (set i (skip-form clean i)))
          (= b 34)
          (let [[lib j] (read-string-at clean i)]
            (unless (empty? lib) (array/push out (lib-name lib)))
            (set i j))
          # A bare symbol require, or a keyword that is not one.
          (let [[sym j] (read-token clean i)]
            (unless (or (empty? sym) (string/has-prefix? ":" sym))
              (array/push out (munge-ns sym)))
            (set i j))))
      (set from end)))
  {:imports (distinct out)})

(def spec
  {:name "clojure"
   :ext [".cljd" ".clj" ".cljc"]
   # `cljd-out` is ClojureDart's transpiled Dart -- build output that
   # shadows the real answer: `cljd.flutter` is a library from deps.edn,
   # and its compiled copy under lib/cljd-out/ was capturing the name that
   # should have stayed an external.
   :skip-dirs [".cpcache" ".clj-kondo" ".lsp" "target" "cljd-out"]
   :imports-are :modules
   :parse parse})
