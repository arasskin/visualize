# The parser engine and the specs that ride on it.
#
# The Swift cases here are the ones that were WRONG at some point during the
# port, kept so they cannot go wrong again quietly. Each is a false edge the
# graph would otherwise have drawn with total confidence.

(import ../visualize/parser :as parser)
(import ../visualize/scan)
(import ../visualize/parsers/swift)
(import ../visualize/parsers/python)
(import ../visualize/parsers/go)
(import ../visualize/parsers/arduino)
(import ../visualize/parsers/html :as html)
(import ../visualize/parsers/css :as css)
(import ../visualize/parsers/javascript :as js)
(import ../visualize/parsers/visualize-lang :as vz)
(import ./harness :as t)

(defn- swift [text] (parser/run swift/spec text "T.swift"))

(t/test "swift finds the declarations another file can name"
  (def got (swift ``
public final class CartWebView: UIView {}
struct Small {}
indirect enum Tree { case leaf }
protocol Feeder {}
actor Worker {}
typealias Handler = () -> Void
``))
  (t/is= ["CartWebView" "Feeder" "Handler" "Small" "Tree" "Worker"]
         (sorted (got :declares))))

(t/test "an extension declares NOTHING"
  # The bug this exists for: `private extension Color` handed the file
  # ownership of Color and invented edges from every file using a SwiftUI
  # colour. Extending someone else's type is the common case in Swift.
  (def got (swift "private extension Color { var x: Int { 1 } }\n"))
  (t/is= [] (sorted (got :declares))))

(t/test "`import struct Foundation.Data` declares nothing"
  # It contains the word `struct`, so an unanchored declaration pattern reads
  # it as declaring Foundation -- handing the framework node to whichever file
  # imported it.
  (def got (swift "import struct Foundation.Data\n"))
  (t/is= [] (got :declares))
  (t/is= ["Foundation"] (got :imports) "the node is the framework, not the symbol"))

(t/test "a declaration must start a line"
  # A keyword inside an expression is not a declaration.
  (t/is= [] ((swift "let x = makeStruct Thing\n") :declares)))

(t/test "comments and string literals never produce references"
  # The reason this matters: a Swift file embedding a JS program in a string
  # contains capitalised words that are not Swift references to anything.
  (def got (swift ``
// mentions FakeType
/* mentions BlockFake */
let js = "HTMLInputElement and Event"
let real = RetailerConfig()
``))
  (t/ok (index-of "RetailerConfig" (got :refs)) "a real mention survives")
  (each ghost ["FakeType" "BlockFake" "HTMLInputElement" "Event"]
    (t/ok (not (index-of ghost (got :refs)))
          (string ghost " must not be a reference"))))

(t/test "blanking noise preserves every byte offset"
  # Replaced with spaces rather than deleted, so a token can never be glued to
  # its neighbour: Foo"bar"Baz must not become FooBaz.
  (def text `Foo"bar"Baz`)
  (def clean (parser/blank-noise (swift/spec :noise) text))
  (t/is= (length text) (length clean))
  (t/ok (not (string/find "FooBaz" clean)) "tokens stay apart"))

(t/test "python reads its imports"
  (def got (parser/run python/spec ``
import os
import os.path
from otto.store import Cart
from . import sibling
`` "t.py"))
  (t/ok (index-of "os" (got :imports)))
  (t/ok (index-of "otto.store" (got :imports)) "dotted modules stay whole")
  # BOTH READINGS, because the syntax does not say which one it is: `Cart`
  # here is a class, but `cart` in `from otto.mcp import cart` is a file, and
  # the two lines are the same shape. The scan keeps whichever names a file
  # -- see "an imported name that is a class is not a node" below.
  (t/ok (index-of "otto.store.Cart" (got :imports)) "the symbol reading too"))

(t/test "a parenthesised import list spans lines"
  # THE FORM A LONG IMPORT IS ACTUALLY WRITTEN IN, and the line-anchored
  # pattern this replaced could only ever see its first line -- so
  # `store_order` and `store_retailer` below were silently dropped, and the
  # files they name looked like nothing imported them.
  (def got (parser/run python/spec ``
from otto import (
    store_cart,
    store_order,
    store_retailer,
)
`` "t.py"))
  (t/ok (index-of "otto.store_cart" (got :imports)))
  (t/ok (index-of "otto.store_order" (got :imports)) "past the first line")
  (t/ok (index-of "otto.store_retailer" (got :imports)) "and the last"))

(t/test "an alias names no file"
  (def got (parser/run python/spec "from otto import store_cart as sc\n" "t.py"))
  (t/ok (index-of "otto.store_cart" (got :imports)) "the thing renamed")
  (t/ok (not (index-of "otto.sc" (got :imports))) "not the local name"))

