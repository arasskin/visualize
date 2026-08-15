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

(t/test "a connection serves many requests, and close still means close"
  # KEEP-ALIVE IS THE ANTI-STALL. One connection per request churned the
  # browser's six-per-origin pool during a hard scroll; a reply lost to the
  # fd race left a zombie slot the browser reaps on a ~10s timeout, and a
  # few zombies froze every fetch the pane makes. Reuse removes the churn.
  (def handler (fn [req] ["200 OK" "text/plain" (string "echo:" (req :path))]))
  (def [server port accept-loop] (http/serve 8941 5 handler))
  (ev/go accept-loop)
  (def conn (net/connect "127.0.0.1" (string port)))
  (defn ask [path & extra]
    (:write conn (string "GET " path " HTTP/1.1\r\nHost: x\r\n"
                         (string/join extra "") "\r\n"))
    (var reply @"")
    (var tries 0)
    (while (and (< tries 40) (not (string/find (string "echo:" path) (string reply))))
      (++ tries)
      (when-let [chunk (:read conn 4096 nil 1)]
        (buffer/push-string reply chunk)))
    (string reply))
  (def first-reply (ask "/one"))
  (t/ok (string/find "echo:/one" first-reply) "the first request is answered")
  (t/ok (string/find "keep-alive" first-reply) "and the connection is offered onward")
  (t/ok (string/find "echo:/two" (ask "/two"))
        "a second request on the SAME connection is answered")
  (def parting (ask "/three" "Connection: close\r\n"))
  (t/ok (string/find "echo:/three" parting) "a request asking to close is answered")
  (t/ok (string/find "Connection: close" parting) "and told the connection ends")
  (:close conn)
  (:close server))

(t/test "two servers walk to two ports, despite SO_REUSEPORT"
  # THE FREEZE THAT CAME FROM DEVELOPING INSIDE THE TOOL. The runtime sets
  # SO_REUSEPORT on every server socket, so binding a taken port SUCCEEDS --
  # the port walk never walked, every sandbox server silently joined the live
  # server's port, and the kernel split the page's requests between them:
  # wrong token, wrong supervisor, a terminal frozen at random. The walk now
  # probes by connecting, which cannot be fooled by a permissive bind.
  (def handler (fn [_] ["200 OK" "text/plain" "a"]))
  (def [one port-one loop-one] (http/serve 8931 5 handler))
  (def [two port-two loop-two] (http/serve 8931 5 handler))
  (t/ok (not= port-one port-two)
        "the second server must not share the first one's port")
  (t/is= (inc port-one) port-two "it lands on the very next port")
  (:close one)
  (:close two))
