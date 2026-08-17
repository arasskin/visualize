# The shortest path through a sequence of gates.
#
# WHAT THIS IS FOR. A long edge crosses several ranks, and on each one the
# layout reserves it a slot with free space either side -- see the corridor
# note in layered.janet. The corridor is the permission; this decides where
# in it the line actually runs. Given the gates and the two endpoints, it
# returns the shortest path that passes through every gate, which for a
# drawing means the straightest one a reader can follow.
#
# GATES, NOT BOXES, AND THE DIFFERENCE ONCE COST THE WHOLE ROUTER. The
# first version modelled the corridor the way dot does: a stack of solid
# boxes, each filling the space down to the next, with the passable opening
# computed as the x-overlap of consecutive boxes. But this layout's
# corridors are not slabs -- each [left right y] describes the free span AT
# ONE RANK LINE, and the band between rank lines is open space. The two
# models agree exactly as long as consecutive slots overlap, which they did
# while a placement bug held every bundle in a vertical column; when that
# was fixed and bends settled onto their diagonals, consecutive slots
# stopped overlapping, the box model read every diagonal corridor as a
# wall, and the router silently refused -- every long edge fell back to a
# spline that checks nothing, and one promptly cut through a group box.
# The model has to match the data: a slot is a gate, and the path is
# constrained at gate lines only.
#
# THE FUNNEL ALGORITHM, on gates directly -- which is its native habitat:
# the literature's triangulation machinery exists to DERIVE portals from
# polygon soup, and ours arrive precomputed. Walk the gates from the start
# point, holding a funnel: an apex, a left chain and a right chain. Each
# gate narrows the funnel. When a new left point would cross the right
# chain, the funnel has closed on that side -- the right chain's first
# point is a corner the path must turn at, so it becomes the new apex and
# the walk restarts from there. The points that become apexes, in order,
# are the shortest path.

(defn- cross
  ``Sign of the cross product (b-a) x (c-a): which side of ab the point c
  falls on.

  SCREEN COORDINATES, so y grows DOWNWARD and the sign is the opposite of
  the one the textbook statement assumes. Negated here, once, so that
  "left" below means left on the page and the funnel reads the way it is
  written. Left un-negated, the algorithm still runs and still terminates --
  it just rounds the far wall of every corner instead of the near one, which
  is a valid path and the wrong one.``
  [a b c]
  (- (* (- (b 1) (a 1)) (- (c 0) (a 0)))
     (* (- (b 0) (a 0)) (- (c 1) (a 1)))))

(defn path
  ``The shortest path from `start` to `goal` through `gates`.

  `gates` is a list of [left right y], strictly increasing in y with
  left <= right; `start` and `goal` are [x y] points. Returns the corner
  points, start and goal included -- a polyline that crosses every gate
  inside its span and turns only where it must.

  Returns nil for a gate with nothing to pass through (left > right),
  which is the caller's signal to fall back rather than draw a line
  through a wall.``
  [start goal gate-list]
  (if (empty? gate-list)
    [start goal]
    (do
      (var broken false)
      (each [l r _] gate-list (when (> l r) (set broken true)))
      (unless broken
        (def gates (array ;(map (fn [[l r y]] [[l y] [r y]]) gate-list)
                          [goal goal]))
        (def out @[start])
        (var apex start)
        (var left start)
        (var right start)
        (var left-at 0)
        (var right-at 0)
        (var i 0)
        (while (< i (length gates))
          (def gate (gates i))
          (def gate-left (gate 0))
          (def gate-right (gate 1))
          # Set when the funnel closes and the walk has to restart from a new
          # apex; the rest of this round is then skipped.
          (var restarted false)

          # THE RIGHT CHAIN. A new right point that does not widen the funnel
          # tightens it; one that crosses the LEFT chain means the funnel has
          # closed over there, and the left chain's first point is a corner.
          (when (<= (cross apex right gate-right) 0)
            (if (or (= apex right) (> (cross apex left gate-right) 0))
              (do (set right gate-right) (set right-at i))
              (do
                (array/push out left)
                (set apex left)
                (set right apex)
                (set i left-at)
                (set right-at left-at)
                (++ i)
                (set restarted true))))

          (unless restarted
            # THE LEFT CHAIN, the mirror of the above.
            (when (>= (cross apex left gate-left) 0)
              (if (or (= apex left) (< (cross apex right gate-left) 0))
                (do (set left gate-left) (set left-at i))
                (do
                  (array/push out right)
                  (set apex right)
                  (set left apex)
                  (set right apex)
                  (set i right-at)
                  (set left-at right-at)
                  (++ i)
                  (set restarted true))))
            (unless restarted (++ i))))
        # The goal is a gate as well as the destination -- it enters the walk
        # as a zero-width portal so the last corner before it is found -- so it
        # may already have been pushed as an apex. Pushing it twice would leave
        # a zero-length segment for the spline fitter to divide by.
        (unless (deep= (last out) goal) (array/push out goal))
        out))))

(defn channel
  ``The free interval at height `y`, between the gates that bracket it.

  Between two gate lines the corridor is modelled as the linear
  interpolation of their intervals -- straight walls from the end of one
  gate to the end of the next. The truly free region is wider (the whole
  band is open), but the interpolated channel has two properties worth
  more than tightness: the funnel's own polyline always fits it, since a
  segment between points inside consecutive gates stays between the
  interpolated walls by linearity, and a curve held to it cannot wander
  far from the path the funnel chose. Above the first gate and below the
  last the corridor does not constrain; nil says so.``
  [gate-list y]
  (var out nil)
  (for i 0 (- (length gate-list) 1)
    (def [l0 r0 y0] (gate-list i))
    (def [l1 r1 y1] (gate-list (+ i 1)))
    (when (and (<= y0 y) (<= y y1) (< y0 y1))
      (def t (/ (- y y0) (- y1 y0)))
      (set out [(+ l0 (* t (- l1 l0))) (+ r0 (* t (- r1 r0)))])))
  (when-let [[l r y0] (first gate-list)]
    (when (= y y0) (set out [l r])))
  out)
