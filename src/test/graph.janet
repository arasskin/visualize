# The config file on disk.

(import ../visualize/graph)
(import ./harness :as t)

(def- scratch "/tmp/visualize-graph-test.janet")

(t/test "reading a config gives one entry per written line"
  # A trailing newline is one empty string on the end, and it is dropped --
  # it is how a text file ends, not a line someone wrote.
  (spit scratch "(show-lines)\n(hide src.test)\n")
  (t/is= ["(show-lines)" "(hide src.test)"] (graph/read-config scratch))
  (spit scratch "(show-lines)")
  (t/is= ["(show-lines)"] (graph/read-config scratch)
         "a file with no trailing newline reads the same"))

(t/test "a config round trips unchanged"
  (spit scratch "(show-lines)\n(hide src.test)\n")
  (def lines (graph/read-config scratch))
  (graph/write-config scratch lines)
  (t/is= lines (graph/read-config scratch))
  (t/is= "(show-lines)\n(hide src.test)\n" (string (slurp scratch))
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

(os/rm scratch)