(t/test "an import that IS a string literal survives the noise pass"
  # THE BUG THIS EXISTS FOR: blanking string literals before reading imports
  # erased every import in Go and JavaScript, because in both languages the
  # module path is a quoted string. Declarations and references still get the
  # strings blanked; imports get only the comments blanked. See src/parser.janet.
  (def got (parser/run go/spec ``
import "fmt"

import (
	"os"
	m "math"
	_ "github.com/lib/pq"
)

// import "commented-out"
`` "a.go"))
  (t/is= ["fmt" "github.com.lib.pq" "math" "os"] (sorted (got :imports)))

(t/test "arduino reads every include and no commented or quoted one"
  (def got (parser/run arduino/spec ``
#include <Servo.h>
#  include "pins.h"
// #include <Commented.h>
/* #include <Blocked.h> */
const char *note = "#include <InAString.h>";
`` "sketch.ino"))
  (t/is= ["Servo" "pins"] (sorted (got :imports))))

(t/test "arduino declares the names another tab can call"
  # A sketch's tabs are concatenated before compiling, so a second tab's
  # function is callable from the first with no include anywhere -- these
  # names are the only thing those edges can be drawn from.
  (def got (parser/run arduino/spec ``
struct Reading { int raw; };
class Motor { public: void spin(); };
enum Mode { IDLE, RUN };
typedef struct Packet { int id; } Packet;
namespace nav { }
int readSensor() { return analogRead(A0); }
static void calibrate() { }
unsigned long lastAt() { return millis(); }
unsigned int count() { }
String label() { return "x"; }
`` "tab.ino"))
  (t/is= ["Mode" "Motor" "Packet" "Reading" "calibrate" "count" "label"
          "lastAt" "nav" "readSensor"]
         (sorted (got :declares))))

(t/test "arduino declares neither setup, loop, nor a control-flow keyword"
  # setup and loop are called by the runtime rather than by another tab, so
  # owning them would make every tab depend on whichever one defined them.
  # The rest are the false declarations a looser pattern invents: `if (x)`
  # reads exactly like a call, and `for (int i = 0; ...)` like a definition.
  (def got (parser/run arduino/spec ``
void setup() { }
void loop() { }
if (ready) { }
while (running) { }
for (int i = 0; i < n; i++) { }
digitalWrite(LED, HIGH);
`` "sketch.ino"))
  (t/is= [] (sorted (got :declares))))

(t/test "arduino claims sketches and leaves C and C++ alone"
  # .h and .cpp belong to every project in the world, not to Arduino --
  # claiming them would scan this repo's own janet.c as a sketch.
  (t/ok (parser/claims? arduino/spec "blink/blink.ino"))
  (t/ok (parser/claims? arduino/spec "old/sketch.pde"))
  (t/ok (not (parser/claims? arduino/spec "external-src/janet/janet.c")))
  (t/ok (not (parser/claims? arduino/spec "lib/thing.h")))
  (t/ok (not (parser/claims? arduino/spec "lib/thing.cpp"))))
  (t/ok (not (index-of "commented-out" (got :imports)))
        "a commented import is still not an import"))

(t/test "javascript takes every import shape, each as the node it names"
  (def got (parser/run js/spec ``
import React from 'react'
import { a, b } from "./store"
import type { T } from '../lib/api'
import './side-effect.css'
export { x } from './other'
const fs = require('fs')
// import Fake from 'nope'
`` "a.ts"))
  (t/is= ["fs" "lib.api" "other" "react" "side-effect" "store"]
         (sorted (got :imports)))
  (t/ok (not (index-of "nope" (got :imports))))
  (t/ok (not (index-of "T" (got :imports))) "the binding is not the module"))

(t/test "a node name is the path, dotted"
  # ONE SPELLING. The name, the label and the config prefix are all the
  # dotted path now: a node reads `src.visualize.color`, answers to
  # `src.visualize.color`, and is grouped by typing what is on it. Names used
  # to flatten to underscores while labels showed slashes, so a path had
  # three forms and only one was ever visible.
  #
  # Import specifiers are the hard cases: `github.com/lib/pq`, `./store`,
  # `@scope/pkg` -- and a directory called `demo-api`, whose hyphen is part
  # of one name rather than a separator between two.
  (t/is= "demo-api.worker.js" (scan/node-name "demo-api/worker.js")
         "a hyphen is part of the name, not a separator")
  (t/is= "OttoClip.CartWebView.swift" (scan/node-name "OttoClip/CartWebView.swift"))
  (t/is= "github.com.lib.pq" (scan/safe-name "github.com/lib/pq"))
  (t/is= "store" (scan/safe-name "./store")
         "a leading ./ leaves no punctuation behind")
  (t/is= "scope.pkg" (scan/safe-name "@scope/pkg"))
  (each name [(scan/node-name "demo-api/worker.js")
              (scan/safe-name "github.com/lib/pq")
              (scan/safe-name "@scope/pkg")]
    (t/ok (peg/match ~(* (some (+ (range "AZ") (range "az") (range "09")
                                  "_" "-" "."))
                         -1)
                     name)
          (string name " must be a name the config can prefix-match"))
    (t/ok (not (string/find ".." name))
          (string name " must not carry a run of dots"))
    (t/ok (not (string/has-prefix? "." name))
          (string name " must not start with a dot"))))

