(import ../visualize/parser :as parser)
(import ../visualize/scan)
(import ../visualize/parsers/swift)
(import ../visualize/parsers/clojure)
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

  (def got (swift "private extension Color { var x: Int { 1 } }\n"))
  (t/is= [] (sorted (got :declares))))

(t/test "`import struct Foundation.Data` declares nothing"

  (def got (swift "import struct Foundation.Data\n"))
  (t/is= [] (got :declares))
  (t/is= ["Foundation"] (got :imports) "the node is the framework, not the symbol"))

(t/test "a declaration must start a line"

  (t/is= [] ((swift "let x = makeStruct Thing\n") :declares)))

(t/test "comments and string literals never produce references"

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

  (t/ok (index-of "otto.store.Cart" (got :imports)) "the symbol reading too"))

(t/test "a parenthesised import list spans lines"

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

  (defn imports [text] (((html/spec :parse) text "page.html") :imports))

  (t/is= ["theme" "app"]
         (imports `<link rel="stylesheet" href="theme.css"><script src="./app.js"></script>`)
         "a stylesheet and a script")
  (t/is= ["logo"] (imports `<img src="logo.png">`) "and an image")
  (t/is= ["clip" "thumb"]
         (sort (imports `<video poster="thumb.jpg" src="clip.mp4"></video>`)))

  (t/is= [] (imports `<a href="about.html">about</a>`))
  (t/is= ["theme"]
         (imports `<a href="about.html">x</a><link href="theme.css">`)
         "which is decided by the tag, not the attribute")

  (t/is= [] (imports `<script src="https://cdn.example.com/lib.js"></script>`))
  (t/is= [] (imports `<link href="//cdn.example.com/f.css">`))
  (t/is= [] (imports `<img src="data:image/png;base64,iVBOR">`))
  (t/is= [] (imports `<a href="#top">top</a>`))

  (t/is= [] (imports `<link rel="icon" href="{{FAVICON}}">`))
  (t/is= ["style"]
         (imports `<link rel="icon" href="{{FAVICON}}"><link href="style.css">`)
         "and the hole beside a real file does not take it with it")

  (t/is= ["favicon"] (imports `<link rel="icon" href="/favicon.ico?v=2">`)))

(t/test "css references other files three ways"

  (defn imports [text] (((css/spec :parse) text "sheet.css") :imports))

  (t/is= ["base"] (imports `@import "base.css";`) "another stylesheet")
  (t/is= ["print"] (imports `@import 'print.css' print;`)
         "media conditions are not part of the path")
  (t/is= ["x"] (imports `@font-face { src: url(x.woff2); }`) "a font")
  (t/is= ["bg"] (imports `body { background: url("bg.png"); }`) "an image")
  (t/is= ["spaced"] (imports `.a { background: url( spaced.png ); }`)
         "the spaces inside url() are syntax, not name")

  (t/is= [] (imports `.e { filter: url(#blur); }`))
  (t/is= [] (imports `.c { background: url(https://cdn.example.com/x.png); }`))
  (t/is= [] (imports `.d { background: url(data:image/gif;base64,R0lGOD); }`))

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

  (t/is= ["demo.auth" "demo.database" "demo.crypto" "demo.disk"] (got :nodes))
  (t/is= "visualize" (got :extension))

  (t/is= [["demo.auth" "demo.database"]
          ["demo.auth" "demo.crypto"]
          ["demo.database" "demo.disk"]]
         (got :edges))

  (t/is= ["demo.a" "demo.b"] ((read-it "a  some prose\n    b\n") :nodes))
  (t/is= ["demo.a" "demo.b"] ((read-it "a\n    b\n") :nodes))

  (t/is= [] ((read-it "# just a note\n") :nodes))
  (t/is= [] ((read-it "    orphan\n") :edges))

  (t/is= [] ((read-it "a  x\n    a\n") :edges))

  (t/is= [["demo.a" "demo.b"] ["demo.a" "demo.c"]]
         ((read-it "a  x\n    b\n\n    c\n") :edges))

  (t/is= [["demo.a" "demo.b"]] ((read-it "a\n\tb\n") :edges) "a tab indents")
  (t/is= [["demo.a" "demo.b"]] ((read-it "a\n b\n") :edges) "one space indents")
  (t/is= [["demo.a" "demo.b"] ["demo.a" "demo.c"]]
         ((read-it "a\n    b\n        c\n") :edges)
         "deeper indentation is not nesting"))

