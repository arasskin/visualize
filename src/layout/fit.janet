# Fitting a bezier to a path, inside the boxes the path came from.
#
# WHAT THIS IS FOR. `funnel.janet` returns the shortest path through a
# corridor, and it is a POLYLINE -- correct, minimal, and drawn as-is it
# looks like a folded wire. This turns it into curves that stay inside the
# same boxes. Together the two are the port scoped in docs/pathplan-scope.md:
# graphviz reaches the same place with Pshortestpath and Proutespline.
#
# THE ALGORITHM, from graphviz's route.c. Try to fit ONE cubic bezier to the
# whole path. Check whether that curve stays inside the corridor. If it does,
# done -- one smooth curve, which is the best possible answer. If it does
# not, split the path at its worst point and fit each half, recursively. A
# path needing many pieces gets many; a path needing one gets one.
#
# WHY NOT JUST CURVE THE POLYLINE, which is what the renderer does today with
# a Catmull-Rom through the bend points: a spline through fixed points has to
# go through them, and the bends are only the DEFAULT position -- the box is
# the permission. Fitting looks at the whole corridor and puts the curve
# where it reads best, which is the entire reason the corridors are computed.
#
# TANGENTS ARE GIVEN, NOT DERIVED. An edge leaves its source and enters its
# target at an angle the renderer has already chosen (see `on-ellipse` and
# the fan logic in svg.janet), and a router that picked its own would undo
# that. dot does the same -- Proutespline takes the end slopes as arguments.

(import ./funnel)

(defn- sub [a b] [(- (a 0) (b 0)) (- (a 1) (b 1))])
(defn- dot [a b] (+ (* (a 0) (b 0)) (* (a 1) (b 1))))
(defn- norm [v]
  (def m (math/sqrt (dot v v)))
  (if (< m 0.0001) [0 0] [(/ (v 0) m) (/ (v 1) m)]))

(defn- bezier-at
  "The point at parameter t on the cubic through p0 c1 c2 p3."
  [p0 c1 c2 p3 t]
  (def u (- 1 t))
  (def a (* u u u))
  (def b (* 3 u u t))
  (def c (* 3 u t t))
  (def d (* t t t))
  [(+ (* a (p0 0)) (* b (c1 0)) (* c (c2 0)) (* d (p3 0)))
   (+ (* a (p0 1)) (* b (c1 1)) (* c (c2 1)) (* d (p3 1)))])

