# The config file on disk.

(import ../visualize/graph)
(import ./harness :as t)

(def- scratch "/tmp/visualize-graph-test.janet")

(defn- roundtrip [text]
  (spit scratch text)
  (graph/read-config scratch))

(t/test "the file always ends in one blank line"
  # THE LAST LINE IS A REAL LINE. The editor shows the file, so the row you
  # type into has to exist on disk -- that is where a new line gets written,
  # and it is why there is no `insert below` any more.
  (t/is= ["(show-lines)" ""] (roundtrip "(show-lines)\n"))
  (t/is= ["(show-lines)" ""] (roundtrip "(show-lines)")
         "a file with no trailing newline still gets the row")
  # Exactly one, so reading and writing does not grow a tail of them.
  (t/is= ["(show-lines)" ""] (roundtrip "(show-lines)\n\n\n\n"))
  (t/is= [""] (roundtrip "") "an empty file is one blank row"))

(t/test "writing keeps what the editor showed"
  (spit scratch "(show-lines)\n(hide src.test)\n")
  (def lines (graph/read-config scratch))
  (graph/write-config scratch lines)
  (t/is= lines (graph/read-config scratch) "a round trip is stable")
  (t/ok (string/has-suffix? "\n\n" (slurp scratch))
        "the blank line is on disk, not just in the panel")
  # A caller that hands over lines without the blank still gets a file with
  # one, so the panel and the file cannot disagree.
  (graph/write-config scratch ["(show-lines)"])
  (t/is= ["(show-lines)" ""] (graph/read-config scratch)))

(os/rm scratch)