(t/test "a relative import resolves to the file it names"
  # Flattened as written, `../visualize/color` becomes the node `___visualize_color`
  # -- a phantom external nothing matches, instead of an edge to the
  # visualize/color the scan already found. Which file it means depends on
  # where the importer sits.
  (t/is= "visualize/color" (scan/resolve-relative "test/scan.janet" "../visualize/color"))
  (t/is= "visualize/b" (scan/resolve-relative "visualize/a.janet" "./b"))
  (t/is= "x" (scan/resolve-relative "a/b/c.js" "../../x"))
  (t/is= "y" (scan/resolve-relative "x.js" "./y.js")
         "an extension on the specifier is dropped, as node names carry none"))

(t/test "a spec claims files by extension"
  (t/ok (parser/claims? swift/spec "a/b/C.swift"))
  (t/ok (not (parser/claims? swift/spec "a/b/C.py")))
  (t/ok (parser/claims? python/spec "a/b/C.py")))

(t/test "a :parse function overrides the PEGs entirely"
  (def fake {:name "fake" :ext [".x"]
             :parse (fn [text path] {:declares ["D"] :imports ["I"] :refs ["R"]})})
  (t/is= {:declares ["D"] :imports ["I"] :refs ["R"]}
         (parser/run fake "anything at all" "a.x")))

(t/test "html reads what a page pulls in"
  # NODE NAMES, not the specifiers read -- see the css test above and the
  # :imports-are contract in parser.janet.
  (defn imports [text] (((html/spec :parse) text "page.html") :imports))

  (t/is= ["theme" "app"]
         (imports `<link rel="stylesheet" href="theme.css"><script src="./app.js"></script>`)
         "a stylesheet and a script")
  (t/is= ["logo"] (imports `<img src="logo.png">`) "and an image")
  (t/is= ["clip" "thumb"]
         (sort (imports `<video poster="thumb.jpg" src="clip.mp4"></video>`)))

  # A LINK TO ANOTHER PAGE IS NAVIGATION, not a dependency: a site whose
  # every page links every other draws a mesh saying only that a nav bar
  # exists. `href` is a file everywhere EXCEPT on an anchor.
  (t/is= [] (imports `<a href="about.html">about</a>`))
  (t/is= ["theme"]
         (imports `<a href="about.html">x</a><link href="theme.css">`)
         "which is decided by the tag, not the attribute")

  # Not files.
  (t/is= [] (imports `<script src="https://cdn.example.com/lib.js"></script>`))
  (t/is= [] (imports `<link href="//cdn.example.com/f.css">`))
  (t/is= [] (imports `<img src="data:image/png;base64,iVBOR">`))
  (t/is= [] (imports `<a href="#top">top</a>`))
  # A TEMPLATE HOLE IS NOT A FILENAME. A page the server fills in before
  # serving carries {{...}} where a value will go; this one drew a node
  # called FAVICON, as though the page depended on a file by that name.
  (t/is= [] (imports `<link rel="icon" href="{{FAVICON}}">`))
  (t/is= ["style"]
         (imports `<link rel="icon" href="{{FAVICON}}"><link href="style.css">`)
         "and the hole beside a real file does not take it with it")

  # A query is not part of the name, and a site-absolute path is read as a
  # sibling: the server maps / to the directory the page sits in.
  (t/is= ["favicon"] (imports `<link rel="icon" href="/favicon.ico?v=2">`)))