(defn- fit-one
  ``One cubic from `p0` to `p3`, leaving along `t0`, arriving along `t1`,
  with both control distances a THIRD OF THE CHORD scaled by `k`.
  Returns [c1 c2].

  PROPORTIONAL, NOT SOLVED FOR -- and this is what route.c actually does.
  An earlier version ran a least-squares fit for the two distances (the
  Hoschek/Plass scheme, misread into dot's code), and with the tangents
  fixed and the distances free, the solver stretched controls until the
  cubic's direction reversed mid-curve: `config -> graph` shipped with
  its controls at y=328 then y=133 and drew a visible knot, and the
  containment never objected because the fold was in DIRECTION, not in
  the channel. dot's `splinefits` never solves: both controls sit at the
  same proportional distance along their tangents, tried at a few scales
  by the caller, and a curve of that shape has nowhere to fold -- the
  hodograph cannot reverse when both controls pull the same way. Fitting
  tightness costs subdivision instead of wiggles, which is the right
  currency: two smooth arcs read better than one clever knot.

  NOT NAMED a' AND b'. Janet reads ' as QUOTE, so `(* a' (t0 0))` parses
  as `(* a '(t0 0))` -- a number times a literal tuple -- and the error
  arrives from a line that looks like arithmetic on two numbers.``
  [p0 p3 t0 t1 k]
  (def span (math/sqrt (dot (sub p3 p0) (sub p3 p0))))
  (def reach (* k (/ span 3)))
  [[(+ (p0 0) (* reach (t0 0))) (+ (p0 1) (* reach (t0 1)))]
   [(- (p3 0) (* reach (t1 0))) (- (p3 1) (* reach (t1 1)))]])

(defn- inside?
  ``Does the curve stay within the corridor's channel?

  The corridor is a sequence of GATES, and between two gate lines the
  bound is the linear interpolation of their intervals -- `funnel/channel`.
  The funnel's polyline always fits that channel by linearity, so
  subdividing toward the polyline always converges.

  Sampled rather than solved. dot's `splineisinside` walks its boxes and
  clips analytically; sampling at a fixed rate is a few lines instead and
  the failure mode is benign -- a curve that bulges out between two samples
  is caught by the next subdivision, and the gates have a gap's worth of
  margin built in by the layout.

  A curve that DOUBLES BACK IN Y is a violation wherever it turns, however
  legal its x. Every path here descends -- gates strictly increase in y --
  and a cubic whose y reverses has folded into a knot. The channel alone
  cannot catch it: above the first gate and below the last nothing bounds
  x, and that is exactly where a folding curve swings, so `config ->
  graph` shipped one segment whose controls sat at y=328 then y=36 and
  drew a loop the containment never sampled illegal. Monotone y is part
  of what "inside the corridor" means for a corridor that only ever goes
  down. Subdividing on it converges, because the funnel polyline is
  monotone by construction.

  Returns the parameter of the WORST violation, or nil when clean, because
  the caller wants to split exactly there.``
  [p0 c1 c2 p3 gates]
  (var worst nil)
  (var worst-at nil)
  (var prev-y nil)
  (for k 0 33
    (def t (/ k 32))
    (def [x y] (bezier-at p0 c1 c2 p3 t))
    (when-let [[l r] (funnel/channel gates y)]
      (def over (max (- l x) (- x r)))
      (when (and (pos? over) (or (nil? worst) (> over worst)))
        (set worst over)
        (set worst-at t)))
    (when prev-y
      (def back (- prev-y y))
      # A hair of tolerance: flat is fine, climbing is a fold.
      (when (and (> back 0.5) (or (nil? worst) (> back worst)))
        (set worst back)
        (set worst-at t)))
    (set prev-y y))
  worst-at)

(defn curve
  ``Fit `path` with cubics that stay inside `boxes`.

  `path` is the polyline from `funnel/path`; `boxes` is the corridor it came
  from; `t0` and `t1` are unit tangents at the two ends. Returns a list of
  [c1 c2 end] segments, each continuing from the previous point -- the shape
  an SVG `C` run wants.

  Returns nil if no fit stays inside, which is the caller's signal to fall
  back to whatever it drew before. A router that cannot do better should
  say so rather than emit something worse.``
  [path boxes t0 t1 &opt depth]
  (default depth 0)
  (cond
    (< (length path) 2) nil

    # TWO POINTS AND NO CORRIDOR TO VIOLATE: a straight line, expressed as a
    # cubic with its controls on the chord so the caller has one shape to
    # handle rather than two.
    (empty? boxes)
    (let [p0 (first path)
          p3 (last path)]
      [[[(+ (p0 0) (/ (- (p3 0) (p0 0)) 3)) (+ (p0 1) (/ (- (p3 1) (p0 1)) 3))]
        [(- (p3 0) (/ (- (p3 0) (p0 0)) 3)) (- (p3 1) (/ (- (p3 1) (p0 1)) 3))]
        p3]])

    (do
      (def p0 (first path))
      (def p3 (last path))
      # A FEW SCALES, ROUNDEST-REASONABLE FIRST, THEN FLAT. Scales above
      # one swing wider to honour the tangents; scales below one hug the
      # chord, and as k approaches zero the cubic approaches the straight
      # segment REGARDLESS of what the tangents ask -- which is the escape
      # valve, because the chord of any piece of the funnel polyline
      # provably fits the channel. splinefits has the same ladder and the
      # same reason. Without the small scales, a piece whose tangents
      # fight a tight channel could only subdivide, and a two-point piece
      # cannot: it was slicing itself into itself plus a lone point,
      # returning nil, and cascading whole edges to the fallback -- which
      # is how three routed edges silently became splines and one cut a
      # group box, again.
      (var fitted nil)
      (var bad nil)
      (each k [1 1.5 2.1 0.5 0.2]
        (unless fitted
          (def [c1 c2] (fit-one p0 p3 t0 t1 k))
          (def worst (inside? p0 c1 c2 p3 boxes))
          (if (nil? worst)
            (set fitted [[c1 c2 p3]])
            (when (nil? bad) (set bad worst)))))
      (cond
        fitted fitted

        # SUBDIVISION HAS A FLOOR, twice over: past a handful of levels
        # the pieces are shorter than the sampling can resolve, and a
        # two-point piece has no interior point to cut at. What remains
        # then is the POLYLINE ITSELF, emitted as chord cubics -- always
        # legal, since every funnel segment fits the channel by linearity.
        # Returning nil here instead threw the WHOLE route away: the
        # narrowest gates in a bundle are a few units wide, the funnel's
        # corner sits at the gate's edge, no tangent-respecting cubic can
        # cross without a bulge, and three routed edges quietly became
        # obstacle-blind splines -- one through a group box, again. A
        # slight kink at exactly the pinch is the honest price; the reader
        # gets a curve that goes where the corridor says everywhere else.
        (or (> depth 6) (< (length path) 3))
        (seq [i :range [0 (- (length path) 1)]]
          (def [ax ay] (path i))
          (def [bx by] (path (+ i 1)))
          [[(+ ax (/ (- bx ax) 3)) (+ ay (/ (- by ay) 3))]
           [(- bx (/ (- bx ax) 3)) (- by (/ (- by ay) 3))]
           [bx by]])

        # SPLIT AT THE WORST POINT and fit each half. The join takes the
        # tangent of the polyline there, which keeps the two pieces
        # continuous in direction -- a visible kink otherwise, and the whole
        # point of fitting was to remove those.
        (let [cut (max 1 (min (- (length path) 2)
                              (math/floor (* bad (- (length path) 1)))))
              left (slice path 0 (+ cut 1))
              right (slice path cut)
              mid (path cut)
              across (norm (sub (path (min (- (length path) 1) (+ cut 1)))
                                (path (max 0 (- cut 1)))))
              # A zero tangent -- the neighbours coincide -- would pin a
              # control point onto its endpoint and draw a corner; the
              # chord's direction is the honest substitute.
              through (if (deep= across [0 0]) (norm (sub p3 p0)) across)
              # Boxes are split at the same y the path was.
              above (filter (fn [[_ _ y]] (<= y (mid 1))) boxes)
              below (filter (fn [[_ _ y]] (>= y (mid 1))) boxes)
              a (curve left above t0 through (+ depth 1))
              b (curve right below through t1 (+ depth 1))]
          (when (and a b) [;a ;b]))))))

(defn route
  ``The whole router: corridor and endpoints in, bezier segments out.

  This is the entry point a renderer wants. It runs the funnel to find the
  path and fits curves to it, and returns nil at the first sign it cannot
  do the job -- a broken corridor, a fit that will not stay inside -- so the
  caller falls back to its existing line rather than drawing something
  worse.``
  [start goal boxes t0 t1]
  (when-let [path (funnel/path start goal boxes)]
    (curve path boxes (norm t0) (norm t1))))
