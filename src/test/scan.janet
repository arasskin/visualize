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
  (t/ok (not (index-of "Cart" (got :imports))) "the symbol is not the module"))

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