(t/test "css references other files three ways"
  # A PARSER ANSWERS IN NODE NAMES, not in the specifier it read -- see the
  # :imports-are contract in parser.janet. The stylesheet under test sits at
  # `sheet.css`, so its siblings are named by their bare stem.
  (defn imports [text] (((css/spec :parse) text "sheet.css") :imports))

  (t/is= ["base"] (imports `@import "base.css";`) "another stylesheet")
  (t/is= ["print"] (imports `@import 'print.css' print;`)
         "media conditions are not part of the path")
  (t/is= ["x"] (imports `@font-face { src: url(x.woff2); }`) "a font")
  (t/is= ["bg"] (imports `body { background: url("bg.png"); }`) "an image")
  (t/is= ["spaced"] (imports `.a { background: url( spaced.png ); }`)
         "the spaces inside url() are syntax, not name")

  # `url(#blur)` names an SVG filter in the same document, not a file.
  (t/is= [] (imports `.e { filter: url(#blur); }`))
  (t/is= [] (imports `.c { background: url(https://cdn.example.com/x.png); }`))
  (t/is= [] (imports `.d { background: url(data:image/gif;base64,R0lGOD); }`))

  # A COMMENTED-OUT IMPORT IS NOT ONE.
  (t/is= [] (imports `/* @import "off.css"; */`))
  (t/is= ["on"] (imports `/* off */ @import "on.css";`)))

(t/test "a .visualize file is a graph, not a node"
  (defn read-it [text] ((vz/spec :parse) text "demo.visualize"))

  (def got (read-it ``
auth  the login service
    database
    crypto

database  where things are kept
    disk
``))
  # PREFIXED BY THE FILE, on its stem: two files may each describe an `auth`
  # without colliding. The extension is reported separately and drawn under
  # the label, so it is not in the name.
  (t/is= ["demo.auth" "demo.database" "demo.crypto" "demo.disk"] (got :nodes))
  (t/is= "visualize" (got :extension))
  # EVERY LABEL MENTIONED IS A NODE, including one that never opens a block
  # of its own -- `disk` is named under `database` and nothing else.
  (t/is= [["demo.auth" "demo.database"]
          ["demo.auth" "demo.crypto"]
          ["demo.database" "demo.disk"]]
         (got :edges))

  # The description after a label is read but not drawn, so a label with one
  # and a label without produce the same node.
  (t/is= ["demo.a" "demo.b"] ((read-it "a  some prose\n    b\n") :nodes))
  (t/is= ["demo.a" "demo.b"] ((read-it "a\n    b\n") :nodes))

  # A comment is not a block, and an indented line with no block above it is
  # a dependency of nothing rather than of whatever came before the comment.
  (t/is= [] ((read-it "# just a note\n") :nodes))
  (t/is= [] ((read-it "    orphan\n") :edges))

  # A label depending on itself says nothing, and is not drawn.
  (t/is= [] ((read-it "a  x\n    a\n") :edges))

  # A block runs until the next heading: a blank line inside one does not
  # end it.
  (t/is= [["demo.a" "demo.b"] ["demo.a" "demo.c"]]
         ((read-it "a  x\n    b\n\n    c\n") :edges))

  # INDENTATION IS ANY LEADING SPACE OR TAB, in any amount -- and it does not
  # NEST. A line indented further still belongs to the nearest heading above
  # it, because the format is one level deep.
  (t/is= [["demo.a" "demo.b"]] ((read-it "a\n\tb\n") :edges) "a tab indents")
  (t/is= [["demo.a" "demo.b"]] ((read-it "a\n b\n") :edges) "one space indents")
  (t/is= [["demo.a" "demo.b"] ["demo.a" "demo.c"]]
         ((read-it "a\n    b\n        c\n") :edges)
         "deeper indentation is not nesting"))

(t/test "an import is relative to its own project, not to the scan root"
  # POINTED AT A DIRECTORY OF PROJECTS, which is what a workspace is. A
  # python import inside one of them is written from THAT project's root:
  # `otto.store` in `shop/` means `shop/otto/store.py`, whose node name
  # carries the `shop.` the import never mentions.
  #
  # Those names matched nothing and became externals, sitting on the graph
  # beside `os` and `json`.
  (def root (string (os/getenv "TMPDIR") "vz-sub-" (string (os/time))))
  (os/mkdir root)
  (os/mkdir (string root "/shop"))
  (os/mkdir (string root "/shop/otto"))
  (spit (string root "/shop/otto/store.py") "x = 1\n")
  (spit (string root "/shop/main.py") "import otto.store\n")

  (def g (scan/scan root))
  (def names (map |($ :name) (g :nodes)))
  (def ext (map |($ :name) (filter |(not ($ :ours)) (g :nodes))))
  (t/ok (index-of "shop.otto.store.py" names) "the file is there")
  (t/is= [] ext "and the import found it rather than inventing an external")
  (t/is= [["shop.main.py" "shop.otto.store.py"]] (g :edges)))

