# Fitting beziers to a funnel path, inside the gate channel it came from.
#
# The properties here are the ones that decide whether a drawing is right:
# the curve crosses every gate inside its span, stays inside the channel
# between them, starts and ends where it was told, leaves along the tangent
# it was given, and does not use more pieces than the shape needs. Each is
# checkable without knowing how the fit works.

(import ../src/layout/fit)
(import ../src/layout/funnel)
(import ./harness :as t)

(defn- near? [a b &opt eps] (< (math/abs (- a b)) (or eps 0.001)))

(defn- at
  "Sample the fitted run at `n` points per segment, as [x y] pairs."
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
  "Does any sample fall outside the channel between the gates?"
  [start segments gates]
  (var out false)
  (each [x y] (at start segments 24)
    (when-let [[l r] (funnel/channel gates y)]
      # A hair of tolerance: touching a wall is legal, crossing it is not.
      (when (or (< x (- l 0.5)) (> x (+ r 0.5))) (set out true))))
  out)

(t/test "a clear channel fits one curve"
  (def gates [[0 100 50] [0 100 100] [0 100 150]])
  (def segs (fit/route [50 0] [50 200] gates [0 1] [0 1]))
  (t/ok segs "a fit was found")
  (t/is= 1 (length segs) "nothing to subdivide for")
  (t/ok (not (escapes? [50 0] segs gates)) "stays inside"))

(t/test "the curve ends exactly where it was told"
  # Endpoints are not negotiable: an edge that stops short of its node, or
  # overshoots into it, is wrong however smooth the curve is.
  (def gates [[50 60 100] [50 60 200]])
  (def segs (fit/route [10 0] [10 300] gates [0 1] [0 1]))
  (t/ok segs)
  (def [_ _ end] (last segs))
  (t/ok (near? 10 (end 0)) "ends at x=10")
  (t/ok (near? 300 (end 1)) "ends at y=300"))

(t/test "the curve leaves along the tangent it was given"
  # The renderer picks the departure angle so edges fan out of a node
  # without overlapping; a router that chose its own would undo that. The
  # first control point is what sets the departure direction.
  (def gates [[0 200 100]])
  (def segs (fit/route [100 0] [100 200] gates [1 0] [0 1]))
  (t/ok segs)
  (def [c1 _ _] (first segs))
  (t/ok (> (c1 0) 100.5) "the first control point lies to the right")
  (t/ok (near? 0 (- (c1 1) 0) 1) "and level with the start, as [1 0] asks"))

(t/test "a narrow off-line gate bends the fit and the curve honours it"
  # The case the whole router exists for: the straight line misses the
  # gate, so the fit must bend, and the bend must cross the gate inside
  # its span.
  (def gates [[60 100 100]])
  (def segs (fit/route [10 0] [10 200] gates [0 1] [0 1]))
  (t/ok segs "a fit was found")
  (t/ok (not (escapes? [10 0] segs gates)) "the curve crosses inside [60,100]"))

(t/test "two offset narrow gates stay honoured through both"
  (def gates [[50 60 100] [50 60 200]])
  (def segs (fit/route [10 0] [10 300] gates [0 1] [0 1]))
  (t/ok segs)
  (t/ok (not (escapes? [10 0] segs gates)) "through both x in [50,60] gates"))

(t/test "a diagonal corridor of disjoint gates fits one near-straight curve"
  # The corridor shape that the box model refused outright: gate intervals
  # marching leftward with no overlap, the way bend slots sit under a long
  # diagonal edge. The straight line passes every gate, so the fit should
  # need one segment and no drama.
  (def gates [[210 260 100] [140 200 200] [60 135 300]])
  (def segs (fit/route [300 0] [30 400] gates [(- 30 300) 400] [(- 30 300) 400]))
  (t/ok segs "the diagonal corridor is routable")
  (t/ok (not (escapes? [300 0] segs gates)) "and the curve holds the channel"))

(t/test "a zigzag stays inside on both swings"
  (def gates [[60 140 100] [0 80 200] [60 140 300]])
  (def segs (fit/route [50 0] [50 400] gates [0 1] [0 1]))
  (t/ok segs)
  (t/ok (not (escapes? [50 0] segs gates)) "neither swing leaves the channel"))

(t/test "segments join without a kink"
  # Subdivision is only worth doing if the pieces read as one line. Where
  # two segments meet, the incoming and outgoing directions must agree --
  # that is the difference between a curve and a folded wire.
  (def gates [[60 140 100] [0 80 200] [60 140 300]])
  (def segs (fit/route [50 0] [50 400] gates [0 1] [0 1]))
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

(t/test "an empty gate is refused, not fitted"
  # A gate with left > right has no opening; the funnel returns nil and
  # the router must pass that along rather than fit something to nothing.
  # The caller falls back to its existing line, which is the whole contract.
  (t/is= nil (fit/route [10 0] [10 200] [[100 40 100]] [0 1] [0 1])))

(t/test "no gates still yields a drawable curve"
  # Edges with no bends have no gates, and asking for a curve should give
  # back the straight line as a cubic rather than nil -- one shape for the
  # renderer to handle instead of two.
  (def segs (fit/route [0 0] [100 100] [] [0 1] [0 1]))
  (t/ok segs)
  (t/is= 1 (length segs))
  (def [_ _ end] (first segs))
  (t/ok (near? 100 (end 0)))
  (t/ok (near? 100 (end 1))))

(t/test "a single gate on the line is no obstacle"
  (def segs (fit/route [0 0] [10 200] [[0 10 100]] [0 1] [0 1]))
  (t/ok segs "a lone gate the line passes does not defeat the router")
  (def [_ _ end] (last segs))
  (t/ok (near? 10 (end 0)) "and still lands on the goal")
  (t/ok (near? 200 (end 1))))
