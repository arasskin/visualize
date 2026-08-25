# CSS: yes, a stylesheet references other files, three ways.
#
#   @import "theme.css"       another stylesheet, pulled in whole
#   url(bg.png)               an image, a font, a cursor, a mask
#   src: url(font.woff2)      inside @font-face, which is a url() like any
#                             other as far as this is concerned
#
# An @import is the closest thing CSS has to a module system and the others
# are assets, but the graph does not distinguish: a file the stylesheet
# cannot do without is a dependency however it was named.
#
# WHAT IS NOT A LOCAL FILE, the same list HTML keeps: an absolute URL is
# somewhere else, and a data: URI is the file itself rather than a reference
# to one. `url(#fragment)` is a reference to an SVG filter in the same
# document and names no file at all.

(import ../names)

(def- inner '(some (if-not (+ (set "()\"'") -1) 1)))

# A url() takes its argument quoted or bare, and whitespace either side.
(def- url-ref ~(* "url(" (any (set " \t\n"))
                  (+ (* `"` (<- (any (if-not `"` 1))) `"`)
                     (* "'" (<- (any (if-not "'" 1))) "'")
                     (<- ,inner))
                  (any (set " \t\n")) ")"))

# `@import` takes a bare url() or a plain string, and may carry media
# conditions after it -- `@import "print.css" print;` -- which are not part
# of the path.
(def- import-ref ~(* "@import" (some (set " \t\n"))
                     (+ (* `"` (<- (any (if-not `"` 1))) `"`)
                        (* "'" (<- (any (if-not "'" 1))) "'"))))

(defn- parse [text path]
  # Comments out first, or a commented-out @import is a dependency. CSS has
  # only the one comment form, and it does not nest.
  (def code (peg/replace-all ~(* "/*" (any (if-not "*/" 1)) "*/") " " text))

  (def found @[])
  (each hit (or (peg/match ~(any (+ ,import-ref ,url-ref 1)) (string code)) [])
    (array/push found hit))

  (def keep
    (filter (fn [ref]
              (and (not (empty? ref))
                   (not (string/find "://" ref))
                   (not (string/has-prefix? "#" ref))
                   (not (string/has-prefix? "//" ref))
                   (not (string/has-prefix? "data:" ref))))
            found))

  # NAMES, NOT PATHS. Every other spec hands `run` its captures and the
  # engine converts them; a :parse spec answers `run`'s whole job itself, so
  # it converts its own. What comes back is the dotted node name, which is
  # what the graph builder compares against the tree.
  {:imports (map |(names/from-path path $)
                 (distinct
              (map (fn [ref]
                     # Trimmed: `url( spaced.png )` is legal, and the spaces
                     # are the syntax rather than part of the name.
                     (def bare (string/trim ref))
                     (def clean (first (string/split "?" (first (string/split "#" bare)))))
                     (cond
                       (empty? clean) clean
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
  {:name "css"
   :ext [".css"]
   :skip-dirs ["node_modules" "dist" "build" "coverage" "_site"]
   :parse parse})
