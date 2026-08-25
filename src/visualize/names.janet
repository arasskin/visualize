# What a node is called, and nothing else.
#
# THE CANONICAL NAME IS THE DOTTED PATH. `src/visualize/color.janet` is the
# node `src.visualize.color`, and every part of this program spells it that
# way: the graph, the labels, the config a person types. A name carries no
# extension, because a file and the thing that imports it must land on one
# node and only the importer's spelling varies.
#
# WHY THIS IS ITS OWN MODULE. Both sides of the scan need it. `scan.janet`
# names the files it walks; the PARSERS name what those files reference --
# each in its own language's terms, since only the Janet parser knows that
# `./term/client` means a path and only the Python parser knows that
# `otto.store` already IS one. scan.janet imports the parsers, so the
# parsers cannot import scan.janet, and a shared bottom is the way round
# that.
#
# THE PARSERS RETURN THESE NAMES, not raw specifiers. That is the whole
# point of the arrangement: a parser reads its language and answers in the
# one vocabulary the graph speaks, so nothing downstream has to guess what a
# string meant. Guessing is what put `external-src.janet.janet.c` on the
# graph -- a path run through a dotted-module rule, its extension read as a
# package separator -- beside the real file it had failed to match.

(defn resolve-relative
  ``A relative import specifier, resolved against the importing file's path.

  `test/scan.janet` importing `../visualize/color` gives `visualize/color`, which is the
  node the scan already made for that file. Without this the specifier is
  flattened as written and becomes a node nothing else refers to.

  Any extension on the specifier is dropped, since node names carry none.``
  [from-rel module]
  (def parts (string/split "/" from-rel))
  # Start in the importing file's DIRECTORY, hence dropping its own name.
  (def stack (array ;(slice parts 0 (max 0 (- (length parts) 1)))))
  (each piece (string/split "/" module)
    (cond
      (or (= piece ".") (= piece "")) nil
      (= piece "..") (when (> (length stack) 0) (array/pop stack))
      (array/push stack piece)))
  (def joined (string/join stack "/"))
  # Drop a trailing extension the same way `node-name` does, so `./a.js` and
  # `./a` land on the same node.
  (if-let [dot (last (string/find-all "." joined))]
    (if (> dot (or (last (string/find-all "/" joined)) -1))
      (string/slice joined 0 dot)
      joined)
    joined))

(defn safe-name
  ``A path or module specifier as a node name: separators become dots.

  `src/visualize/color.janet` -> `src.visualize.color`, `github.com/lib/pq`
  -> `github.com.lib.pq`, `./store` -> `store`.

  ONE SPELLING EVERYWHERE, which is the point. This used to flatten to
  UNDERSCORES -- `src_visualize_color` -- while the label showed
  `src/visualize/color` and the config was written `src.visualize.color`, so
  a path had three forms and only one of them was ever visible. The dot is
  the one the config already used, it survives a DOT identifier as long as
  the name is quoted (which `layout/to-dot` does), and it is what a reader
  types after seeing the picture.

  Leading and trailing dots are trimmed and runs collapsed, so `./store` and
  `@scope/pkg` do not come back wearing punctuation they never had.

  HYPHENS SURVIVE. A directory called `demo-api` is one name, not two: with
  the hyphen swept into a dot it became `demo.api.worker`, which reads as a
  directory `demo` that does not exist and breaks the prefix a config would
  write. The old underscore flattening had the same bug in reverse (it made
  `demo-api_worker`, which graphviz then rejected) -- quoting the name is
  what lets the hyphen simply stay.``
  [text]
  (def dotted
    (string
      (peg/replace-all ~(if-not (+ (range "AZ") (range "az") (range "09") "_" "-" ".") 1)
                       "." text)))
  # `./store` becomes `..store` on the way through; collapse and trim so the
  # name is the shape the config language expects.
  (var out dotted)
  (while (string/find ".." out)
    (set out (string/replace-all ".." "." out)))
  (string/trim out "."))

(defn node-name
  ``A file's path as its DOT node name.

  `OttoClip/CartWebView.swift` -> `OttoClip.CartWebView`. DOT identifiers
  cannot carry a separator unquoted, so the path is flattened to dots -- the
  same shape the labels wear and the config is written in, which is what
  makes `(hide OttoClip.)` a thing you can type after reading the drawing.

  THE FLATTENING IS LOSSY and deliberately so: `OttoClip.Cart` could have been
  `OttoClip/Cart.swift` or `OttoClip.Cart.swift`, and nothing in the name says
  which. Everything that needs the real path therefore works FORWARD from the
  file list rather than backward from a node name.``
  [rel]
  (def without-ext
    (if-let [dot (last (string/find-all "." rel))]
      (if (> dot (or (last (string/find-all "/" rel)) -1))
        (string/slice rel 0 dot)
        rel)
      rel))
  (safe-name without-ext))

(defn from-path
  ``A PATH a file referenced, as the node name it means.

  `from` is the referencing file, repo-relative, so `./b` and `../c/d`
  resolve against the right directory. A path that starts at the repo root
  (`external-src/janet/janet.c`) is taken as it stands.

  This is what a parser whose imports are PATHS calls -- javascript, css,
  html, janet, bash. The extension goes, the separators become dots, and
  what comes back is the same name the file itself would be given, which is
  what makes the two match.``
  [from path]
  (if (string/has-prefix? "." path)
    (safe-name (resolve-relative from path))
    (node-name path)))

(defn from-module
  ``A MODULE NAME a file imported, as the node name it means.

  `otto.store` is already the canonical spelling and comes back untouched;
  `github.com/lib/pq` has its separators swapped for dots like any other
  path. Nothing is resolved against the importing file, because a module
  name is not relative to anything.

  This is what a parser whose imports are NAMES calls -- python, go, swift.
  A name that matches no file in the tree stays an external, which is the
  right answer for `fmt` and `Foundation`.``
  [module]
  (safe-name (string/replace-all "." "/" module)))
