# The config file on disk.

(import ../visualize/graph)
(import ./harness :as t)

(def- scratch "/tmp/visualize-graph-test.janet")

(t/test "the file always has a blank line at each end"
  # ROOM TO WRITE IN. They are ordinary empty lines -- the parser skips a
  # blank the way it skips a comment -- but the file always carries them, so
  # there is somewhere to start typing above the first verb and below the
  # last without making room first.
  (t/is= ["" "(a)" "(b)" ""] (graph/margins ["(a)" "(b)"]))
  (t/is= ["" "(a)" ""] (graph/margins ["" "(a)" ""]) "already margined")
  # AT LEAST one, not exactly one. Trimming to exactly one swallowed a line
  # opened NEXT TO a margin -- alt+N on the first verb wrote a blank the next
  # read threw away, so the key silently did nothing.
  (t/is= ["" "" "(a)" ""] (graph/margins ["" "" "(a)" ""])
         "a blank someone asked for is kept")
  (t/is= ["" "(a)" "" ""] (graph/margins ["" "(a)" "" ""]))
  (t/is= ["" ""] (graph/margins []) "an empty file is its two margins")
  (t/is= ["" ""] (graph/margins [""]) "and one blank becomes two")
  # A blank BETWEEN lines is the writer's own spacing and is left alone.
  (t/is= ["" "(a)" "" "(b)" ""] (graph/margins ["(a)" "" "(b)"])))

(t/test "reading a config gives one entry per written line, plus margins"
  # A trailing newline is one empty string on the end, and it is dropped --
  # it is how a text file ends, not a line someone wrote. The margins are
  # then put back, because those ARE lines someone can write in.
  (spit scratch "(show-lines)\n(hide src.test)\n")
  (t/is= ["" "(show-lines)" "(hide src.test)" ""] (graph/read-config scratch))
  (spit scratch "(show-lines)")
  (t/is= ["" "(show-lines)" ""] (graph/read-config scratch)
         "a file with no trailing newline reads the same"))

(t/test "a config round trips unchanged"
  (spit scratch "(show-lines)\n(hide src.test)\n")
  (def lines (graph/read-config scratch))
  (graph/write-config scratch lines)
  (t/is= lines (graph/read-config scratch))
  (t/is= "\n(show-lines)\n(hide src.test)\n\n" (string (slurp scratch))
         "and the margins are on disk, not just in the panel")
  # A caller that hands over lines with no margins still writes a file with
  # them, so the panel and the file cannot disagree.
  (graph/write-config scratch ["(show-lines)"])
  (t/is= ["" "(show-lines)" ""] (graph/read-config scratch)))

(t/test "deleting a margin gets it back"
  # The margin is a real line, so it can be deleted -- and then it is not
  # there, which is the one thing the file may not be.
  (t/is= ["" "(a)" ""] (graph/margins (graph/edit ["" "(a)" ""] "delete" 0)))
  (t/is= ["" "(a)" ""] (graph/margins (graph/edit ["" "(a)" ""] "delete" 2)))
  (t/is= ["" "(b)" ""] (graph/margins (graph/edit ["" "(a)" "(b)" ""] "delete" 1))
         "and deleting a real line keeps them"))

(t/test "the editor's actions are the ones the page can send"
  # A new line does not come through `edit` at all: the compose bar sends the
  # whole list with the line already in it, as `run`.
  (t/is= ["a" "b"] (graph/edit ["a" "b"] "run" -1))
  (t/is= ["b"] (graph/edit ["a" "b"] "delete" 0))
  (t/is= ["a" "b"] (graph/edit ["a" "b"] "delete" 9)
         "an index off the end deletes nothing")
  (t/ok (try (do (graph/edit ["a"] "insert-below" 0) false) ([_] true))
        "inserting is no longer an action"))

(os/rm scratch)