(t/test "a tail that two projects share resolves to neither"
  # THE RULE EVERY OTHER LOOKUP HERE FOLLOWS. Two projects both holding
  # `otto/store.py` cannot be told apart by a name that says neither, so the
  # reference stays external rather than being attributed to whichever was
  # read first. Losing an edge says nothing false; inventing one does.
  # THE IMPORTER IS IN NEITHER, so the sibling rule cannot settle it: a file
  # that imports `otto.store` from its own directory means the one beside
  # it, and this one has no `otto` beside it at all.
  (def root (string (os/getenv "TMPDIR") "vz-amb-" (string (os/time))))
  (os/mkdir root)
  (each p ["/a" "/a/otto" "/b" "/b/otto" "/c"] (os/mkdir (string root p)))
  (spit (string root "/a/otto/store.py") "x = 1\n")
  (spit (string root "/b/otto/store.py") "y = 2\n")
  (spit (string root "/c/main.py") "import otto.store\n")

  (def g (scan/scan root))
  (def ext (map |($ :name) (filter |(not ($ :ours)) (g :nodes))))
  (t/is= ["?.otto.store"] ext "ambiguous, so it stays a name from outside"))

(t/test "a python package is the directory's __init__.py"
  # `import otto.texting` NAMES A DIRECTORY in python, not a module file,
  # and what runs is the `__init__.py` inside it. Without this the import
  # matched nothing and drew a node beside the very file it meant.
  (def root (string (os/getenv "TMPDIR") "vz-pkg-" (string (os/time))))
  (os/mkdir root)
  (os/mkdir (string root "/otto"))
  (os/mkdir (string root "/otto/texting"))
  (spit (string root "/otto/texting/__init__.py") "x = 1\n")
  # THE IMPORTER SITS OUTSIDE the package it names: a file's own package is
  # not drawn as a dependency of it (see "a file's own package" below), so an
  # importer inside `otto/texting/` would prove nothing about resolution.
  (spit (string root "/otto/cli.py") "import otto.texting\n")

  (def g (scan/scan root))
  (def ext (map |($ :name) (filter |(not ($ :ours)) (g :nodes))))
  (t/is= [] ext "the package resolved rather than becoming an external")
  (t/is= [["otto.cli.py" "otto.texting.__init__.py"]] (g :edges))

  # AND FROM A SUBPROJECT'S OWN ROOT, where the import says nothing about
  # where the project sits -- the same tail rule the module lookup follows.
  (def sub (string (os/getenv "TMPDIR") "vz-pkgsub-" (string (os/time))))
  (os/mkdir sub)
  (os/mkdir (string sub "/shop"))
  (os/mkdir (string sub "/shop/otto"))
  (os/mkdir (string sub "/shop/otto/texting"))
  (spit (string sub "/shop/otto/texting/__init__.py") "x = 1\n")
  (spit (string sub "/shop/main.py") "import otto.texting\n")

  (def g2 (scan/scan sub))
  (t/is= [] (map |($ :name) (filter |(not ($ :ours)) (g2 :nodes))))
  (t/is= [["shop.main.py" "shop.otto.texting.__init__.py"]] (g2 :edges)))

(t/test "a bare import is the module beside it"
  # THE DIRECTORY A SCRIPT RUNS FROM IS ON PYTHON'S PATH, so `import db` in
  # `src/main.py` means the `db.py` sitting next to it. Without this the
  # name fell through to the global fallbacks, which called it ambiguous --
  # a tree can hold several files ending in `db`, and two of them here were
  # `.db` DATABASES rather than modules -- and drew an external instead.
  (def root (string (os/getenv "TMPDIR") "vz-sib-" (string (os/time))))
  (os/mkdir root)
  (os/mkdir (string root "/src"))
  (os/mkdir (string root "/data"))
  (spit (string root "/src/db.py") "x = 1\n")
  (spit (string root "/src/main.py") "import db\n")
  # A decoy with the same leaf, elsewhere, of the kind that made the global
  # lookup give up.
  (spit (string root "/data/db.py") "y = 2\n")

  (def g (scan/scan root))
  (t/is= [] (map |($ :name) (filter |(not ($ :ours)) (g :nodes)))
         "the sibling resolved rather than becoming an external")
  (t/is= [["src.main.py" "src.db.py"]] (g :edges)
         "and it is the sibling, not the file with the same name elsewhere"))

