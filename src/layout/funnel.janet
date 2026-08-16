# The shortest path through a stack of boxes.
#
# WHAT THIS IS FOR. A long edge crosses several ranks, and on each one the
# layout reserves it a slot with free space either side -- see the corridor
# note in layered.janet. The corridor is the permission; this decides where
# in it the line actually runs. Given the boxes and the two endpoints, it
# returns the shortest path that stays inside them, which for a drawing means
# the straightest one a reader can follow.
#
# THE FUNNEL ALGORITHM, and it is simpler here than in the literature. The
# usual statement is over a channel of triangles from a triangulated polygon,
# with all the machinery that implies -- graphviz spends most of shortest.c
# on exactly that, because its input can be any simple polygon. Ours cannot:
# a corridor is built rank by rank, so it is always a stack of axis-aligned
# boxes, strictly descending, one per rank. Measured on this tool's own
# graph, eighteen of eighteen. The "portals" between consecutive triangles
# are therefore just the horizontal overlap between consecutive boxes, and
# the funnel runs directly over those.
#
# HOW IT WORKS. Walk the portals from the start point, holding a funnel: an
# apex, a left chain and a right chain. Each new portal narrows the funnel.
# When a new left point would cross the right chain, the funnel has closed on
# that side -- the right chain's first point is a corner the path must turn
# at, so it becomes the new apex and the walk restarts from there. The points
# that become apexes, in order, are the shortest path.

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

(defn portals
  ``The gates between consecutive boxes, as [left right] point pairs.

  A portal is where the path crosses from one box to the next: the shared
  horizontal span at the boundary between them, which is the overlap of the
  two boxes' x-ranges.

  RETURNS NIL WHEN TWO CONSECUTIVE BOXES DO NOT OVERLAP, because then there
  is no opening between them and no path through the corridor at all.

  Worth stating plainly, since the first version tried to be helpful here
  and produced a silent wrong answer instead. It emitted the span BETWEEN
  the two boxes -- min(r0,r1) to max(l0,l1) -- as though it were a gate. For
  boxes [0,40] and [100,140] that is the gate [40,100]: precisely the region
  the path may not enter, offered to the funnel as the one place it may go.
  The funnel dutifully drew a straight line through the wall, and the line
  looked perfectly reasonable.

  A corridor built from one bend chain cannot hit this case -- consecutive
  bends are one rank apart and their boxes are centred on them -- so nil
  here means the caller built something that is not a corridor, and the
  caller should fall back rather than draw the result.``
  [boxes]
  (def out @[])
  (var broken false)
  (for i 0 (- (length boxes) 1)
    (def [l0 r0 y0] (boxes i))
    (def [l1 r1 y1] (boxes (+ i 1)))
    (def left (max l0 l1))
    (def right (min r0 r1))
    # The gate sits on the boundary between the two ranks.
    (def y (/ (+ y0 y1) 2))
    (if (<= left right)
      (array/push out [[left y] [right y]])
      (set broken true)))
  (unless broken out))

(defn path
  ``The shortest path from `start` to `goal` through `boxes`.

  `boxes` is a list of [left right y], strictly descending in y; `start` and
  `goal` are [x y] points. Returns the corner points, start and goal
  included -- a polyline that stays inside the corridor and turns only where
  it must.

  Returns nil when the boxes do not form a connected corridor, which is the
  caller's signal to fall back rather than draw a line that goes through a
  wall.``
  [start goal boxes]
  (if (empty? boxes)
    [start goal]
    (when-let [gate-list (portals boxes)]
      (def gates (array ;gate-list [goal goal]))
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
      out)))
