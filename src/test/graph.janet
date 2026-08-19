# The config file on disk.

(import ../visualize/graph)
(import ../visualize/config)
(import ../visualize/scan)
(import ./harness :as t)

# The three steps the server takes for one drawing: read the config, run it,
# render it. Here rather than in graph, because graph draws a PARSED config
# and knows nothing about files.
(defn- drawn [tree path]
  (def lines (config/read-config path))
  (def [state problems] (config/run lines))
  (def [ok result] (graph/render-svg tree state))
  [lines problems ok result])

(t/test "animate flashes what moved since the last drawing"
  # NOTHING ON THE FIRST DRAW: there is no previous one to differ from, and
  # flashing the whole graph on load would say only that the graph exists.
  (def conf "/tmp/visualize-animate-test.conf")
  (spit conf "(animate)\n")
  # A FRESH SCAN PER DRAWING, the way the server does it after the watcher
  # says the source moved. Nothing is cached between them, so what the
  # drawing compares against is the drawing before it and nothing else.
  (def first-draw (drawn (scan/scan ".") conf))
  (t/is= 0 (length (string/find-all "node fresh" (string (first-draw 3))))
         "the first drawing flashes nothing")

  # A file written since then is new to this drawing.
  (os/touch "src/visualize/color.janet")
  (def second-draw (drawn (scan/scan ".") conf))
  (t/is= 1 (length (string/find-all `class="node fresh"` (string (second-draw 3))))
         "one file moved, one node flashes")

  # And without the verb, nothing is marked however much moved.
  (spit conf "(lines)\n")
  (os/touch "src/visualize/select.janet")
  (def unasked (drawn (scan/scan ".") conf))
  (t/is= 0 (length (string/find-all "fresh" (string (unasked 3))))
         "the flash is the verb's, not the watcher's")
  (os/rm conf))

(t/test "a line count is written out in full"
  # No `1.3k`: abbreviating rounds away the difference between files a
  # hundred lines apart, which is the comparison the number is on the box to
  # support. Asserted on the drawing rather than on a formatter, since the
  # label is the thing that has to be right.
  (def conf "/tmp/visualize-lines-test.conf")
  (spit conf "(lines)\n")
  (def svg (string ((drawn (scan/scan ".") conf) 3)))
  (t/ok (nil? (peg/find ~(* (some (range "09")) "k") svg))
        "no k-abbreviated count")
  (t/ok (nil? (peg/find ~(* (some (range "09")) "." (some (range "09")) "k") svg))
        "and nothing rounded to a tenth")
  # And a real count is on the drawing, so the assertions above are not
  # passing because nothing was labelled at all.
  (t/ok (peg/find ~(* ">" (some (range "09")) "<") svg) "counts are drawn")
  (os/rm conf))

(t/test "a drawing of a stale tree does not consume the flash"
  # THE DEFERRED FLASH. The server holds the scanned tree and the watcher
  # polls, so between an edit and the tick that notices it there is a
  # window. A drawing made in that window sees the OLD stamps: the edited
  # file looks unchanged, and recording those stamps as seen meant the flash
  # arrived on whatever redraw came after the tick -- a file nobody was
  # working on appearing to flash out of nowhere.
  #
  # Fixed by checking the tree per draw rather than only when the watcher
  # fires; this asserts the behaviour that fix produces.
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
  # An edit the held tree has not seen yet.
  (spit (string dir "/b.py") "x = 222222\n")
  # A FRESH SCAN is what the server now does per draw, so the edit is caught
  # by the drawing that follows it rather than by a later one.
  (t/is= ["b"] (fresh-in (scan/scan dir)))
  (t/is= [] (fresh-in (scan/scan dir)) "and is not shown twice")
  (clear))

(t/test "a file added, edited or removed between drawings"
  # A TREE OF ITS OWN, so adding and removing files is not done to the repo
  # the suite is running out of.
  (def dir "/tmp/visualize-animate-tree")
  # Removed file by file: this Janet has no recursive rmdir, and the tree is
  # flat by construction.
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

  # THE BASELINE IS PER PROCESS, not per tree -- "since you last looked" is
  # a question about this session. The test above drew this repository, so
  # the first drawing of a DIFFERENT tree finds every node new, which is
  # correct and is why this one is discarded rather than asserted on.
  (flashed)
  (t/is= [] (flashed) "a second drawing of an unchanged tree flashes nothing")

  # A FILE THAT DID NOT EXIST is new to this drawing.
  (spit (string dir "/c.py") "import a\n")
  (t/is= ["c"] (flashed) "a new file flashes")

  (t/is= [] (flashed) "and stops once it has been seen")

  # WITHIN THE SAME SECOND, which is the case animate exists for: save a
  # file and the watcher redraws a moment later. mtime counts whole seconds,
  # so the size is what catches this.
  (spit (string dir "/b.py") "x = 222222222\n")
  (t/is= ["b"] (flashed) "an edit inside one second still flashes")

  # A REMOVED FILE flashes nothing -- it is not there to flash, and the
  # nodes that remain have not moved.
  (os/rm (string dir "/c.py"))
  (t/is= [] (flashed))

  (clear))