(t/test "an imported name that is a class is not a node"
  # `from otto.models import Cart` and `from otto.mcp import cart` ARE THE
  # SAME LINE as far as the syntax goes: a module, `import`, a name. Python
  # tells them apart by looking -- a submodule if one exists, an attribute
  # otherwise -- so the parser reports both readings and the resolution here
  # keeps whichever names a file.
  #
  # THE BUG THIS EXISTS FOR came in two halves. Reading only the module lost
  # `otto/mcp/cart.py` and every store beside it, so real files looked
  # unimported. Reading both and externalising the misses drew a `?.` node
  # for every class and type in the tree -- three hundred and sixty of them
  # on one project, `?.otto.models.FetchFn` sitting beside `otto.models.py`
  # itself. A name whose own prefix resolved is a symbol, and is dropped.
  (def root (string (os/getenv "TMPDIR") "vz-cls-" (string (os/time))))
  (os/mkdir root)
  (os/mkdir (string root "/otto"))
  (os/mkdir (string root "/otto/mcp"))
  (spit (string root "/otto/models.py") "class Cart: pass\n")
  (spit (string root "/otto/mcp/__init__.py") "")
  (spit (string root "/otto/mcp/cart.py") "x = 1\n")
  (spit (string root "/otto/mcp/core.py")
        "from otto.models import Cart\nfrom otto.mcp import cart\n")

  (def g (scan/scan root))
  (def edges (sorted (map |(string (first $) " -> " (get $ 1)) (g :edges))))
  (t/ok (index-of "otto.mcp.core.py -> otto.mcp.cart.py" edges)
        "the submodule reading won where a file backs it")
  (t/ok (index-of "otto.mcp.core.py -> otto.models.py" edges)
        "and the module itself is still a dependency")
  (t/is= [] (map |($ :name) (filter |(not ($ :ours)) (g :nodes)))
         "the class invented no external"))

(t/test "a package-qualified import resolves against the package root"
  # `from otto import db` inside `otto/store_cart.py` means `otto/db.py` --
  # the name resolved against the importer's GRANDparent, not its own
  # directory. Checking only the immediate directory built
  # `...otto.otto.db`, which exists nowhere, so the name fell through to the
  # global fallbacks.
  #
  # AND THE FALLBACKS CANNOT ANSWER IT, which is why this matters at a scan
  # root holding more than one project: `otto.db` also names three SQLITE
  # DATABASES here, so the by-leaf map calls it ambiguous and gives up --
  # correctly, since it has no way to know which was meant. The file one
  # directory up from the importer is not ambiguous at all.
  (def root (string (os/getenv "TMPDIR") "vz-anc-" (string (os/time))))
  (os/mkdir root)
  (os/mkdir (string root "/shop"))
  (os/mkdir (string root "/shop/otto"))
  (os/mkdir (string root "/shop/data"))
  (spit (string root "/shop/otto/__init__.py") "")
  (spit (string root "/shop/otto/db.py") "x = 1\n")
  (spit (string root "/shop/otto/store_cart.py") "from otto import db\n")
  # The decoys that make the global lookup ambiguous.
  (spit (string root "/shop/data/otto.db") "")
  (spit (string root "/shop/data/otto.db-wal") "")

  (def g (scan/scan root))
  (def edges (map |(string (first $) " -> " (get $ 1)) (g :edges)))
  (t/ok (index-of "shop.otto.store_cart.py -> shop.otto.db.py" edges)
        "the module beside it won, not the database")
  (t/ok (not (some |(string/has-prefix? "?." ($ :name)) (g :nodes)))
        "and nothing was invented as an external"))

(t/test "a third-party package does not collide with a local one"
  # `from mcp.server.fastmcp import FastMCP` means the INSTALLED mcp
  # library. A project that happens to hold an `otto/mcp/` package must not
  # capture it -- and the graph was disagreeing with itself about the one
  # import, keeping `?.mcp.server.fastmcp` external while drawing an edge to
  # the local `otto/mcp/` for the bare prefix `mcp`.
  #
  # TWO LOOSE MATCHES DID IT. The package map indexes every suffix of a
  # package's name, so `otto/mcp/__init__.py` answers to a bare `mcp`; and
  # the sibling walk climbed past the package root, which python has not
  # done since PEP 328 removed implicit relative imports -- from inside a
  # package `import json` is the stdlib, never the file beside it. Both are
  # right for a name a file actually wrote, and wrong for a prefix nobody
  # wrote.
  (def root (string (os/getenv "TMPDIR") "vz-coll-" (string (os/time))))
  (os/mkdir root)
  (os/mkdir (string root "/otto"))
  (os/mkdir (string root "/otto/mcp"))
  (os/mkdir (string root "/otto/onboarding"))
  (spit (string root "/otto/__init__.py") "")
  (spit (string root "/otto/mcp/__init__.py") "")
  (spit (string root "/otto/onboarding/__init__.py") "")
  (spit (string root "/otto/onboarding/server.py")
        "from mcp.server.fastmcp import FastMCP\n")

  (def g (scan/scan root))
  (def edges (map |(string (first $) " -> " (get $ 1)) (g :edges)))
  (t/ok (not (index-of "otto.onboarding.server.py -> otto.mcp.__init__.py" edges))
        "the local package did not capture the library's name")
  (t/ok (some |(string/find "?.mcp" $) edges)
        "and the library stayed external"))