(t/test "an import is relative to its own project, not to the scan root"

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

  (def root (string (os/getenv "TMPDIR") "vz-pkg-" (string (os/time))))
  (os/mkdir root)
  (os/mkdir (string root "/otto"))
  (os/mkdir (string root "/otto/texting"))
  (spit (string root "/otto/texting/__init__.py") "x = 1\n")

  (spit (string root "/otto/cli.py") "import otto.texting\n")

  (def g (scan/scan root))
  (def ext (map |($ :name) (filter |(not ($ :ours)) (g :nodes))))
  (t/is= [] ext "the package resolved rather than becoming an external")
  (t/is= [["otto.cli.py" "otto.texting.__init__.py"]] (g :edges))

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

  (def root (string (os/getenv "TMPDIR") "vz-sib-" (string (os/time))))
  (os/mkdir root)
  (os/mkdir (string root "/src"))
  (os/mkdir (string root "/data"))
  (spit (string root "/src/db.py") "x = 1\n")
  (spit (string root "/src/main.py") "import db\n")

  (spit (string root "/data/db.py") "y = 2\n")

  (def g (scan/scan root))
  (t/is= [] (map |($ :name) (filter |(not ($ :ours)) (g :nodes)))
         "the sibling resolved rather than becoming an external")
  (t/is= [["src.main.py" "src.db.py"]] (g :edges)
         "and it is the sibling, not the file with the same name elsewhere"))

(t/test "an imported name that is a class is not a node"

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

  (def root (string (os/getenv "TMPDIR") "vz-anc-" (string (os/time))))
  (os/mkdir root)
  (os/mkdir (string root "/shop"))
  (os/mkdir (string root "/shop/otto"))
  (os/mkdir (string root "/shop/data"))
  (spit (string root "/shop/otto/__init__.py") "")
  (spit (string root "/shop/otto/db.py") "x = 1\n")
  (spit (string root "/shop/otto/store_cart.py") "from otto import db\n")

  (spit (string root "/shop/data/otto.db") "")
  (spit (string root "/shop/data/otto.db-wal") "")

  (def g (scan/scan root))
  (def edges (map |(string (first $) " -> " (get $ 1)) (g :edges)))
  (t/ok (index-of "shop.otto.store_cart.py -> shop.otto.db.py" edges)
        "the module beside it won, not the database")
  (t/ok (not (some |(string/has-prefix? "?." ($ :name)) (g :nodes)))
        "and nothing was invented as an external"))

(t/test "a third-party package does not collide with a local one"

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

  (def root (string (os/getenv "TMPDIR") "vz-prune-" (string (os/time))))
  (os/mkdir root)

  (os/mkdir (string root "/dist"))
  (spit (string root "/dist/app.css") "body{}\n")
  (spit (string root "/page.html")
        "<link rel=\"stylesheet\" href=\"/dist/app.css\">")

  (def g (scan/scan root))
  (t/is= [] (map |($ :name) (filter |(not ($ :ours)) (g :nodes)))
         "the pruned file invented no external")
  (t/is= [] (g :edges) "and no edge was drawn to it"))

(t/test "a url the page computes at runtime is not a path"

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

  (def root (string (os/getenv "TMPDIR") "vz-dot-" (string (os/time))))
  (os/mkdir root)
  (os/mkdir (string root "/proj"))
  (spit (string root "/proj/.env") "X=1\n")
  (spit (string root "/proj/run.sh") "[ -f .env ] && . ./.env\n")

  (def g (scan/scan root))
  (t/is= [] (map |($ :name) (filter |(not ($ :ours)) (g :nodes)))
         "the dotfile invented no external")
  (t/is= [] (g :edges)))

(t/test "a package beside the importer resolves, and a library still does not"

  (def root (string (os/getenv "TMPDIR") "vz-sib-" (string (os/time))))
  (os/mkdir root)
  (os/mkdir (string root "/otto"))
  (os/mkdir (string root "/tests"))
  (spit (string root "/otto.sh") "#!/bin/bash\n")
  (spit (string root "/otto/__init__.py") "")
  (spit (string root "/tests/test_x.py") "from otto import thing\n")

  (def g (scan/scan root))
  (def edges (map |(string (first $) " -> " (get $ 1)) (g :edges)))
  (t/ok (index-of "tests.test_x.py -> otto.__init__.py" edges)
        "the package one directory up resolved")
  (t/ok (not (some |(string/find "otto.sh" $) edges))
        "and the shell script sharing its stem did not win")

  (def lib (string (os/getenv "TMPDIR") "vz-lib-" (string (os/time))))
  (os/mkdir lib)
  (os/mkdir (string lib "/otto"))
  (os/mkdir (string lib "/otto/mcp"))
  (os/mkdir (string lib "/otto/onboarding"))
  (spit (string lib "/otto/__init__.py") "")
  (spit (string lib "/otto/mcp/__init__.py") "")
  (spit (string lib "/otto/onboarding/__init__.py") "")
  (spit (string lib "/otto/onboarding/server.py")
        "from mcp.server.fastmcp import FastMCP\n")

  (def g2 (scan/scan lib))
  (def edges2 (map |(string (first $) " -> " (get $ 1)) (g2 :edges)))
  (t/ok (not (index-of "otto.onboarding.server.py -> otto.mcp.__init__.py" edges2))
        "the local package did not capture the library's name"))

