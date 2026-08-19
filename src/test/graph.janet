# The config file on disk.

(import ../visualize/graph)
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
  (def first-draw (graph/draw "." conf))
  (t/is= 0 (length (string/find-all "node fresh" (string (first-draw 3))))
         "the first drawing flashes nothing")

  # A file written since then is new to this drawing.
  (os/touch "src/visualize/color.janet")
  (graph/forget-scan)
  (def second-draw (graph/draw "." conf))
  (t/is= 1 (length (string/find-all `class="node fresh"` (string (second-draw 3))))
         "one file moved, one node flashes")

  # And without the verb, nothing is marked however much moved.
  (spit conf "(lines)\n")
  (os/touch "src/visualize/select.janet")
  (graph/forget-scan)
  (def unasked (graph/draw "." conf))
  (t/is= 0 (length (string/find-all "fresh" (string (unasked 3))))
         "the flash is the verb's, not the watcher's")
  (os/rm conf))

(os/rm scratch)
