# The funnel: shortest path through a sequence of gates.
#
# Every case here is hand-computed. A router's output is easy to eyeball as
# plausible and hard to check, and the layout ports each looked right and
# measured wrong -- so these assert against paths worked out on paper, not
# against whatever the code happened to print the first time.
#
# GATES, not boxes: each [left right y] constrains the path at that y only,
# and between gates the space is open. The first version modelled slabs,
# and the mismatch silently disabled the router for every diagonal corridor
# -- see the header of funnel.janet.

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

(defn- crossing-at
  "The path's x where it crosses height y."
  [path y]
  (var out nil)
  (for i 0 (- (length path) 1)
    (def [x0 y0] (path i))
    (def [x1 y1] (path (+ i 1)))
    (when (and (nil? out) (<= (min y0 y1) y) (<= y (max y0 y1)))
      (set out (if (near? y0 y1)
                 x0
                 (+ x0 (* (- x1 x0) (/ (- y y0) (- y1 y0))))))))
  out)

(defn- passes-gates?
  "Does the path cross every gate inside its span?"
  [path gates]
  (var ok true)
  (each [l r y] gates
    (def x (crossing-at path y))
    (unless (and x (>= x (- l 0.001)) (<= x (+ r 0.001)))
      (set ok false)))
  ok)

(t/test "wide gates on the line leave it straight"
  # Three gates, all spanning [0,100], endpoints at x=50: nothing binds,
  # so the shortest path is the segment -- no corners at all.
  (def gates [[0 100 50] [0 100 100] [0 100 150]])
  (def p (funnel/path [50 0] [50 200] gates))
  (t/ok (straight? p) "no bends where none are needed")
  (t/is= [50 0] (first p))
  (t/is= [50 200] (last p)))

(t/test "a diagonal through wide gates is still one segment"
  (def gates [[0 100 50] [0 100 100] [0 100 150]])
  (def p (funnel/path [10 0] [90 200] gates))
  (t/ok (straight? p) "a clear diagonal needs no corner"))

(t/test "one narrow gate off the line bends the path at its near end"
  # Hand-computed. The straight line from (10,0) to (10,200) runs at x=10;
  # the gate at y=100 admits only [60,100]. The shortest legal path turns
  # exactly once, at the gate's NEAR end: (60,100).
  (def gates [[60 100 100]])
  (def p (funnel/path [10 0] [10 200] gates))
  (t/is= 3 (length p) "start, one corner, goal")
  (t/ok (near? 60 ((p 1) 0)) "the corner is at x=60")
  (t/ok (near? 100 ((p 1) 1)) "on the gate line"))

(t/test "the mirror image bends at the mirrored corner"
  (def gates [[0 40 100]])
  (def p (funnel/path [90 0] [90 200] gates))
  (t/is= 3 (length p))
  (t/ok (near? 40 ((p 1) 0)) "the corner is at x=40"))

(t/test "two offset narrow gates give one corner each"
  # Hand-computed. From (10,0), through [50,60]@100 and back to (10,300)
  # through [50,60]@200: the path pushes right to 50, holds through both
  # gates, and returns. Corners at (50,100) and (50,200).
  (def gates [[50 60 100] [50 60 200]])
  (def p (funnel/path [10 0] [10 300] gates))
  (t/ok (not (straight? p)) "a blocked path must bend")
  (t/ok (some |(and (near? 50 ($ 0)) (near? 100 ($ 1))) p) "corner at (50,100)")
  (t/ok (some |(and (near? 50 ($ 0)) (near? 200 ($ 1))) p) "corner at (50,200)"))

(t/test "a diagonal corridor of disjoint gates is a straight line"
  # THE CASE THAT KILLED THE BOX MODEL. Gates marching leftward, each
  # x-interval DISJOINT from the last -- as bend slots are when a long
  # edge runs diagonally. The straight line from (300,0) to (30,400)
  # crosses at x = 232.5, 165, 97.5, inside all three gates, so the
  # answer is the segment. The box model computed the portal between the
  # first two gates as [max(210,140), min(260,200)] = empty, called the
  # corridor broken, and refused -- which is exactly what silently
  # disabled the router for every diagonal corridor in the drawing.
  (def gates [[210 260 100] [140 200 200] [60 135 300]])
  (def p (funnel/path [300 0] [30 400] gates))
  (t/ok p "the diagonal corridor is passable")
  (t/ok (straight? p) "and the straight diagonal is the answer")
  (t/ok (passes-gates? p gates)))

(t/test "a zigzag holds the binding wall and ignores the slack one"
  # Gates alternating right and left of the endpoints' column. The two
  # outer gates bind (x must reach 60); the middle gate [0,80] is crossed
  # at x=60 without touching it -- the first draft of this test expected a
  # corner on the middle gate's wall at 80, which is a LONGER path than
  # holding x=60 straight through. The funnel knew better.
  (def gates [[60 140 100] [0 80 200] [60 140 300]])
  (def p (funnel/path [50 0] [50 400] gates))
  (t/ok (passes-gates? p gates) "every gate crossed inside its span")
  (t/ok (some |(and (near? 60 ($ 0)) (near? 100 ($ 1))) p) "corner at (60,100)")
  (t/ok (some |(and (near? 60 ($ 0)) (near? 300 ($ 1))) p) "corner at (60,300)"))

(t/test "an empty gate is refused, not squeezed through"
  # A gate with left > right has no opening; nil sends the caller to its
  # fallback rather than drawing a line through a wall.
  (t/is= nil (funnel/path [10 0] [10 200] [[100 40 100]])))

(t/test "a zero-width gate is a point the path must visit"
  (def gates [[40 40 100]])
  (def p (funnel/path [20 0] [60 200] gates))
  (t/ok p "one exact point is still an opening")
  (t/ok (some |(and (near? 40 ($ 0)) (near? 100 ($ 1))) p)
        "and the path passes through it"))

(t/test "no gates means a straight line"
  (def p (funnel/path [0 0] [10 10] []))
  (t/is= 2 (length p))
  (t/is= [0 0] (first p))
  (t/is= [10 10] (last p)))

(t/test "every path crosses every gate inside its span"
  (each [start goal gates]
    [[[50 0] [50 200] [[0 100 50] [0 100 100] [0 100 150]]]
     [[10 0] [10 200] [[60 100 100]]]
     [[10 0] [10 300] [[50 60 100] [50 60 200]]]
     [[300 0] [30 400] [[210 260 100] [140 200 200] [60 135 300]]]
     [[50 0] [50 400] [[60 140 100] [0 80 200] [60 140 300]]]]
    (def p (funnel/path start goal gates))
    (t/ok (and p (passes-gates? p gates))
          (string "legal crossing for goal " (string/format "%j" goal)))))

(t/test "the channel between gates interpolates their walls"
  (def gates [[0 100 100] [50 150 200]])
  (t/is= [0 100] (funnel/channel gates 100) "on the first gate line")
  (def mid (funnel/channel gates 150))
  (t/ok (near? 25 (mid 0)) "left wall halfway between 0 and 50")
  (t/ok (near? 125 (mid 1)) "right wall halfway between 100 and 150")
  (t/is= nil (funnel/channel gates 50) "above the corridor nothing binds")
  (t/is= nil (funnel/channel gates 250) "below it either"))
