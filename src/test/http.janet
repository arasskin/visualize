(import ../visualize/http)
(import ./harness :as t)

(t/test "a plain filename in web/ is served"
  (t/is= "term.js" (http/static-file "/term.js"))
  (t/is= "app.js" (http/static-file "/app.js"))
  (t/is= "style.css" (http/static-file "/style.css"))
  (t/is= "index.html" (http/static-file "/index.html")))

(t/test "a name may not describe a path"

  (t/is= nil (http/static-file "/../visualize.conf"))
  (t/is= nil (http/static-file "/../../etc/passwd"))
  (t/is= nil (http/static-file "/src/pty.janet"))
  (t/is= nil (http/static-file "/web/term.js"))
  (t/is= nil (http/static-file "/a/b"))
  (t/is= nil (http/static-file "/..\\windows"))
  (t/is= nil (http/static-file "/")))

(t/test "a dotfile is not servable"
  (t/is= nil (http/static-file "/.gitignore"))
  (t/is= nil (http/static-file "/.env")))

(t/test "odd characters are refused rather than interpreted"

  (t/is= nil (http/static-file "/term%2Ejs"))
  (t/is= nil (http/static-file "/term.js?k=1"))
  (t/is= nil (http/static-file "/term js"))
  (t/is= nil (http/static-file "/term;js"))
  (t/is= nil (http/static-file "/$(whoami)")))

(t/test "javascript is labelled so a browser will execute it"

  (t/ok (string/has-prefix? "text/javascript" (http/content-type "term.js")))
  (t/ok (string/has-prefix? "text/javascript" (http/content-type "app.mjs")))
  (t/ok (string/has-prefix? "text/css" (http/content-type "style.css")))
  (t/ok (string/has-prefix? "text/html" (http/content-type "index.html")))
  (t/ok (string/has-prefix? "text/plain" (http/content-type "notes.txt"))
        "an unknown extension falls back rather than guessing"))

(t/test "every file the page actually asks for is servable"

  (def src-dir (os/realpath (string (dyn :current-file) "/../..")))
  (def here (string src-dir "/web"))

  (def roots [here (string src-dir "/../external-src/wterm")])
  (defn servable? [name]
    (find |(= :file (os/stat (string $ "/" name) :mode)) roots))
  (def markup (slurp (string here "/index.html")))
  (def wanted @[])

  (each pattern [~(* `src="/` (<- (some (if-not `"` 1))) `"`)
                 ~(* `href="/` (<- (some (if-not `"` 1))) `"`)]
    (each found (or (peg/match ~(any (+ ,pattern 1)) markup) [])
      (array/push wanted found)))
  (t/ok (> (length wanted) 0) "the page references at least one file")
  (each name wanted
    (t/is= name (http/static-file (string "/" name))
           (string name " is referenced by index.html and must be servable"))
    (t/ok (servable? name)
          (string name " exists in web/ or external-src/wterm/")))

  (def script (slurp (string here "/app.js")))
  (each found (or (peg/match ~(any (+ (* `from './` (<- (some (if-not "'" 1))) "'") 1)) script) [])
    (t/is= found (http/static-file (string "/" found))
           (string found " is imported by app.js and must be servable"))))

(t/test "a connection serves many requests, and close still means close"

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

  (def handler (fn [_] ["200 OK" "text/plain" "a"]))
  (def [one port-one loop-one] (http/serve 8931 5 handler))
  (def [two port-two loop-two] (http/serve 8931 5 handler))
  (t/ok (not= port-one port-two)
        "the second server must not share the first one's port")
  (t/is= (inc port-one) port-two "it lands on the very next port")
  (:close one)
  (:close two))
