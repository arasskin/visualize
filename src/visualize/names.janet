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

(defn stem
  ``A path with its extension taken off, or unchanged if it has none.

  Only a FINAL dot after the last slash counts, so `a.b/c` keeps its dot and
  `./x.js` loses one.``
  [rel]
  (if-let [dot (last (string/find-all "." rel))]
    (if (> dot (or (last (string/find-all "/" rel)) -1))
      (string/slice rel 0 dot)
      rel)
    rel))

(defn resolve-relative
  ``A relative import specifier, resolved against the importing file's path.

  `test/scan.janet` importing `../visualize/color` gives `visualize/color`, which is the
  node the scan already made for that file. Without this the specifier is
  flattened as written and becomes a node nothing else refers to.

  THE EXTENSION IS DROPPED, so `./a.js` and `./a` -- the two ways the same
  import gets written -- come out identical. That makes this a STEM rather
  than a node name, which is deliberate: node names keep their extension
  (see `node-name`) and an import usually does not say it, so the stem is
  the only spelling both sides can agree on. `build` in scan.janet resolves
  it against the file list.``
  [from-rel module]
  (def parts (string/split "/" from-rel))
  # Start in the importing file's DIRECTORY, hence dropping its own name.
  (def stack (array ;(slice parts 0 (max 0 (- (length parts) 1)))))
  (each piece (string/split "/" module)
    (cond
      (or (= piece ".") (= piece "")) nil
      (= piece "..") (when (> (length stack) 0) (array/pop stack))
      (array/push stack piece)))
  (stem (string/join stack "/")))

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

(defn extension
  "A path's extension without the dot, or nil when it has none."
  [rel]
  (def cut (stem rel))
  (when (not= cut rel) (string/slice rel (+ 1 (length cut)))))

(defn node-name
  ``A file's path as its DOT node name, EXTENSION AND ALL.

  `OttoClip/CartWebView.swift` -> `OttoClip.CartWebView.swift`. DOT
  identifiers cannot carry a separator unquoted, so the path is flattened to
  dots -- the same shape the labels wear and the config is written in, which
  is what makes `(hide OttoClip.)` a thing you can type after reading the
  drawing.

  THE EXTENSION STAYS because dropping it merged files that are not the same
  file. This repo has `visualize` (the launcher) beside `visualize.conf`
  (the drawing's own source), and they answered to one node; janet's vendored
  source is worse, with `janet`, `janet.c` and `janet.h` collapsing to a
  single point that claimed to be all three. A graph that silently unions
  distinct files is lying about the thing it exists to show.

  What that costs is that an import must still find its file: `./store`
  names `store.js` and does not say so. `build` in scan.janet keeps a map
  from stem to full name for exactly that, so the matching is done where the
  file list is known rather than by guessing here.``
  [rel]
  (safe-name rel))

(defn from-path
  ``A PATH a file referenced, as the STEM of the node it means.

  `from` is the referencing file, repo-relative, so `./b` and `../c/d`
  resolve against the right directory. A path that starts at the repo root
  (`external-src/janet/janet.c`) is taken as it stands.

  This is what a parser whose imports are PATHS calls -- javascript, css,
  html, janet, bash.

  A STEM, not a finished node name, and the difference matters. Node names
  keep their extension so that `visualize` and `visualize.conf` stay two
  nodes; an import mostly does NOT write the extension -- `./store` means
  store.js -- so the two spellings only meet with it removed. `build` in
  scan.janet holds the map from stem to real node and does the joining
  there, where the file list is known.``
  [from path]
  # THE EXTENSION COMES OFF WHILE SLASHES STILL MARK THE BOUNDARY. Flatten
  # first and `src/web/graph.js` is `src.web.graph.js`, whose "extension" is
  # `js` by the same rule that makes `graph` look like a directory -- taking
  # it off then gives `src.web.graph`, but taking it off after another dot
  # has been introduced eats a real segment. `resolve-relative` already
  # returns a stem; a rooted path is stemmed here.
  (safe-name (if (string/has-prefix? "." path)
               (resolve-relative from path)
               (stem path))))

(defn from-module
  ``A MODULE NAME a file imported, as the node name it means.

  `otto.store` is already the canonical spelling and comes back untouched;
  `github.com/lib/pq` has its separators swapped for dots like any other
  path. Nothing is resolved against the importing file, because a module
  name is not relative to anything.

  This is what a parser whose imports are NAMES calls -- python, go, swift.
  A module name carries no extension to begin with, so what comes back is
  already a stem and is looked up the same way. A name matching no file
  stays an external, which is right for `fmt` and `Foundation`.``
  [module]
  (safe-name (string/replace-all "." "/" module)))
