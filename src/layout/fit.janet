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

(defn- chord-lengths
  ``Parameter values for each point, spaced by distance along the polyline.

  Uniform spacing (t = i/n) is the obvious choice and fits badly whenever the
  segments differ in length, because it asks the curve to cover a long
  stretch and a short one in the same amount of parameter. Chord-length
  parameterisation is the standard fix and what dot uses.``
  [points]
  (def d @[0])
  (var total 0)
  (for i 1 (length points)
    (+= total (math/sqrt (dot (sub (points i) (points (- i 1)))
                              (sub (points i) (points (- i 1))))))
    (array/push d total))
  (if (zero? total)
    (map (fn [_] 0) d)
    (map |(/ $ total) d)))

(defn- fit-one
  ``One cubic from `points` first to last, leaving along `t0` and arriving
  along `t1`. Returns [c1 c2], the two control points.

  LEAST SQUARES WITH THE TANGENTS FIXED. The control points are constrained
  to lie along the given tangents -- c1 = p0 + a*t0, c2 = p3 - b*t1 -- so
  the only unknowns are the two distances a and b. That makes this a 2x2
  system rather than a general fit, which is both faster and better
  behaved: the curve cannot flail off sideways to chase a point, it can
  only reach further along a direction that was already chosen.

  This is `points2coeff` and its solve in route.c, which is the standard
  Hoschek/Plass fit.``
  [points t0 t1]
  (def p0 (first points))
  (def p3 (last points))
  (def ts (chord-lengths points))

  # The 2x2 normal equations. Each point contributes the bezier basis
  # weights of the two unknowns and a residual against the fixed ends.
  (var c00 0) (var c01 0) (var c11 0) (var x0 0) (var x1 0)
  (for i 0 (length points)
    (def t (ts i))
    (def u (- 1 t))
    (def b1 (* 3 u u t))
    (def b2 (* 3 u t t))
    (def a1 [(* b1 (t0 0)) (* b1 (t0 1))])
    (def a2 [(* (- b2) (t1 0)) (* (- b2) (t1 1))])
    (+= c00 (dot a1 a1))
    (+= c01 (dot a1 a2))
    (+= c11 (dot a2 a2))
    # What is left after the two fixed endpoints have had their say.
    (def base (+ (* u u u) b1))
    (def base2 (+ (* t t t) b2))
    (def residual (sub (points i)
                       [(+ (* base (p0 0)) (* base2 (p3 0)))
                        (+ (* base (p0 1)) (* base2 (p3 1)))]))
    (+= x0 (dot a1 residual))
    (+= x1 (dot a2 residual)))

  (def det (- (* c00 c11) (* c01 c01)))
  # A degenerate system means the points are effectively collinear with the
  # tangents; the thirds of the chord are the right answer and the one dot
  # falls back to.
  (def [a b]
    (if (< (math/abs det) 0.000001)
      (let [d (math/sqrt (dot (sub p3 p0) (sub p3 p0)))]
        [(/ d 3) (/ d 3)])
      [(/ (- (* x0 c11) (* x1 c01)) det)
       (/ (- (* x1 c00) (* x0 c01)) det)]))

  # Negative or absurd distances turn the curve inside out. Clamped to
  # something sane in the same spirit as route.c's checks.
  #
  # NOT NAMED a' AND b'. Janet reads ' as QUOTE, so `(* a' (t0 0))` parses
  # as `(* a '(t0 0))` -- a number times a literal tuple -- and the error
  # arrives from a line that looks like arithmetic on two numbers. Worse,
  # `(max a 0.01)` compares a tuple against a number without complaining, so
  # a mistake of this shape can also come back as a plausible wrong number
  # rather than an error.
  (def span (math/sqrt (dot (sub p3 p0) (sub p3 p0))))
  (def lead (min (max a 0.01) (* 3 span)))
  (def trail (min (max b 0.01) (* 3 span)))
  [[(+ (p0 0) (* lead (t0 0))) (+ (p0 1) (* lead (t0 1)))]
   [(- (p3 0) (* trail (t1 0))) (- (p3 1) (* trail (t1 1)))]])

(defn- inside?
  ``Does the curve stay within the corridor?

  Sampled rather than solved. dot's `splineisinside` walks the boxes and
  clips analytically; sampling at a fixed rate is a few lines instead and
  the failure mode is benign -- a curve that bulges out between two samples
  is caught by the next subdivision, and the boxes have a gap's worth of
  margin built in by the layout.

  Returns the parameter of the WORST violation, or nil when clean, because
  the caller wants to split exactly there.``
  [p0 c1 c2 p3 boxes]
  (defn box-at [y]
    (var found nil)
    (var best nil)
    (each [l r by] boxes
      (def d (math/abs (- y by)))
      (when (or (nil? best) (< d best))
        (set best d)
        (set found [l r])))
    found)
  (var worst nil)
  (var worst-at nil)
  (for k 0 33
    (def t (/ k 32))
    (def [x y] (bezier-at p0 c1 c2 p3 t))
    (when-let [[l r] (box-at y)]
      (def over (max (- l x) (- x r)))
      (when (and (pos? over) (or (nil? worst) (> over worst)))
        (set worst over)
        (set worst-at t))))
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
      (def [c1 c2] (fit-one path t0 t1))
      (def bad (inside? p0 c1 c2 p3 boxes))
      (cond
        (nil? bad) [[c1 c2 p3]]

        # SUBDIVISION HAS A FLOOR. Past a handful of levels the pieces are
        # shorter than the sampling can resolve and splitting again cannot
        # help; dot gives up the same way. nil here rather than a bad curve.
        (> depth 6) nil

        # SPLIT AT THE WORST POINT and fit each half. The join takes the
        # tangent of the polyline there, which keeps the two pieces
        # continuous in direction -- a visible kink otherwise, and the whole
        # point of fitting was to remove those.
        (let [cut (max 1 (min (- (length path) 2)
                              (math/floor (* bad (- (length path) 1)))))
              left (slice path 0 (+ cut 1))
              right (slice path cut)
              mid (path cut)
              through (norm (sub (path (min (- (length path) 1) (+ cut 1)))
                                 (path (max 0 (- cut 1)))))
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
