# The funnel: shortest path through a stack of boxes.
#
# Every case here is hand-computed. A router's output is easy to eyeball as
# plausible and hard to check, and the last five layout ports each looked
# right and measured wrong -- so these assert against paths worked out on
# paper, not against whatever the code happened to print the first time.

(import ../src/layout/funnel)
(import ./harness :as t)

(defn- near? [a b] (< (math/abs (- a b)) 0.001))

(defn- straight?
  "Is every point on the path collinear with the first and last?"
  [points]
  (def [x0 y0] (first points))
  (def [x1 y1] (last points))
  (every? (seq [[x y] :in points]
            (near? 0 (- (* (- x1 x0) (- y y0))
                        (* (- y1 y0) (- x x0)))))))

(t/test "a straight shot through aligned boxes stays straight"
  # Three boxes, all spanning the same x. Nothing is in the way, so the
  # shortest path is the segment -- no corners at all.
  (def boxes [[0 100 0] [0 100 100] [0 100 200]])
  (def p (funnel/path [50 0] [50 200] boxes))
  (t/ok (straight? p) "no bends where none are needed")
  (t/is= [50 0] (first p))
  (t/is= [50 200] (last p)))

(t/test "a diagonal through wide boxes is still one segment"
  # The endpoints differ in x, but every gate is wide enough to admit the
  # straight line between them, so the funnel never closes.
  (def boxes [[0 100 0] [0 100 100] [0 100 200]])
  (def p (funnel/path [10 0] [90 200] boxes))
  (t/ok (straight? p) "a clear diagonal needs no corner"))

(t/test "a jog bends at the corner that blocks it"
  # Hand-computed. The middle box is pushed right, so its LEFT wall at x=60
  # is a corner the path must round:
  #
  #     rank 0   [ 0 .. 100]        start (10, 0)
  #     rank 1   [60 .. 100]        <- left wall at 60 blocks the straight line
  #     rank 2   [ 0 .. 100]        goal  (10, 200)
  #
  # The straight line from (10,0) to (10,200) runs at x=10, outside rank 1
  # entirely. The shortest legal path touches (60, 50) -- the near corner of
  # the gate into the narrow box -- and returns.
  (def boxes [[0 100 0] [60 100 100] [0 100 200]])
  (def p (funnel/path [10 0] [10 200] boxes))
  (t/ok (not (straight? p)) "an obstructed path must bend")
  (t/ok (some |(near? 60 ($ 0)) p) "it rounds the wall at x=60"))

(t/test "an evenly-stepped staircase needs no corners at all"
  # Worth its own case because it caught a bad test rather than bad code.
  # Four boxes marching right by 30 a rank: the straight line from start to
  # goal passes through every gate with room to spare, so the honest answer
  # is the segment. A router that bent here would be adding kinks a reader
  # would have to follow for nothing.
  (def boxes [[0 40 0] [30 70 100] [60 100 200] [90 130 300]])
  (def p (funnel/path [20 0] [110 300] boxes))
  (t/is= 2 (length p) "a clear line is start and goal, nothing between")
  (t/ok (straight? p)))

(t/test "an uneven staircase bends at the steps that block it"
  # Hand-computed. The boxes overlap -- they must, or there is no corridor --
  # but by uneven amounts, so the gates are not aligned:
  #
  #     rank 0  [ 0 ..  60]   start (10, 0)
  #     rank 1  [50 .. 140]   gate y= 50  x in [ 50 ..  60]  <- narrow, right
  #     rank 2  [50 .. 140]   gate y=150  x in [ 50 .. 140]
  #     rank 3  [ 0 ..  60]   gate y=250  x in [ 50 ..  60]  <- narrow again
  #                           goal  (10, 300)
  #
  # The straight line from (10,0) to (10,300) runs at x=10, outside both
  # narrow gates. The path must push right to x=50 to get through the first,
  # hold, and come back -- two corners, both on the wall at x=50.
  (def boxes [[0 60 0] [50 140 100] [50 140 200] [0 60 300]])
  (def p (funnel/path [10 0] [10 300] boxes))
  (t/ok (not (straight? p)) "a blocked path must bend")
  (t/ok (some |(and (near? 50 ($ 0)) (near? 50 ($ 1))) p)
        "it turns at the corner (50, 50)")
  (t/ok (some |(and (near? 50 ($ 0)) (near? 250 ($ 1))) p)
        "and back at (50, 250)")
  # Every corner must be a real box wall, not an interior point invented
  # along the way. Endpoints excepted -- those are given.
  (def walls @{})
  (each [l r _] boxes (put walls l true) (put walls r true))
  (each [x _] (slice p 1 -2)
    (t/ok (some |(near? x $) (keys walls))
          (string "corner at x=" x " is a box wall"))))

