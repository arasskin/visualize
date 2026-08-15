# The fault ring: what went wrong lately, where the agent can find it.

(import ../src/faults)
(import ./harness :as t)

(t/test "a fault is recorded with its where and what"
  (faults/clear)
  (faults/record :request "/pane/harness/poll" "timeout" "  in net/read")
  (def [entry] (faults/recent))
  (t/is= "request" (entry "kind"))
  (t/is= "/pane/harness/poll" (entry "where"))
  (t/is= "timeout" (entry "what"))
  (t/ok (string/find "net/read" (entry "trace")) "the trace rides along"))

(t/test "an immediate repeat collapses instead of flooding the ring"
  # A failing poll fails several times a second. Sixty identical entries
  # would push out the one different fault that explains them.
  (faults/clear)
  (repeat 5 (faults/record :request "/pane/harness/poll" "timeout"))
  (t/is= 1 (length (faults/recent)))
  (t/is= 5 ((first (faults/recent)) "count"))
  # A different fault starts its own entry, and does not merge backwards.
  (faults/record :request "/pane/repl/poll" "timeout")
  (t/is= 2 (length (faults/recent)))
  (faults/record :request "/pane/harness/poll" "timeout")
  (t/is= 3 (length (faults/recent))
         "a repeat that is not immediate is its own entry"))

(t/test "the ring forgets the oldest rather than growing"
  (faults/clear)
  (for i 0 100 (faults/record :request (string "/p" i) "boom"))
  (t/ok (<= (length faults/faults) 64) "capped")
  (t/ok (string/find "/p99" ((last (faults/recent)) "where"))
        "and it is the NEWEST that survives"))

(t/test "counting since a moment is what the page puts in its state line"
  (faults/clear)
  (def before (os/time))
  (repeat 3 (faults/record :request "/a" "boom"))
  (faults/record :request "/b" "bang")
  # Repeats count individually: four things went wrong, in two entries.
  (t/is= 4 (faults/count-since before))
  (t/is= 0 (faults/count-since (+ (os/time) 10))
         "nothing is newer than the future"))