(t/test "a symbol whose module is the file beside it is not a node"

  (def root (string (os/getenv "TMPDIR") "vz-sym-" (string (os/time))))
  (os/mkdir root)
  (os/mkdir (string root "/src"))
  (spit (string root "/src/search.py") "def search_products(): pass\n")
  (spit (string root "/src/main.py") "from search import search_products\n")

  (def g (scan/scan root))
  (t/is= [] (map |($ :name) (filter |(not ($ :ours)) (g :nodes)))
         "the symbol invented no external")
  (t/is= [["src.main.py" "src.search.py"]] (g :edges)
         "and the module it named is the edge"))

(t/test "clojure reads the ns form, and only the live parts of it"
  (def got (parser/run clojure/spec `
(ns icare.ui
  (:require ["package:flutter/material.dart" :as m]
            ;; [icare.benchmarks :refer [dart-time]]
            [icare.ui.shared :refer [scale-down-fade-animation]]
            ["dart:ui" :as ui]
            [icare.ui.normalized-ast :refer [ast->ast-store]]))
` "t.cljd"))
  (def found (got :imports))

  (t/ok (not (index-of "icare.benchmarks" found)) "the ;; line said nothing")

  (t/ok (index-of "icare.ui.normalized_ast" found) "munged to match the file")

  (t/ok (index-of "?.flutter.material" found) "package: and .dart trimmed, marked")
  (t/ok (index-of "?.dart.ui" found) "dart: likewise")

  (t/ok (not (index-of "scale_down_fade_animation" found)) "refer names skipped")
  (t/ok (index-of "icare.ui.shared" found)))

(t/test "a clojuredart require finds its file from the source root"

  (def root (string (os/getenv "TMPDIR") "vz-cljd-" (string (os/time))))
  (os/mkdir root)
  (each d ["/src" "/src/app" "/src/app/src" "/src/app/src/icare"
           "/lib" "/lib/cljd-out" "/lib/cljd-out/cljd"]
    (os/mkdir (string root d)))
  (spit (string root "/src/app/src/icare/shared_thing.cljd") "(ns icare.shared-thing)\n")
  (spit (string root "/src/app/src/icare/ui.cljd")
        "(ns icare.ui (:require [icare.shared-thing :as s] [cljd.flutter :as f]))\n")
  (spit (string root "/lib/cljd-out/cljd/flutter.dart") "// transpiled\n")

  (def g (scan/scan root))
  (def edges (map |(string (first $) " -> " (get $ 1)) (g :edges)))
  (t/ok (index-of "src.app.src.icare.ui.cljd -> src.app.src.icare.shared_thing.cljd" edges)
        "the munged require found the file under the source root")
  (t/ok (index-of "src.app.src.icare.ui.cljd -> ?.cljd.flutter" edges)
        "and the library stayed external, its transpiled copy unseen"))

(t/test "fingerprints track names and individual files without aggregate collisions"
  (def root (string (os/getenv "TMPDIR" "/tmp/") "vz-fingerprint-" (os/getpid)))
  (os/mkdir root)
  (defer (do (each name (os/dir root) (os/rm (string root "/" name)))
             (os/rmdir root))
    (spit (string root "/a.js") "one")
    (spit (string root "/c.js") "three")
    (def before (scan/fingerprint root))
    (t/is= before (scan/fingerprint root) "unchanged scans compare equal")
    (os/rename (string root "/a.js") (string root "/b.js"))
    (def renamed (scan/fingerprint root))
    (t/ok (not= before renamed) "same-length rename changes the fingerprint")
    (spit (string root "/b.js") "three")
    (spit (string root "/c.js") "one")
    (def edited (scan/fingerprint root))
    (t/ok (not= renamed edited) "opposing size changes cannot cancel out")
    (os/rm (string root "/c.js"))
    (t/ok (not= edited (scan/fingerprint root)) "deletion changes the fingerprint")))
