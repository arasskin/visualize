(import ../visualize/graph)
(import ../visualize/config)
(import ../visualize/scan)
(import ./harness :as t)

(defn- drawn [tree path]
  (def lines (config/read-config path))
  (def [state problems] (config/run lines))
  (def [ok result] (graph/render-svg tree state))
  [lines problems ok result])

(t/test "animate flashes what moved since the last drawing"

  (def conf "/tmp/visualize-animate-test.conf")
  (spit conf "(animate)\n")

  (def first-draw (drawn (scan/scan ".") conf))
  (t/is= 0 (length (string/find-all "node fresh" (string (first-draw 3))))
         "the first drawing flashes nothing")

  (os/touch "src/visualize/color.janet")
  (def second-draw (drawn (scan/scan ".") conf))
  (t/is= 1 (length (string/find-all `class="node fresh"` (string (second-draw 3))))
         "one file moved, one node flashes")

  (spit conf "(lines)\n")
  (os/touch "src/visualize/select.janet")
  (def unasked (drawn (scan/scan ".") conf))
  (t/is= 0 (length (string/find-all "fresh" (string (unasked 3))))
         "the flash is the verb's, not the watcher's")
  (os/rm conf))

(t/test "a nested box becomes a nested cluster"

  (def dir "/tmp/visualize-nested-boxes")
  (defn clear []
    (each entry (try (os/dir dir) ([_] []))
      (os/rm (string dir "/" entry)))
    (try (os/rmdir dir) ([_] nil)))
  (clear)
  (os/mkdir dir)
  (spit (string dir "/api.v1.users.py") "x = 1\n")
  (spit (string dir "/web.page.py") "y = 2\n")
  (def conf (string dir "/vz.conf"))
  (spit conf "(box api blue)\n(box api.v1 red)\n")

  (def svg (string ((drawn (scan/scan dir) conf) 3)))
  (def clusters
    (peg/match ~(any (+ (* `class="cluster"` (any (if-not "<title>" 1))
                           "<title>" (<- (any (if-not "<" 1)))) 1))
               svg))
  (t/is= ["cluster_api" "cluster_api.v1"] (sort clusters)
         "both boxes are drawn, not just the one declared first")

  (t/ok (string/find "#22a6f2" svg) "the outer box is blue")
  (t/ok (string/find "#ff4d6d" svg) "and the inner one red")
  (clear))

(t/test "a line count is written out in full"

  (def conf "/tmp/visualize-lines-test.conf")
  (spit conf "(lines)\n")
  (def svg (string ((drawn (scan/scan ".") conf) 3)))
  (t/ok (nil? (peg/find ~(* (some (range "09")) "k") svg))
        "no k-abbreviated count")
  (t/ok (nil? (peg/find ~(* (some (range "09")) "." (some (range "09")) "k") svg))
        "and nothing rounded to a tenth")

  (t/ok (peg/find ~(* ">" (some (range "09")) "<") svg) "counts are drawn")
  (os/rm conf))

(t/test "a drawing of a stale tree does not consume the flash"

  (def dir "/tmp/visualize-stale-tree")
  (defn clear []
    (each entry (try (os/dir dir) ([_] []))
      (os/rm (string dir "/" entry)))
    (try (os/rmdir dir) ([_] nil)))
  (clear)
  (os/mkdir dir)
  (def conf (string dir "/vz.conf"))
  (spit conf "(animate)\n")
  (spit (string dir "/a.py") "import b\n")
  (spit (string dir "/b.py") "x = 1\n")

  (defn fresh-in [tree]
    (sort (peg/match ~(any (+ (* `class="node fresh"` (any (if-not "<title>" 1))
                                 "<title>" (<- (some (if-not "<" 1)))) 1))
                     (string ((drawn tree conf) 3)))))

  (fresh-in (scan/scan dir))

  (spit (string dir "/b.py") "x = 222222\n")

  (t/is= ["b.py"] (fresh-in (scan/scan dir)))
  (t/is= [] (fresh-in (scan/scan dir)) "and is not shown twice")
  (clear))

(t/test "a file added, edited or removed between drawings"

  (def dir "/tmp/visualize-animate-tree")

  (defn clear []
    (each entry (try (os/dir dir) ([_] []))
      (os/rm (string dir "/" entry)))
    (try (os/rmdir dir) ([_] nil)))
  (clear)
  (os/mkdir dir)
  (def conf (string dir "/vz.conf"))
  (spit conf "(animate)\n")
  (spit (string dir "/a.py") "import b\n")
  (spit (string dir "/b.py") "x = 1\n")

  (defn flashed []
    (sort (peg/match ~(any (+ (* `class="node fresh"` (any (if-not "<title>" 1))
                                 "<title>" (<- (some (if-not "<" 1)))) 1))
                     (string ((drawn (scan/scan dir) conf) 3)))))

  (flashed)
  (t/is= [] (flashed) "a second drawing of an unchanged tree flashes nothing")

  (spit (string dir "/c.py") "import a\n")
  (t/is= ["c.py"] (flashed) "a new file flashes")

  (t/is= [] (flashed) "and stops once it has been seen")

  (spit (string dir "/b.py") "x = 222222222\n")
  (t/is= ["b.py"] (flashed) "an edit inside one second still flashes")

  (os/rm (string dir "/c.py"))
  (t/is= [] (flashed))

  (clear))

(t/test "aliased folded nodes keep their final name component instead of an extension"
  (def tree {:nodes [{:name "src.visualize.parsers.janet.janet" :label "janet\n.janet" :ours true}
                     {:name "src.visualize.parsers.python.janet" :label "python\n.janet" :ours true}]
             :edges [] :ours {} :stamps {}
             :sizes {"src.visualize.parsers.janet.janet" 400
                     "src.visualize.parsers.python.janet" 341}})
  (each sized [false true]
    (def state (config/new-state))
    (put state :aliases [{:alias "~" :prefix "src.visualize"}])
    (put state :folded ["src.visualize.parsers"])
    (put state :sized sized)
    (def [ok svg] (graph/render-svg tree state))
    (t/ok ok)
    (t/ok (string/find ">parsers</text>" svg) "parsers remains part of the folded name")
    (t/ok (not (string/find ">.parsers" svg)) "a folded node has no extension row")
    (when sized (t/ok (string/find ">741</text>" svg) "the aggregate line count stays separate"))))

