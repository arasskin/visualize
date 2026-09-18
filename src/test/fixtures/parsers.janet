(def cases
  [{:name "python packages, aliases, relative imports and external name collisions"
    :files {"app/pkg/__init__.py" ""
            "app/pkg/common.py" "class Result: pass\n"
            "app/pkg/jobs/__init__.py" ""
            "app/pkg/jobs/local.py" "VALUE = 1\n"
            "app/pkg/jobs/search.py" "def search(): pass\n"
            "app/pkg/jobs/parent.py" "from ..common import Result\n"
            "app/pkg/jobs/main.py" ``
from pkg.common import (
    Result as Outcome,
)
from . import local
from ..common import Result
from mcp import search as remote_search
example = """
from phantom import search
import imaginary
"""
# from ghost import missing
``}
    :edges [["app.pkg.jobs.main.py" "app.pkg.common.py"]
            ["app.pkg.jobs.main.py" "app.pkg.jobs.local.py"]
            ["app.pkg.jobs.main.py" "?.mcp"]
            ["app.pkg.jobs.parent.py" "app.pkg.common.py"]]}
   {:name "python bare libraries do not resolve to files inside packages"
    :files {"shop/otto/__init__.py" ""
            "shop/otto/retailers/__init__.py" ""
            "shop/otto/retailers/html.py" "import html\nfrom html.parser import HTMLParser\n"
            "shop/otto/retailers/json.py" ""
            "shop/otto/retailers/thirdparty/__init__.py" ""
            "shop/otto/retailers/main.py" "import html\nimport json\nimport thirdparty\nfrom html import escape\nfrom . import html as local_html\n"
            "shop/otto/namespace/main.py" "import html\nfrom otto.retailers.html import cards\n"
            "shop/otto/core.py" "import html\nfrom html.parser import HTMLParser\n"
            "shop/otto/members.py" "from html import parser\nimport html.parser\n"
            "shop/tests/check.py" "from otto.retailers.html import cards\n"
            "shop/main.py" "import html\nimport thirdparty\n"}
    :edges [["shop.otto.retailers.html.py" "?.html"]
            ["shop.otto.retailers.html.py" "?.html.parser"]
            ["shop.otto.retailers.main.py" "?.html"]
            ["shop.otto.retailers.main.py" "?.json"]
            ["shop.otto.retailers.main.py" "?.thirdparty"]
            ["shop.otto.retailers.main.py" "shop.otto.retailers.html.py"]
            ["shop.otto.namespace.main.py" "?.html"]
            ["shop.otto.namespace.main.py" "shop.otto.retailers.html.py"]
            ["shop.otto.namespace.main.py" "shop.otto.retailers.__init__.py"]
            ["shop.otto.core.py" "?.html"]
            ["shop.otto.core.py" "?.html.parser"]
            ["shop.otto.members.py" "?.html"]
            ["shop.otto.members.py" "?.html.parser"]
            ["shop.tests.check.py" "shop.otto.__init__.py"]
            ["shop.tests.check.py" "shop.otto.retailers.__init__.py"]
            ["shop.tests.check.py" "shop.otto.retailers.html.py"]
            ["shop.main.py" "?.html"]
            ["shop.main.py" "?.thirdparty"]]}
   {:name "python root modules and standalone script siblings can shadow libraries"
    :files {"html.py" ""
            "main.py" "import html\n"
            "scripts/json.py" ""
            "scripts/main.py" "import json\n"
            "shop/logging.py" ""
            "shop/app/__init__.py" ""
            "shop/app/main.py" "import logging\n"}
    :edges [["main.py" "html.py"]
            ["scripts.main.py" "scripts.json.py"]
            ["shop.app.main.py" "shop.logging.py"]]}
   {:name "typescript multiline imports, reexports and dynamic imports"
    :files {"src/main.tsx" ``
import type {
  Model,
} from './model';
export {
  value as renamed,
} from './store';
import './theme.css';
const lazy = () => import('./lazy');
const common = require('./common');
const computed = import('./computed/' + name);
loader.require('./not-a-module');
const example = "require('./phantom')";
const template = `
import Missing from './missing';
`;
// require('./ghost');
/* import Nope from './nope'; */
``
            "src/model.ts" "export interface Model { name: string }\n"
            "src/store.ts" "export const value = 1;\n"
            "src/theme.css" "body { color: black; }\n"
            "src/lazy.ts" "export default 1;\n"
            "src/common.cjs" "module.exports = 1;\n"}
    :imports {"src/main.tsx" ["src.model" "src.store" "src.theme" "src.lazy" "src.common"]}
    :edges [["src.main.tsx" "src.model.ts"] ["src.main.tsx" "src.store.ts"]
            ["src.main.tsx" "src.theme.css"] ["src.main.tsx" "src.lazy.ts"]
            ["src.main.tsx" "src.common.cjs"]]}
   {:name "janet imports inside code but not documentation strings"
    :files {"src/main.janet" ```
(import ./store :as store)
(use "../lib/math")
(def explanation ``
(import ./phantom)
(use ../missing)
``)
# (import ./ghost)
```
            "src/store.janet" "(def value 1)\n"
            "lib/math.janet" "(defn twice [x] (* x 2))\n"}
    :imports {"src/main.janet" ["src.store" "lib.math"]}
    :edges [["src.main.janet" "src.store.janet"] ["src.main.janet" "lib.math.janet"]]}
   {:name "janet resolves modules beside native C sources and links literal FFI symbols"
    :files {"src/host.janet" "(import ./pty)\n(use ./package)\n(import ./absent)\n"
            "src/pty.janet" ```
(def library-path (string (os/realpath (string (dyn :current-file) "/..")) "/libvisualize-pty.so"))
(def resize (ffi/lookup (ffi/native library-path) "visualize_pty_resize"))
(def api (ffi/lookup
           (ffi/native "./arbitrary-library-name.so")
           "exported_pointer"))
(def dynamic (ffi/lookup library (string "computed_" "symbol")))
(def private (ffi/lookup library "private_helper"))
(def prototype (ffi/lookup library "only_declared"))
(def ambiguous (ffi/lookup library "duplicate_symbol"))
(def text ``(ffi/lookup library "documented_symbol")``)
# (ffi/lookup library "commented_symbol")
```
            "src/pty.c" ``
#include <sys/ioctl.h>
int visualize_pty_resize(int fd, int rows, int cols) {
    return ioctl(fd, TIOCSWINSZ, 0);
}
static
int private_helper(void) { return 0; }
int only_declared(void);
int duplicate_symbol(void) { return 1; }
``
            "native/bridge.c" ``
const unsigned char *
exported_pointer (void (*callback)(int)) { return 0; }
int computed_symbol(void) { return 0; }
int documented_symbol(void) { return 0; }
int commented_symbol(void) { return 0; }
int duplicate_symbol(void) { return 2; }
// int only_declared(void) { return 0; }
const char *example = "int only_declared(void) { return 0; }";
``
            "src/package.c" "int package(void) { return 0; }\n"
            "src/package/init.janet" "(def value 1)\n"
            "src/absent.c" "int absent(void) { return 0; }\n"
            "elsewhere/absent.janet" "(def value 1)\n"}
    :imports {"src/host.janet" ["src.pty" "src.package" "src.absent"]}
    :edges [["src.host.janet" "src.pty.janet"]
            ["src.host.janet" "src.package.init.janet"]
            ["src.host.janet" "?.src.absent"]
            ["src.pty.janet" "src.pty.c"]
            ["src.pty.janet" "native.bridge.c"]]}
   {:name "go grouped imports, aliases and raw documentation strings"
    :files {"main.go" ``
package main
import "fmt"
import single "example.org/single"
import (
  alias "example.org/lib"
  _ "example.org/driver"
  . "math"
)
var example = `
import "phantom"
"missing"
`
func main() {
  fmt.Println(
    "not-an-import",
  )
  fmt.Println(alias.Value)
}
// import "ghost"
``}
    :imports {"main.go" ["fmt" "example.org.single" "example.org.lib" "example.org.driver" "math"]}
    :edges [["main.go" "?.fmt"] ["main.go" "?.example.org.lib"]
            ["main.go" "?.example.org.driver"] ["main.go" "?.math"]
            ["main.go" "?.example.org.single"]]}
   {:name "clojuredart nested namespaces, macro requires and platform libraries"
    :files {"src/app/src/icare/ui/main.cljd" ``
(ns icare.ui.main
  (:require [icare.ui.shared :refer [render-card]]
            [icare.ui.normalized-ast :as ast]
            ["package:flutter/material.dart" :as m]
            ["dart:ui" :as ui])
  (:require-macros [icare.macros :as macros]))
(def example "(:require [icare.phantom])")
; (:require [icare.ghost])
``
            "src/app/src/icare/ui/shared.cljd" "(ns icare.ui.shared)\n"
            "src/app/src/icare/ui/normalized_ast.cljd" "(ns icare.ui.normalized-ast)\n"
            "src/app/src/icare/macros.clj" "(ns icare.macros)\n"
            "lib/cljd-out/cljd/flutter.dart" "generated code\n"}
    :ignored ["lib/cljd-out/cljd/flutter.dart"]
    :imports {"src/app/src/icare/ui/main.cljd" ["icare.ui.shared" "icare.ui.normalized_ast"
                                                "?.flutter.material" "?.dart.ui" "icare.macros"]}
    :edges [["src.app.src.icare.ui.main.cljd" "src.app.src.icare.ui.shared.cljd"]
            ["src.app.src.icare.ui.main.cljd" "src.app.src.icare.ui.normalized_ast.cljd"]
            ["src.app.src.icare.ui.main.cljd" "src.app.src.icare.macros.clj"]
            ["src.app.src.icare.ui.main.cljd" "?.flutter.material"]
            ["src.app.src.icare.ui.main.cljd" "?.dart.ui"]]}
   {:name "swift cross-file declarations, extensions and ambiguous symbols"
    :files {"App/Main.swift" ``
import Foundation
public final class Controller {
    let worker = Worker()
    let result = Shared()
    let example = "Ghost Phantom"
}
private extension Worker { var ready: Bool { true } }
/* Ghost Phantom */
``
            "App/Worker.swift" "actor Worker {}\n"
            "App/First.swift" "struct Shared {}\n"
            "App/Second.swift" "struct Shared {}\n"
            "App/Ghost.swift" "struct Ghost {}\n"}
    :edges [["App.Main.swift" "App.Worker.swift"] ["App.Main.swift" "?.Foundation"]]}
   {:name "swift references stay local when sibling worktrees repeat declarations"
    :files {"otto-ios/OttoClip/ClipState.swift" "final class ClipState { let recipe = Recipe(); let client = APIClient(); let ambiguous = Shared(); let foreign = ForeignType() }\n"
            "otto-ios/OttoClip/Models.swift" "struct Recipe {}\n"
            "otto-ios/OttoClip/APIClient.swift" "final class APIClient {}\n"
            "otto-ios/OttoClip/First.swift" "struct Shared {}\n"
            "otto-ios/OttoClip/Second.swift" "struct Shared {}\n"
            "otto-ios/OttoClip/UI/ClipView.swift" "struct ClipView { let state = ClipState(); let recipe = Recipe() }\n"
            "otto-ios/OttoClip/UI/Models.swift" "struct Recipe {}\n"
            "otto-ios/OttoTests/Checks.swift" "let state = ClipState()\nlet ambiguous = Recipe()\n"
            "otto-ios-reporting/OttoClip/ClipState.swift" "final class ClipState { let recipe = Recipe() }\n"
            "otto-ios-reporting/OttoClip/Models.swift" "struct Recipe {}\nstruct Shared {}\n"
            "otto-ios-reporting/OttoClip/UI/ClipView.swift" "struct ClipView { let state = ClipState(); let recipe = Recipe() }\n"
            "unrelated/Outside.swift" "let ambiguous = ClipState()\n"
            "robot/sketch.ino" "struct ForeignType {};\nstruct APIClient {};\n"}
    :edges [["otto-ios.OttoClip.ClipState.swift" "otto-ios.OttoClip.APIClient.swift"]
            ["otto-ios.OttoClip.ClipState.swift" "otto-ios.OttoClip.Models.swift"]
            ["otto-ios.OttoClip.UI.ClipView.swift" "otto-ios.OttoClip.ClipState.swift"]
            ["otto-ios.OttoClip.UI.ClipView.swift" "otto-ios.OttoClip.UI.Models.swift"]
            ["otto-ios.OttoTests.Checks.swift" "otto-ios.OttoClip.ClipState.swift"]
            ["otto-ios-reporting.OttoClip.ClipState.swift" "otto-ios-reporting.OttoClip.Models.swift"]
            ["otto-ios-reporting.OttoClip.UI.ClipView.swift" "otto-ios-reporting.OttoClip.ClipState.swift"]
            ["otto-ios-reporting.OttoClip.UI.ClipView.swift" "otto-ios-reporting.OttoClip.Models.swift"]]}
   {:name "swift direct free-function calls exclude member calls and private helpers"
    :files {"app/State.swift" "struct State { func run() { debugLog(\"Ghost()\"); secret(); hidden(); memberOnly() } }\n"
            "app/DebugLog.swift" "func debugLog(_ message: String) {}\nprivate func secret() {}\nfileprivate func hidden() {}\n"
            "app/Member.swift" "let a = logger.debugLog(\"a\")\nlet b = logger . debugLog (\"b\")\n"
            "app/Logger.swift" "struct Logger {\n    func memberOnly() {}\n}\n"
            "app/Ghost.swift" "func Ghost() {}\n"
            "app-copy/State.swift" "struct State { func run() { debugLog(\"hello\") } }\n"
            "app-copy/DebugLog.swift" "public func debugLog(_ message: String) {}\n"}
    :edges [["app.State.swift" "app.DebugLog.swift"]
            ["app-copy.State.swift" "app-copy.DebugLog.swift"]]}
   {:name "arduino includes, calls across tabs and unparsed headers"
    :files {"robot/main.ino" ``
#include "pins.h"
#include <Servo.h>
void setup() { calibrate(); }
void loop() { readSensor(); }
const char *example = "readGhost(); #include <Phantom.h>";
// readGhost();
``
            "robot/sensors.ino" "int readSensor() { return 1; }\nstatic void calibrate() {}\n"
            "robot/ghost.ino" "int readGhost() { return 0; }\n"
            "robot/pins.h" "#define LED 13\n"}
    :edges [["robot.main.ino" "robot.sensors.ino"] ["robot.main.ino" "robot.pins.h"]
            ["robot.main.ino" "?.Servo"]]}
   {:name "html local assets, import maps and inert commented markup"
    :files {"web/index.html" ``
<!doctype html>
<!-- <script src="phantom.js"></script> -->
<link rel="stylesheet" href = "./theme.css?version=2">
<script type="module" src = "./app.js"></script>
<img src="/images/logo.svg#icon" data-src="lazy.svg">
<a href="/navigation">Link</a>
<script src="https://cdn.example/app.js"></script>
<script type="importmap">{"imports":{"renderer":"/lib/renderer.js"}}</script>
``
            "web/theme.css" "body { color: black; }\n"
            "web/app.js" "import {render} from 'renderer';\n"
            "lib/renderer.js" "export const render = () => {};\n"
            "images/logo.svg" "<svg/>\n"}
    :edges [["web.index.html" "web.theme.css"] ["web.index.html" "web.app.js"]
            ["web.index.html" "images.logo.svg"] ["web.app.js" "lib.renderer.js"]]}
   {:name "css imports, fonts, URL suffixes and quoted example text"
    :files {"web/styles/main.css" ``
@import "./base.css" screen;
@font-face { src: url('../../fonts/body.woff2?v=3'); }
.hero { background: url(../images/hero.svg#main); }
.note::after { content: "url(phantom.png)"; }
.remote { background: url(https://example.org/image.png); }
.inline { background: url(data:image/png;base64,abcd); }
/* @import "ghost.css"; */
``
            "web/styles/base.css" "body { margin: 0; }\n"
            "web/images/hero.svg" "<svg/>\n"
            "fonts/body.woff2" "\x00binary"}
    :imports {"web/styles/main.css" ["web.styles.base" "fonts.body" "web.images.hero"]}
    :edges [["web.styles.main.css" "web.styles.base.css"]
            ["web.styles.main.css" "fonts.body.woff2"]
            ["web.styles.main.css" "web.images.hero.svg"]]}
   {:name "shell hidden paths do not become dependencies on a directory config"
    :files {"shop/otto.sh" ``#!/bin/sh
[ -f .env ] && . ./.env
source ./.env.local
source ../.secrets/setup.sh
source ./env.sh
exec .venv/bin/python -m otto.mcp.core
``
            "shop/.env" "SECRET=example\n"
            "shop/.env.local" "SECRET=example\n"
            ".secrets/setup.sh" "export SECRET=example\n"
            "shop/env.sh" "export MODE=development\n"
            "shop/visualize_config" "box otto\n"}
    :ignored ["shop/.env" "shop/.env.local" ".secrets/setup.sh"]
    :imports {"shop/otto.sh" ["shop.env"]}
    :edges [["shop.otto.sh" "shop.env.sh"]]}
   {:name "shell extensionless files keep their filename during resolution"
    :files {"launch.sh" "#!/bin/sh\n./missing\n./bin/worker\n"
            "missing/visualize_config" "lines\n"
            "bin/worker" "#!/bin/sh\nsource ./setup.sh\n"
            "bin/setup.sh" "export READY=yes\n"}
    :edges [["launch.sh" "?.missing"]
            ["launch.sh" "bin.worker"]
            ["bin.worker" "bin.setup.sh"]]}
   {:name "shell extensionless launchers and compiler continuations"
    :files {"launch" ``#!/bin/sh
here=$(cd "$(dirname "$0")" && pwd)
source "$here/env.sh"
cc -c \
  src/main.c \
  src/helper.c
exec "$here/bin/worker" --verbose
# ./phantom
``
            "env.sh" "export MODE=development\n"
            "bin/worker" "#!/bin/sh\nprintf 'ready'\n"
            "src/main.c" "int main(void) { return 0; }\n"
            "src/helper.c" "int helper(void) { return 1; }\n"}
    :edges [["launch" "env.sh"] ["launch" "bin.worker"]]}
   {:name "visualize plans link exact project files and preserve logical tasks"
    :files {"plans/release.visualize" ``
ship
    src/main.py
    checks
checks
    docs/review.md
    missing.txt
``
            "src/main.py" "print('hello')\n"
            "docs/review.md" "# Review\n"
            "other/main.py" "print('unrelated')\n"}
    :nodes ["plans.release.ship" "plans.release.checks" "plans.release.missing.txt"
            "src.main.py" "docs.review.md" "other.main.py"]
    :edges [["plans.release.ship" "src.main.py"] ["plans.release.ship" "plans.release.checks"]
            ["plans.release.checks" "docs.review.md"] ["plans.release.checks" "plans.release.missing.txt"]]}])
