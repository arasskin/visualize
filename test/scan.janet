# The parser engine and the specs that ride on it.
#
# The Swift cases here are the ones that were WRONG at some point during the
# port, kept so they cannot go wrong again quietly. Each is a false edge the
# graph would otherwise have drawn with total confidence.

(import ../src/parser :as parser)
(import ../src/scan)
(import ../src/parsers/swift)
(import ../src/parsers/python)
(import ../src/parsers/go)
(import ../src/parsers/javascript :as js)
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
  (t/is= ["fmt" "github.com/lib/pq" "math" "os"] (sorted (got :imports)))
  (t/ok (not (index-of "commented-out" (got :imports)))
        "a commented import is still not an import"))

(t/test "javascript takes every import shape and keeps relative paths whole"
  (def got (parser/run js/spec ``
import React from 'react'
import { a, b } from "./store"
import type { T } from '../lib/api'
import './side-effect.css'
export { x } from './other'
const fs = require('fs')
// import Fake from 'nope'
`` "a.ts"))
  (t/is= ["../lib/api" "./other" "./side-effect.css" "./store" "fs" "react"]
         (sorted (got :imports)))
  (t/ok (not (index-of "nope" (got :imports))))
  (t/ok (not (index-of "T" (got :imports))) "the binding is not the module"))

(t/test "node names are legal bare DOT identifiers"
  # A real directory called `demo-api` produced `demo-api_worker`, and
  # graphviz rejected the whole graph with a syntax error at the hyphen.
  # Import specifiers are worse: `github.com/lib/pq`, `./store`, `@scope/pkg`.
  (t/is= "demo_api_worker" (scan/node-name "demo-api/worker.js"))
  (t/is= "OttoClip_CartWebView" (scan/node-name "OttoClip/CartWebView.swift"))
  (t/is= "github_com_lib_pq" (scan/safe-name "github.com/lib/pq"))
  (t/is= "__store" (scan/safe-name "./store") "both the dot and the slash go")
  (t/is= "_scope_pkg" (scan/safe-name "@scope/pkg"))
  (each name [(scan/node-name "demo-api/worker.js")
              (scan/safe-name "github.com/lib/pq")
              (scan/safe-name "@scope/pkg")]
    (t/ok (peg/match ~(* (some (+ (range "AZ") (range "az") (range "09") "_")) -1)
                     name)
          (string name " must be a bare DOT identifier"))))

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
