# Fitting beziers to a funnel path, inside the corridor it came from.
#
# The properties here are the ones that decide whether a drawing is right:
# the curve stays in the corridor, it starts and ends where it was told, it
# leaves along the tangent it was given, and it does not use more pieces
# than the shape needs. Each is checkable without knowing how the fit works.

(import ../src/layout/fit)
(import ../src/layout/funnel)
(import ./harness :as t)

(defn- near? [a b &opt eps] (< (math/abs (- a b)) (or eps 0.001)))

(defn- at
  "Sample the fitted run at `n` points, as [x y] pairs."
  [start segments n]
  (def out @[])
  (var from start)
  (each [c1 c2 end] segments
    (for k 0 (+ n 1)
      (def s (/ k n))
      (def u (- 1 s))
      (array/push out
                  [(+ (* u u u (from 0)) (* 3 u u s (c1 0))
                      (* 3 u s s (c2 0)) (* s s s (end 0)))
                   (+ (* u u u (from 1)) (* 3 u u s (c1 1))
                      (* 3 u s s (c2 1)) (* s s s (end 1)))]))
    (set from end))
  out)

(defn- escapes?
  "Does any sample fall outside the box nearest its y?"
  [start segments boxes]
  (defn box-at [y]
    (var found nil)
    (var best nil)
    (each [l r by] boxes
      (def d (math/abs (- y by)))
      (when (or (nil? best) (< d best)) (set best d) (set found [l r])))
    found)
  (var out false)
  (each [x y] (at start segments 24)
    (when-let [[l r] (box-at y)]
      # A hair of tolerance: touching a wall is legal, crossing it is not.
      (when (or (< x (- l 0.5)) (> x (+ r 0.5))) (set out true))))
  out)

(t/test "a straight corridor fits one curve"
  (def boxes [[0 100 0] [0 100 100] [0 100 200]])
  (def segs (fit/route [50 0] [50 200] boxes [0 1] [0 1]))
  (t/ok segs "a fit was found")
  (t/is= 1 (length segs) "nothing to subdivide for")
  (t/ok (not (escapes? [50 0] segs boxes)) "stays inside"))

(t/test "the curve ends exactly where it was told"
  # Endpoints are not negotiable: an edge that stops short of its node, or
  # overshoots into it, is wrong however smooth the curve is.
  (def boxes [[0 60 0] [50 140 100] [50 140 200] [0 60 300]])
  (def segs (fit/route [10 0] [10 300] boxes [0 1] [0 1]))
  (t/ok segs)
  (def [_ _ end] (last segs))
  (t/ok (near? 10 (end 0)) "ends at x=10")
  (t/ok (near? 300 (end 1)) "ends at y=300"))

(t/test "the curve leaves along the tangent it was given"
  # The renderer picks the departure angle so edges fan out of a node
  # without overlapping; a router that chose its own would undo that. The
  # first control point is what sets the departure direction.
  (def boxes [[0 200 0] [0 200 100] [0 200 200]])
  (def segs (fit/route [100 0] [100 200] boxes [1 0] [0 1]))
  (t/ok segs)
  (def [c1 _ _] (first segs))
  (t/ok (> (c1 0) 100.5) "the first control point lies to the right")
  (t/ok (near? 0 (- (c1 1) 0) 1) "and level with the start, as [1 0] asks"))

(t/test "a corridor that jogs subdivides and stays inside"
  # The case the whole router exists for: a straight line does not fit, so
  # the fit must bend, and the bend must respect the walls.
  (def boxes [[0 100 0] [60 100 100] [0 100 200]])
  (def segs (fit/route [10 0] [10 200] boxes [0 1] [0 1]))
  (t/ok segs "a fit was found")
  (t/ok (not (escapes? [10 0] segs boxes))
        "the curve does not cross the wall at x=60"))

(t/test "an uneven staircase stays inside its narrow gates"
  (def boxes [[0 60 0] [50 140 100] [50 140 200] [0 60 300]])
  (def segs (fit/route [10 0] [10 300] boxes [0 1] [0 1]))
  (t/ok segs)
  (t/ok (not (escapes? [10 0] segs boxes)) "through both x in [50,60] gates"))

(t/test "a zigzag stays inside on both swings"
  (def boxes [[0 100 0] [60 140 100] [0 80 200] [60 140 300] [0 100 400]])
  (def segs (fit/route [50 0] [50 400] boxes [0 1] [0 1]))
  (t/ok segs)
  (t/ok (not (escapes? [50 0] segs boxes)) "neither swing leaves the corridor"))

(t/test "segments join without a kink"
  # Subdivision is only worth doing if the pieces read as one line. Where
  # two segments meet, the incoming and outgoing directions must agree --
  # that is the difference between a curve and a folded wire.
  (def boxes [[0 100 0] [60 140 100] [0 80 200] [60 140 300] [0 100 400]])
  (def segs (fit/route [50 0] [50 400] boxes [0 1] [0 1]))
  (t/ok segs)
  (when (> (length segs) 1)
    (for i 0 (- (length segs) 1)
      (def [_ c2 end] (segs i))
      # `next-c1`, not `c1'` -- Janet's ' is quote, and a primed name parses
      # as two forms rather than one symbol.
      (def [next-c1 _ _] (segs (+ i 1)))
      # Direction arriving at the join, and direction leaving it.
      (defn unit [a b]
        (def d [(- (b 0) (a 0)) (- (b 1) (a 1))])
        (def m (math/sqrt (+ (* (d 0) (d 0)) (* (d 1) (d 1)))))
        (if (< m 0.0001) [0 0] [(/ (d 0) m) (/ (d 1) m)]))
      (def incoming (unit c2 end))
      (def outgoing (unit end next-c1))
      (def agreement (+ (* (incoming 0) (outgoing 0))
                        (* (incoming 1) (outgoing 1))))
      (t/ok (> agreement 0.7)
            (string "join " i " continues in the same direction")))))

(t/test "a broken corridor is refused, not fitted"
  # The funnel returns nil for boxes that do not overlap, and the router
  # must pass that along rather than fit something to nothing. The caller
  # falls back to its existing line, which is the whole contract.
  (def broken [[0 40 0] [0 40 100] [100 140 200] [100 140 300]])
  (t/is= nil (fit/route [20 0] [120 300] broken [0 1] [0 1])))

(t/test "no corridor still yields a drawable curve"
  # Edges with no bends have no boxes, and asking for a curve should give
  # back the straight line as a cubic rather than nil -- one shape for the
  # renderer to handle instead of two.
  (def segs (fit/route [0 0] [100 100] [] [0 1] [0 1]))
  (t/ok segs)
  (t/is= 1 (length segs))
  (def [_ _ end] (first segs))
  (t/ok (near? 100 (end 0)))
  (t/ok (near? 100 (end 1))))

(t/test "a single box is a corridor with nothing to cross"
  # Not a refusal case, though it looks like one. One box has no gates --
  # gates are the boundaries BETWEEN boxes -- so there is nothing that could
  # block the line and the honest answer is the direct curve. Refusing here
  # would send the caller to its fallback for an edge that had no problem.
  (def segs (fit/route [0 0] [10 10] [[0 10 0]] [0 1] [0 1]))
  (t/ok segs "a lone box does not defeat the router")
  (def [_ _ end] (last segs))
  (t/ok (near? 10 (end 0)) "and still lands on the goal")
  (t/ok (near? 10 (end 1))))
