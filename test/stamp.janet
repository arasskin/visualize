# The stamp: which code is this process actually running?

(import ../visualize/stamp)
(import ./harness :as t)

(t/test "the stamp is stable and shaped like a timestamp"
  (t/is= stamp/born (stamp/compute)
         "unchanged sources answer with the process's birth stamp")
  (t/ok (peg/match ~(* (repeat 8 :d) "-" (repeat 6 :d) -1) stamp/born)
        "YYYYMMDD-HHMMSS, comparable at a glance"))