(t/test "a package-qualified import still reaches its parent package"
  # The restriction above must not cost the parent edges: `from
  # otto.product_reads.shopify import read` depends on
  # `otto/product_reads/__init__.py`, because python runs it on the way.
  # That name is inferred too, so it resolves by the EXACT package map --
  # matched on the whole path rather than on a suffix of it.
  (def root (string (os/getenv "TMPDIR") "vz-par-" (string (os/time))))
  (os/mkdir root)
  (os/mkdir (string root "/otto"))
  (os/mkdir (string root "/otto/reads"))
  (spit (string root "/otto/__init__.py") "")
  (spit (string root "/otto/reads/__init__.py") "")
  (spit (string root "/otto/reads/shopify.py") "x = 1\n")
  (spit (string root "/otto/caller.py")
        "from otto.reads.shopify import read\n")

  (def g (scan/scan root))
  (def edges (map |(string (first $) " -> " (get $ 1)) (g :edges)))
  (t/ok (index-of "otto.caller.py -> otto.reads.shopify.py" edges) "the module")
  (t/ok (index-of "otto.caller.py -> otto.reads.__init__.py" edges)
        "and the package python ran to reach it"))

(t/test "a file's own package is not drawn as a dependency of it"
  # Python runs `otto/mcp/__init__.py` before `otto/mcp/core.py`, so it is a
  # real import and pydeps reports it -- but on a DRAWING it says nothing the
  # picture is not already saying. The two sit in the same box, and every
  # module in a package would get the identical arrow to the box it is drawn
  # inside: seventy seven such edges on shoppingagent, all noise.
  #
  # A DIFFERENT PACKAGE'S `__init__.py` IS A REAL EDGE and stays. It crosses
  # from one box to another, which is what the drawing exists to show.
  (def root (string (os/getenv "TMPDIR") "vz-own-" (string (os/time))))
  (os/mkdir root)
  (os/mkdir (string root "/otto"))
  (os/mkdir (string root "/otto/mcp"))
  (os/mkdir (string root "/otto/reads"))
  (spit (string root "/otto/__init__.py") "")
  (spit (string root "/otto/mcp/__init__.py") "")
  (spit (string root "/otto/reads/__init__.py") "")
  (spit (string root "/otto/mcp/core.py")
        "from otto.mcp import helper\nfrom otto.reads import shopify\n")
  (spit (string root "/otto/mcp/helper.py") "x = 1\n")

  (def g (scan/scan root))
  (def edges (map |(string (first $) " -> " (get $ 1)) (g :edges)))
  (t/ok (not (index-of "otto.mcp.core.py -> otto.mcp.__init__.py" edges))
        "its own package is not an arrow")
  (t/ok (index-of "otto.mcp.core.py -> otto.reads.__init__.py" edges)
        "but another package's is")
  (t/ok (index-of "otto.mcp.core.py -> otto.mcp.helper.py" edges)
        "and a sibling module is untouched"))

(t/test "an import resolves only to a file its language could load"
  # `otto.sh` is a bash launcher sitting beside the `otto/` package. Stripping
  # its extension leaves the stem `otto`, the same stem the package has, so
  # `from otto import db` resolved to the SHELL SCRIPT -- and every python
  # file in the project drew an edge to it. Ninety one of them on
  # shoppingagent.
  #
  # A stem match is not enough: an import names a file its own language can
  # LOAD, and python loads .py files. Checked once where the target is
  # decided, so every route to it -- stem, sibling, package, tail, leaf --
  # obeys the same rule, and a rejected target falls through to the external
  # branch exactly as an unmatched name does.
  (def root (string (os/getenv "TMPDIR") "vz-lang-" (string (os/time))))
  (os/mkdir root)
  (os/mkdir (string root "/otto"))
  (spit (string root "/otto.sh") "#!/bin/bash\necho hi\n")
  (spit (string root "/otto/__init__.py") "")
  (spit (string root "/otto/db.py") "x = 1\n")
  (spit (string root "/caller.py") "from otto import db\n")

  (def g (scan/scan root))
  (def edges (map |(string (first $) " -> " (get $ 1)) (g :edges)))
  (t/ok (not (some |(string/find "otto.sh" $) edges))
        "the shell script is not a python import")
  (t/ok (index-of "caller.py -> otto.db.py" edges)
        "and the module it actually meant still resolves")

  # A LANGUAGE THAT SAYS NOTHING KEEPS THE OLD BEHAVIOUR. Only python
  # declares a restriction, because it is the one whose imports are modules
  # rather than paths; a stylesheet naming a font and a page naming a script
  # are cross-kind on purpose and are not made to enumerate the web.
  (def web (string (os/getenv "TMPDIR") "vz-web-" (string (os/time))))
  (os/mkdir web)
  (spit (string web "/page.html")
        "<link rel=\"stylesheet\" href=\"./style.css\">")
  (spit (string web "/style.css") "body { color: red }\n")
  (def g2 (scan/scan web))
  (t/ok (index-of "page.html -> style.css"
                  (map |(string (first $) " -> " (get $ 1)) (g2 :edges)))
        "html still reaches a stylesheet"))

