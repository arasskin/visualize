# Serving files out of web/, and refusing to serve anything else.
#
# THE BUG THIS FILE EXISTS FOR: the server had a route per file -- one for
# style.css, one for app.js -- and when app.js grew an `import './term.js'`,
# nothing served term.js. The 404 aborted the whole ES module, so panning,
# zooming, the config editor and the terminal all stopped working at once. One
# missing line took out every interaction on the page.
#
# A whitelist of routes invites exactly that failure, so files are now served
# by name. That is only safe if a name cannot describe a path, which is what
# most of these assertions are about.

(import ../visualize/http)
(import ./harness :as t)

(t/test "a plain filename in web/ is served"
  (t/is= "term.js" (http/static-file "/term.js"))
  (t/is= "app.js" (http/static-file "/app.js"))
  (t/is= "style.css" (http/static-file "/style.css"))
  (t/is= "index.html" (http/static-file "/index.html")))

(t/test "a name may not describe a path"
  # `..` and `/` are REFUSED rather than resolved. There is no traversal to
  # get subtly wrong when the answer to anything containing a separator is no.
  (t/is= nil (http/static-file "/../visualize.janet"))
  (t/is= nil (http/static-file "/../../etc/passwd"))
  (t/is= nil (http/static-file "/visualize/pty.janet"))
  (t/is= nil (http/static-file "/web/term.js"))
  (t/is= nil (http/static-file "/a/b"))
  (t/is= nil (http/static-file "/..\\windows"))
  (t/is= nil (http/static-file "/")))

(t/test "a dotfile is not servable"
  (t/is= nil (http/static-file "/.gitignore"))
  (t/is= nil (http/static-file "/.env")))

(t/test "odd characters are refused rather than interpreted"
  # An allowlist, so anything unexpected is a no by default -- including the
  # percent-encodings a client might use to smuggle a separator past a
  # blacklist.
  (t/is= nil (http/static-file "/term%2Ejs"))
  (t/is= nil (http/static-file "/term.js?k=1"))
  (t/is= nil (http/static-file "/term js"))
  (t/is= nil (http/static-file "/term;js"))
  (t/is= nil (http/static-file "/$(whoami)")))

(t/test "javascript is labelled so a browser will execute it"
  # A module served as text/plain is refused by the browser, and the failure
  # looks like the file is missing rather than mislabelled -- which is a
  # confusing hour if it ever happens.
  (t/ok (string/has-prefix? "text/javascript" (http/content-type "term.js")))
  (t/ok (string/has-prefix? "text/javascript" (http/content-type "app.mjs")))
  (t/ok (string/has-prefix? "text/css" (http/content-type "style.css")))
  (t/ok (string/has-prefix? "text/html" (http/content-type "index.html")))
  (t/ok (string/has-prefix? "text/plain" (http/content-type "notes.txt"))
        "an unknown extension falls back rather than guessing"))

(t/test "every file the page actually asks for is servable"
  # The regression, stated directly: if index.html references it, the server
  # has to be willing to serve it.
  (def here (string (os/realpath (string (dyn :current-file) "/../..")) "/web"))
  (def markup (slurp (string here "/index.html")))
  (def wanted @[])
  # src="/x" and href="/x" -- the two ways the page names a file.
  (each pattern [~(* `src="/` (<- (some (if-not `"` 1))) `"`)
                 ~(* `href="/` (<- (some (if-not `"` 1))) `"`)]
    (each found (or (peg/match ~(any (+ ,pattern 1)) markup) [])
      (array/push wanted found)))
  (t/ok (> (length wanted) 0) "the page references at least one file")
  (each name wanted
    (t/is= name (http/static-file (string "/" name))
           (string name " is referenced by index.html and must be servable"))
    (t/ok (= :file (os/stat (string here "/" name) :mode))
          (string name " exists in web/")))
  # And the import that started all this: app.js pulls in term.js, which no
  # route served.
  (def script (slurp (string here "/app.js")))
  (each found (or (peg/match ~(any (+ (* `from './` (<- (some (if-not "'" 1))) "'") 1)) script) [])
    (t/is= found (http/static-file (string "/" found))
           (string found " is imported by app.js and must be servable"))))
