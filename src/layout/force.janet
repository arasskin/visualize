# A force-directed layout, in about as few lines as a graph needs.
#
# WHY THIS EXISTS ALONGSIDE THE LAYERED ONE. Not because it draws a
# dependency graph better -- it does not, and `layered` is the default for
# that reason. It earned its place twice over anyway:
#
# It FORCED THE SEAM. Writing a second layout is what turned "a layout" into
# a function from a graph to positions, and once that was true the choice
# became a config line rather than an assumption baked through the renderer.
# The layered layout that later replaced graphviz slotted into the seam this
# one opened, which is why that swap touched no route and no page.
#
# And it answers a different question. Layers show DIRECTION -- what depends
# on what, in order. A force layout shows RELATEDNESS: what clusters with
# what, whatever the arrows do. For a tangle with no honest hierarchy, that
# is the more truthful picture, and it is the one place cycles and
# disconnected pieces cost nothing at all.
#
# THE MODEL is the usual one and there is no cleverness in it: nodes repel
# each other like charges, edges pull like springs, everything is dragged
# toward the middle so the picture cannot drift off, and the whole thing
# cools over a fixed number of rounds. Cycles, disconnected pieces and
# self-edges all fall out fine, which is the one place this beats a layered
# algorithm on honesty rather than looks.
#
# DETERMINISTIC, and that matters more than it sounds: the same graph must
# draw the same picture twice or a watcher redraw becomes a jump scare. The
# starting positions come from a hash of each node's name rather than from
# a random source.

(def- defaults
  {:rounds 300        # how many times the simulation steps
   :repel 9000        # strength of node-node repulsion
   :spring 0.03       # stiffness of an edge
   :rest 110          # the length an edge would like to be
   :gravity 0.015     # pull toward the middle, so nothing escapes
   :step 0.85         # how much of a round's force is applied
   :cool 0.985})      # ...and how quickly that fades

# A stable pseudo-random start: same name, same place, every run.
#
# Plain arithmetic rather than the usual FNV constants, because Janet's bit
# operations are 32-bit SIGNED and the seed alone overflows them. The mixing
# only has to scatter a few dozen names across a square; it is not a hash.
(defn- seed-of [name]
  (var h 7)
  (each byte name
    (set h (mod (+ (* h 131) byte) 1000003)))
  h)

(defn- start-positions [nodes]
  (def out @{})
  (each node nodes
    (def h (seed-of (node :name)))
    # Two independent-enough fields out of one hash.
    (put out (node :name)
         @{:x (- (mod h 1000) 500)
           :y (- (mod (div h 1000) 1000) 500)
           :dx 0 :dy 0}))
  out)

(defn place
  ``Positions for `graph`, as {name {:x :y}}, in arbitrary units.

  `opts` may override any of the constants above -- which is the point of
  having them in a table: a layout that feels wrong is a number to change,
  not a function to rewrite.``
  [graph &opt opts]
  (default opts {})
  (def tuning (merge (table ;(kvs defaults)) opts))
  (def nodes (get graph :nodes []))
  (def edges (get graph :edges []))
  (def points (start-positions nodes))
  (def names (map |($ :name) nodes))

  (var heat 1)
  (for _ 0 (tuning :rounds)
    # Repulsion: every pair pushes apart, softened at very short range so
    # two nodes landing on the same spot do not fling each other away.
    (each a names
      (def pa (points a))
      (each b names
        (unless (= a b)
          (def pb (points b))
          (def dx (- (pa :x) (pb :x)))
          (def dy (- (pa :y) (pb :y)))
          (def d2 (max 25 (+ (* dx dx) (* dy dy))))
          (def force (/ (tuning :repel) d2))
          (def d (math/sqrt d2))
          (put pa :dx (+ (pa :dx) (* force (/ dx d))))
          (put pa :dy (+ (pa :dy) (* force (/ dy d)))))))

    # Springs: an edge pulls its ends toward the rest length.
    (each [from to] edges
      (def pa (points from))
      (def pb (points to))
      (when (and pa pb)
        (def dx (- (pb :x) (pa :x)))
        (def dy (- (pb :y) (pa :y)))
        (def d (max 1 (math/sqrt (+ (* dx dx) (* dy dy)))))
        (def pull (* (tuning :spring) (- d (tuning :rest))))
        (def ux (/ dx d))
        (def uy (/ dy d))
        (put pa :dx (+ (pa :dx) (* pull ux)))
        (put pa :dy (+ (pa :dy) (* pull uy)))
        (put pb :dx (- (pb :dx) (* pull ux)))
        (put pb :dy (- (pb :dy) (* pull uy)))))

    # Gravity, and the step itself. Without gravity a disconnected node has
    # nothing but repulsion acting on it and leaves for the horizon.
    (each name names
      (def p (points name))
      (put p :dx (- (p :dx) (* (tuning :gravity) (p :x))))
      (put p :dy (- (p :dy) (* (tuning :gravity) (p :y))))
      (put p :x (+ (p :x) (* heat (tuning :step) (p :dx))))
      (put p :y (+ (p :y) (* heat (tuning :step) (p :dy))))
      # Velocities are not carried between rounds: this is a relaxation,
      # not a physics engine, and momentum makes it oscillate.
      (put p :dx 0)
      (put p :dy 0))
    (set heat (* heat (tuning :cool))))

  (def out @{})
  (eachp [name p] points
    (put out name {:x (p :x) :y (p :y)}))
  out)
