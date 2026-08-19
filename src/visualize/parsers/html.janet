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

(defn- parse [text _path]
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
  (def keep
    (filter (fn [ref]
              (and (not (empty? ref))
                   (not (string/find "://" ref))
                   (not (string/has-prefix? "#" ref))
                   (not (string/has-prefix? "//" ref))
                   (not (string/has-prefix? "data:" ref))
                   (not (string/has-prefix? "mailto:" ref))
                   (not (string/has-prefix? "tel:" ref))))
            found))

  # Relative, so the scanner resolves against the importing file -- see
  # resolve-relative in src/visualize/scan.janet. An absolute path is rooted
  # at the site rather than at the tree, and is closer to root-relative than
  # to a sibling.
  {:imports (distinct
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
                   keep))})

(def spec
  {:name "html"
   :ext [".html" ".htm"]
   :skip-dirs ["node_modules" "dist" "build" "coverage" "_site" "public"]
   :parse parse})
