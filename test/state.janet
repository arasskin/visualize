# State on disk: the facts a view reads, without an API to agree on first.

(import ../src/state)
(import ./harness :as t)

(def- root (string (string/trimr (or (os/getenv "TMPDIR") "/tmp") "/")
                   "/visualize-state-test-" (os/time)))
(os/mkdir root)

(t/test "a value written is a value read, by anything"
  (state/write root "scan.json" {"nodes" ["a" "b"] "at" 42})
  (def back (state/read root "scan.json"))
  (t/is= 42 (back "at"))
  (t/is= ["a" "b"] (back "nodes"))
  # The point of the exercise: it is a FILE, readable without this module.
  (def raw (slurp (state/path-for root "scan.json")))
  (t/ok (string/find "nodes" raw) "and it is plain text on disk"))

(t/test "a missing file is nil, not an error"
  # A view asking for state that does not exist yet is ordinary -- the scan
  # has not run, no fault has happened -- and must not be a crash.
  (t/is= nil (state/read root "never-written.json")))

(t/test "a half-written file is never seen"
  # Written to a temporary and renamed, so a page polling while a scan
  # lands cannot parse a truncated object and call the graph broken.
  (state/write root "big.json" {"payload" (string/repeat "x" 100000)})
  (t/is= 100000 (length ((state/read root "big.json") "payload")))
  (t/ok (not (os/stat (string (state/path-for root "big.json") ".tmp") :mode))
        "and the temporary is gone afterwards"))

(t/test "a line log keeps the newest and forgets the oldest"
  (each i (range 0 10)
    (state/append-line root "faults.jsonl" {"n" i} 4))
  (def kept (state/read-lines root "faults.jsonl"))
  (t/is= 4 (length kept) "bounded")
  (t/is= 9 ((last kept) "n") "and it is the newest that survives")
  (t/is= 6 ((first kept) "n")))

(t/test "the state directory is made on demand"
  (def fresh (string root "/nested"))
  (os/mkdir fresh)
  (state/write fresh "x.json" {"ok" true})
  (t/ok (os/stat (string fresh "/.visualize") :mode)
        "writing creates the directory rather than failing"))
