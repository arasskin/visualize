# Network simplex ranking, and its balance tail.
#
# The ranker itself is exercised through `layered/rank` by the layout
# tests; these are the cases that pin simplex's own contract -- the
# hand-computed optimum it was debugged with, and the balance pass's
# measured inertness, which is a finding worth a guard rather than a
# behaviour worth trusting.

(import ../src/layout/simplex)
(import ./harness :as t)

(defn- span
  "Total edge length of a ranking: what simplex minimises."
  [edges rank-of]
  (var total 0)
  (each [from to] edges
    (when (and (rank-of from) (rank-of to))
      (+= total (math/abs (- (rank-of to) (rank-of from))))))
  total)

(t/test "the hand-computed optimum, which is what fixed the cut values"
  # a -> b -> c -> d, a -> d, e -> d. Longest path leaves e at rank 0 with
  # its edge spanning 3, total 9; the optimum drops e to rank 2 for a total
  # of 7. The smallest case where a wrong cut-value sign shows up.
  (def names ["a" "b" "c" "d" "e"])
  (def edges [["a" "b"] ["b" "c"] ["c" "d"] ["a" "d"] ["e" "d"]])
  (def initial @{"a" 0 "b" 1 "c" 2 "d" 3 "e" 0})
  (def out (simplex/rank names edges initial))
  (t/is= 7 (span edges out) "the optimum, not the longest path's 9")
  (t/is= 2 (out "e") "e dropped to sit just above its only child"))

(t/test "a chain keeps its shape"
  (def names ["a" "b" "c"])
  (def edges [["a" "b"] ["b" "c"]])
  (def out (simplex/rank names edges @{"a" 0 "b" 1 "c" 2}))
  (t/is= 0 (out "a"))
  (t/is= 1 (out "b"))
  (t/is= 2 (out "c")))

(t/test "components are ranked independently and normalised to the top"
  # Two disjoint chains: neither should be pushed down by the other, and
  # both should start at rank 0.
  (def names ["a" "b" "x" "y"])
  (def edges [["a" "b"] ["x" "y"]])
  (def out (simplex/rank names edges @{"a" 0 "b" 1 "x" 0 "y" 1}))
  (t/is= 0 (out "a"))
  (t/is= 0 (out "x"))
  (t/is= 1 (out "b"))
  (t/is= 1 (out "y")))

(t/test "balance leaves a free node alone when moving it conserves crowding"
  # THE MEASURED FINDING, pinned so a future edit cannot quietly undo it.
  #
  # `hub` is free (one parent, one child), its window spans ranks 1..3, and
  # rank 1 carries a crowd of seven. dot's node-counted balance moves it
  # gratefully -- and doing that here doubled drawn crossings, because
  # moving a node off a rank ADDS A BEND to that rank: its own edge now
  # spans it. Squared load is 149 at every position in the window, exactly
  # flat, so the honest answer is to stay.
  #
  # This test fails if balance is ever changed back to counting nodes
  # without counting the bends their edges lay.
  (def names ["top" "hub" "bot" "c1" "c2" "c3" "c4" "c5" "s1" "s2" "s3"])
  (def edges [["top" "hub"] ["hub" "bot"]
              ["top" "c1"] ["top" "c2"] ["top" "c3"] ["top" "c4"] ["top" "c5"]
              ["c1" "bot"] ["c2" "bot"] ["c3" "bot"] ["c4" "bot"] ["c5" "bot"]
              ["top" "s1"] ["s1" "s2"] ["s2" "s3"] ["s3" "bot"]])
  (def initial @{"top" 0 "hub" 1 "bot" 4 "c1" 1 "c2" 1 "c3" 1 "c4" 1 "c5" 1
                 "s1" 1 "s2" 2 "s3" 3})
  (def out (simplex/rank names edges initial))
  (t/is= 1 (out "hub")
         "a move that trades a node for a bend on the same rank is not a move")
  (t/is= 4 (out "bot") "and the chain that fixes the window is undisturbed"))

(t/test "balance never breaks a node out of its edges' window"
  # Whatever balance decides, the ranking it hands back must still be
  # feasible: every edge pointing down by at least its minimum length.
  (def names ["a" "b" "c" "d" "e" "f"])
  (def edges [["a" "b"] ["b" "c"] ["c" "d"] ["a" "e"] ["e" "d"] ["b" "f"]
              ["f" "d"]])
  (def out (simplex/rank names edges @{"a" 0 "b" 1 "c" 2 "d" 3 "e" 1 "f" 2}))
  (var inverted 0)
  (each [from to] edges
    (unless (>= (- (out to) (out from)) 1) (++ inverted)))
  (t/is= 0 inverted "every edge still points down by at least one rank"))
