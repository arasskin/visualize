# HTML: what a page pulls in, read off the attributes that pull it.
#
# A page's dependencies are written as `src` and `href`, and the tag decides
# what kind of thing arrived: `<script src>` is code, `<link href>` is a
# stylesheet, `<img src>` is an image. The graph does not care which -- a file
# the page cannot do without is a dependency however it was named -- so this
# reads the attribute and leaves the tag alone.
#
# WHAT IT LEAVES OUT is as deliberate as what it takes:
#
#   <a href>      a link to another PAGE is navigation, not a dependency. A
#                 site's every page linking every other draws a mesh that
#                 says only that a nav bar exists.
#   http://...    somewhere else entirely, like an absolute path.
#   #anchor       a place in this page.
#   data:, mailto: not files.
#
# `<a>` is the one that needs the tag, then, and it is excluded by matching
# the attribute WITH its tag rather than on its own.

(import ../names)

(def- attr-char '(if-not (+ (set " \t\n\"'<>") -1) 1))
(def- value ~(some ,attr-char))

# A quoted or bare attribute value, captured. Bare is rare in hand-written
# HTML and legal, so it is read too.
(def- quoted ~(+ (* `"` (<- ,value) `"`)
                 (* "'" (<- ,value) "'")
                 (<- ,value)))

# The attributes that name a file the page needs. `href` is here for `<link>`
# and excluded for `<a>` below; the rest are unambiguous.
(def- fetching ~(+ "src" "href" "poster" "data" "srcset"))

# THE IMPORT MAP IS A DICTIONARY FROM NAME TO PATH, and the page carries it
# in plain sight: `<script type="importmap">` holding JSON. A module written
# `import ... from '@wterm/dom'` names no file, and without this the scan can
# only draw it as an external -- a bare `wterm.dom` node beside the vendored
# file it actually loads.
#
# Read with a PEG rather than a JSON parser: the shape wanted is a flat
# string-to-string table under "imports", every value of which is a URL the
# page will fetch. Anything more elaborate (scopes, integrity) is skipped
# rather than half-understood.
(defn- import-map [text]
  (def maps @{})
  # The opening tag's attributes and the body that follows it, as a pair per
  # script element. Captured separately because the type has to be READ --
  # matching "importmap" inside the tag with a greedy scan to `>` swallows
  # the word itself and finds nothing.
  (def blocks
    (peg/match ~(any (+ (* "<script" (<- (any (if-not ">" 1))) ">"
                           (<- (any (if-not "</script" 1))))
                        1))
               text))
  (each [attrs block] (partition 2 (or blocks []))
    (when (string/find "importmap" (string/ascii-lower attrs))
    (each [name target]
      (partition 2 (or (peg/match
                         ~(any (+ (* `"` (<- (some (if-not `"` 1))) `"`
                                     (any (set " \t\n")) ":" (any (set " \t\n"))
                                     `"` (<- (some (if-not `"` 1))) `"`)
                                  1))
                         block) []))
      # A trailing-slash entry maps a PREFIX rather than a name, which is a
      # different rule; only exact names are taken.
      (unless (or (string/has-suffix? "/" name) (string/has-suffix? "/" target))
        (put maps name target)))))
  maps)

# A URL THE PAGE FETCHES, as a path this scan can look for.
#
# A SITE-ABSOLUTE PATH IS ROOTED AT WHAT IS SERVED, not at the tree being
# scanned -- this repo's page asks for `/app.js` and the file is its sibling,
# because the server maps / to the directory holding them. There is no way to
# read that mapping from here, and a sibling is the likelier of the two: a
# static site is usually served from the directory its pages sit in.
(defn- site-path [url]
  (def clean (first (string/split "?" (first (string/split "#" url)))))
  (cond
    (empty? clean) clean
    (string/has-prefix? "/" clean) (string "./" (string/slice clean 1))
    (string/has-prefix? "." clean) clean
    (string "./" clean)))

(defn- parse [text path]
  # A tag is what an attribute belongs to, so the exclusion of `<a href>` is
  # done by finding the tags first and skipping the anchors -- an attribute
  # scan alone cannot tell one href from another.
  (def found @[])
  (def tags (peg/match ~(any (+ (<- (* "<" (some (if-not ">" 1)) ">")) 1)) text))
  (each tag (or tags [])
    (def name (first (or (peg/match ~(* "<" (? "/") (<- (some (range "az" "AZ")))) tag) [])))
    # An anchor's href is navigation. Every other tag's is a file.
    (when (and name (not= (string/ascii-lower name) "a"))
      (each hit (or (peg/match ~(any (+ (* (+ ,;(map |(string $ "=") ["src" "href" "poster" "data"]))
                                           ,quoted)
                                        1))
                               tag) [])
        (array/push found hit))))

  # WHAT IS NOT A LOCAL FILE. An absolute URL is somewhere else, an anchor is
  # a place in this page, and a data: URI is the file itself rather than a
  # reference to one.
  #
  # A TEMPLATE HOLE IS NOT A FILENAME EITHER. An html file that a server fills
  # in before serving carries `{{...}}` where a value will go, and one of
  # those in an href is a promise about the response, not a reference to
  # anything on disk -- `href="{{FAVICON}}"` became a node called FAVICON,
  # drawn as though the page depended on a file by that name. Whatever the
  # hole is finally filled with is the server's business and may not be a
  # path at all; this one becomes a data: URI, which the line above would
  # have refused had the scan seen it.
  (def keep
    (filter (fn [ref]
              (and (not (empty? ref))
                   (not (string/find "://" ref))
                   (not (string/has-prefix? "#" ref))
                   (not (string/has-prefix? "//" ref))
                   (not (string/has-prefix? "data:" ref))
                   (not (string/has-prefix? "mailto:" ref))
                   (not (string/has-prefix? "tel:" ref))
                   (not (string/find "{{" ref))
                   # AND A HOLE THE PAGE'S OWN JAVASCRIPT FILLS. `src="${esc
                   # (t.image)}"` is a template literal evaluated in the
                   # browser, and reading it as a path invented `esc/t` -- a
                   # node named after the escaping helper that happened to sit
                   # inside the braces. `<%` and `{%` are the same promise in
                   # the other template dialects a page may be written in.
                   (not (string/find "${" ref))
                   (not (string/find "<%" ref))
                   (not (string/find "{%" ref))))
            found))

  # Relative, so the scanner resolves against the importing file -- see
  # resolve-relative in src/visualize/scan.janet. An absolute path is rooted
  # at the site rather than at the tree, and is closer to root-relative than
  # to a sibling.
  # NAMES, NOT PATHS. Every other spec hands `run` its captures and the
  # engine converts them; a :parse spec answers `run`'s whole job itself, so
  # it converts its own. What comes back is the dotted node name, which is
  # what the graph builder compares against the tree.
  # WHAT A NAME MEANS, for the modules this page's own scripts import. The
  # values are URLs the server will answer, so they are named the same way a
  # site-absolute href is -- see `site-path` above.
  # KEYED THE WAY AN IMPORT ARRIVES. A javascript file writing
  # `from '@wterm/dom'` is converted by its own parser before the graph sees
  # it, so the key stored here has to be that converted form -- the raw
  # specifier would never match. `safe-name` is the same rule the javascript
  # spec applies to a bare package name.
  {:aliases (let [out @{}]
              (eachp [name target] (import-map text)
                (put out (names/safe-name name)
                     (names/from-path path (site-path target))))
              out)
   :imports (map |(names/from-path path $)
                 (distinct
              (map (fn [ref]
                     (def clean (first (string/split "?" (first (string/split "#" ref)))))
                     (cond
                       # A SITE-ABSOLUTE PATH IS ROOTED AT WHAT IS SERVED,
                       # not at the tree being scanned -- this repo's page
                       # asks for `/app.js` and the file is its sibling,
                       # because the server maps / to the directory holding
                       # them. There is no way to read that mapping from
                       # here, and a sibling is the likelier of the two: a
                       # static site is usually served from the directory
                       # its pages sit in. Read as relative, so `/app.js`
                       # finds the app.js next door rather than inventing
                       # one at the root.
                       (string/has-prefix? "/" clean) (string "./" (string/slice clean 1))
                       (string/has-prefix? "." clean) clean
                       (string "./" clean)))
                   keep)))})

(def spec
  {:name "html"
   :ext [".html" ".htm"]
   # NOT `public`, though a generated site often has one. Skip lists are
   # merged across every spec and applied to the whole walk, so this one
   # entry hid `otto/resources/public/app.css` -- a served stylesheet the
   # page beside it depends on, and a CSS file the css spec never asked to
   # skip. A directory named for what it SERVES holds sources as often as
   # output; `dist` and `_site` name the output itself and stay.
   :skip-dirs ["node_modules" "dist" "build" "coverage" "_site"]
   :parse parse})