(t/test "the path never leaves the corridor"
  # The property that actually matters for the drawing, checked at the
  # GATES rather than by sampling with a tolerance -- a path stays inside a
  # stack of boxes exactly when it is inside every gate it crosses, and the
  # gates are where a wrong path escapes.
  (defn crosses-legally? [start goal boxes]
    (def p (funnel/path start goal boxes))
    (def gates (funnel/portals boxes))
    # A refused corridor is not a containment failure; it has its own test.
    (if (or (nil? p) (nil? gates)) (break false))
    (var ok true)
    (each [[l gy] [r _]] gates
      # Where is the path at this gate's y?
      (var at nil)
      (for i 0 (- (length p) 1)
        (def [x0 y0] (p i))
        (def [x1 y1] (p (+ i 1)))
        (when (and (nil? at) (<= (min y0 y1) gy) (<= gy (max y0 y1)))
          (set at (if (near? y0 y1)
                    x0
                    (+ x0 (* (- x1 x0) (/ (- gy y0) (- y1 y0))))))))
      (unless (and at (>= at (- l 0.001)) (<= at (+ r 0.001)))
        (set ok false)))
    ok)
  (t/ok (crosses-legally? [20 0] [110 300]
                          [[0 40 0] [30 70 100] [60 100 200] [90 130 300]])
        "the even staircase")
  (t/ok (crosses-legally? [10 0] [10 300]
                          [[0 60 0] [50 140 100] [50 140 200] [0 60 300]])
        "the uneven staircase")
  (t/ok (crosses-legally? [10 0] [10 200]
                          [[0 100 0] [60 100 100] [0 100 200]])
        "the jog")
  (t/ok (crosses-legally? [90 0] [90 200]
                          [[0 100 0] [0 40 100] [0 100 200]])
        "the jog, mirrored")
  # A zigzag, which forces corners on ALTERNATING sides and is where a
  # swapped left/right chain shows up. Consecutive boxes must still overlap
  # or it is not a corridor at all -- the first draft of this case pushed
  # the swing too far, the boxes came apart, and it was testing the broken
  # corridor above by accident.
  (t/ok (crosses-legally? [50 0] [50 400]
                          [[0 100 0] [60 140 100] [0 80 200]
                           [60 140 300] [0 100 400]])
        "a zigzag alternating sides"))

(t/test "a broken corridor is refused, not routed through"
  # THE BUG THIS EXISTS FOR. Boxes [0,40] and [100,140] share no x, so there
  # is no opening between them. The first version computed the gate as
  # min(r0,r1)..max(l0,l1) = 40..100 -- the gap itself, the one region the
  # path may NOT enter -- handed it to the funnel as the only way through,
  # and got back a confident straight line through the wall. It looked
  # entirely reasonable, which is why this is asserted rather than trusted.
  (def broken [[0 40 0] [0 40 100] [100 140 200] [100 140 300]])
  (t/is= nil (funnel/portals broken) "no gate between disjoint boxes")
  (t/is= nil (funnel/path [20 0] [120 300] broken)
         "and no path, so the caller can fall back"))

(t/test "boxes touching at exactly one x still connect"
  # The boundary of the case above: [0,40] and [40,80] share the single
  # point x=40. That is a corridor -- a very thin one -- and refusing it
  # would be as wrong as inventing one.
  (def boxes [[0 40 0] [40 80 100]])
  (t/ok (funnel/portals boxes) "a zero-width gate is still a gate")
  (def p (funnel/path [20 0] [60 100] boxes))
  (t/ok p "and a path exists through it")
  (t/ok (some |(near? 40 ($ 0)) p) "which necessarily passes x=40"))

(t/test "no boxes means a straight line"
  (def p (funnel/path [0 0] [10 10] []))
  (t/is= 2 (length p))
  (t/is= [0 0] (first p))
  (t/is= [10 10] (last p)))

(t/test "the path is no longer than the polyline through box centres"
  # The sanity check on "shortest": whatever it returns must beat the
  # obvious naive route, which is what the current router effectively draws.
  (def boxes [[0 40 0] [30 70 100] [60 100 200] [90 130 300]])
  (defn length-of [points]
    (var total 0)
    (for i 0 (- (length points) 1)
      (def [x0 y0] (points i))
      (def [x1 y1] (points (+ i 1)))
      (+= total (math/sqrt (+ (* (- x1 x0) (- x1 x0)) (* (- y1 y0) (- y1 y0))))))
    total)
  (def naive (array [20 0]))
  (each [l r y] boxes (array/push naive [(/ (+ l r) 2) y]))
  (array/push naive [110 300])
  (def found (funnel/path [20 0] [110 300] boxes))
  (t/ok (<= (length-of found) (+ 0.001 (length-of naive)))
        "the funnel is at least as short as routing through centres"))
