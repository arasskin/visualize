# The config file on disk.

(import ../visualize/graph)
(import ../visualize/scan)
(import ./harness :as t)

(def- scratch "/tmp/visualize-graph-test.janet")

(t/test "reading a config gives one entry per written line"
  # A trailing newline is one empty string on the end, and it is dropped --
  # it is how a text file ends, not a line someone wrote.
  (spit scratch "(lines)\n(hide src.test)\n")
  (t/is= ["(lines)" "(hide src.test)"] (graph/read-config scratch))
  (spit scratch "(lines)")
  (t/is= ["(lines)"] (graph/read-config scratch)
         "a file with no trailing newline reads the same"))

(t/test "a config round trips unchanged"
  (spit scratch "(lines)\n(hide src.test)\n")
  (def lines (graph/read-config scratch))
  (graph/write-config scratch lines)
  (t/is= lines (graph/read-config scratch))
  (t/is= "(lines)\n(hide src.test)\n" (string (slurp scratch))
         "and the file is the lines, newline-terminated"))

(t/test "the editor's actions are the ones the page can send"
  (t/is= ["a" "b"] (graph/edit ["a" "b"] "run" -1))
  (t/is= ["b"] (graph/edit ["a" "b"] "delete" 0))
  (t/is= ["a" "b"] (graph/edit ["a" "b"] "delete" 9)
         "an index off the end deletes nothing")
  (t/is= ["a" "" "b"] (graph/edit ["a" "b"] "insert-above" 1))
  (t/is= ["a" "" "b"] (graph/edit ["a" "b"] "insert-below" 0))
  (t/is= [""] (graph/edit [] "insert-below" -1)
         "the first line of an empty file"))

(t/test "animate flashes what moved since the last drawing"
  # NOTHING ON THE FIRST DRAW: there is no previous one to differ from, and
  # flashing the whole graph on load would say only that the graph exists.
  (def conf "/tmp/visualize-animate-test.conf")
  (spit conf "(animate)\n")
  # A FRESH SCAN PER DRAWING, the way the server does it after the watcher
  # says the source moved. Nothing is cached between them, so what the
  # drawing compares against is the drawing before it and nothing else.
  (def first-draw (graph/draw (scan/scan ".") conf))
  (t/is= 0 (length (string/find-all "node fresh" (string (first-draw 3))))
         "the first drawing flashes nothing")

  # A file written since then is new to this drawing.
  (os/touch "src/visualize/color.janet")
  (def second-draw (graph/draw (scan/scan ".") conf))
  (t/is= 1 (length (string/find-all `class="node fresh"` (string (second-draw 3))))
         "one file moved, one node flashes")

  # And without the verb, nothing is marked however much moved.
  (spit conf "(lines)\n")
  (os/touch "src/visualize/select.janet")
  (def unasked (graph/draw (scan/scan ".") conf))
  (t/is= 0 (length (string/find-all "fresh" (string (unasked 3))))
         "the flash is the verb's, not the watcher's")
  (os/rm conf))

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
                     (string ((graph/draw (scan/scan dir) conf) 3)))))

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

(os/rm scratch)