(t/test "a reference into a pruned directory draws nothing"
  # The walk prunes `public/`, `.venv/`, `dist/` and the rest, so a file
  # inside one is not in the tree. A reference to it matched nothing and was
  # invented as an EXTERNAL -- which says the opposite of what is true: the
  # file is right there, and the scan chose not to look. Skipping a directory
  # AND drawing nodes for what it holds is the worst of both.
  (def root (string (os/getenv "TMPDIR") "vz-prune-" (string (os/time))))
  (os/mkdir root)
  # `dist` rather than `public`: a directory named for what it SERVES holds
  # sources as often as output, and `public` was taken off the skip list
  # when it turned out to be hiding a served stylesheet. `dist` names the
  # output itself and is skipped by every spec that has an opinion.
  (os/mkdir (string root "/dist"))
  (spit (string root "/dist/app.css") "body{}\n")
  (spit (string root "/page.html")
        "<link rel=\"stylesheet\" href=\"/dist/app.css\">")

  (def g (scan/scan root))
  (t/is= [] (map |($ :name) (filter |(not ($ :ours)) (g :nodes)))
         "the pruned file invented no external")
  (t/is= [] (g :edges) "and no edge was drawn to it"))

(t/test "a url the page computes at runtime is not a path"
  # `src="${esc(t.image)}"` is a template literal the browser fills in, and
  # reading it as a path invented `esc/t` -- a node named after the escaping
  # helper that happened to sit inside the braces.
  (def root (string (os/getenv "TMPDIR") "vz-tmpl-" (string (os/time))))
  (os/mkdir root)
  (spit (string root "/page.html")
        (string "<img src=\"${esc(t.image)}\">"
                "<img src=\"{{FAVICON}}\">"
                "<img src=\"<%= asset %>\">"
                "<link rel=\"stylesheet\" href=\"./real.css\">"))
  (spit (string root "/real.css") "body{}\n")

  (def g (scan/scan root))
  (t/is= [] (map |($ :name) (filter |(not ($ :ours)) (g :nodes)))
         "no template hole became a node")
  (t/is= [["page.html" "real.css"]] (g :edges)
         "and the one real reference still resolves"))

(t/test "a shell assignment is not a command"
  # `css=otto/resources/public/app.css` opens a line with something that
  # looks exactly like a slashed path in command position, and reading it as
  # one made `css` a DIRECTORY: the value became
  # `css.otto.resources.public.app`, a node for a path that exists nowhere.
  (def root (string (os/getenv "TMPDIR") "vz-assign-" (string (os/time))))
  (os/mkdir root)
  (os/mkdir (string root "/lib"))
  (spit (string root "/lib/util.sh") "echo hi\n")
  (spit (string root "/run.sh")
        "css=some/generated/app.css\nsource lib/util.sh\n")

  (def g (scan/scan root))
  (def edges (map |(string (first $) " -> " (get $ 1)) (g :edges)))
  (t/ok (not (some |(string/find "css." $) edges))
        "the assignment named no directory")
  (t/ok (index-of "run.sh -> lib.util.sh" edges)
        "and a real source line still resolves"))

(t/test "a reference that resolves to no name draws nothing"
  # `. ./.env` names a dotfile the walk skips, and `.env` has no stem at all
  # -- `stem` reads the whole name as an extension and returns "". What
  # survived was the DIRECTORY it was resolved against, so the reference
  # collapsed to the importing file's own parent and drew an external named
  # after the folder the script is sitting in.
  (def root (string (os/getenv "TMPDIR") "vz-dot-" (string (os/time))))
  (os/mkdir root)
  (os/mkdir (string root "/proj"))
  (spit (string root "/proj/.env") "X=1\n")
  (spit (string root "/proj/run.sh") "[ -f .env ] && . ./.env\n")

  (def g (scan/scan root))
  (t/is= [] (map |($ :name) (filter |(not ($ :ours)) (g :nodes)))
         "the dotfile invented no external")
  (t/is= [] (g :edges)))
