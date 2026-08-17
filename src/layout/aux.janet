# X-coordinates by the auxiliary graph, the way dot does it.
#
# THE IDEA, AND WHY IT IS WORTH THE FILE. Every other way of assigning x
# decides one rank at a time: compute what each node wants, resolve the row,
# move on. That is what src/layout/layered.janet does, and its row solver is
# optimal for the row -- but a row solver cannot trade a worse position on
# rank three for a better one on rank five, because it never sees rank five.
# The visible cost was a long edge ordered after a group box: seating honours
# order above every bound it is given, so the edge's bend was pushed to the
# far side of the box and the edge swung out around it and back.
#
# dot has no per-rank coordinate pass at all. position.c builds a SECOND
# GRAPH whose "ranks" are x-coordinates, expresses every desire as an edge in
# it, and runs the ranking algorithm on that:
#
#   separation   u -> v, minimum length (width_u + width_v)/2 + gap
#                for each adjacent pair in a rank. These are hard: the
#                solver may never violate a minimum length.
#
#   straightness for each real edge (a, b), a SLACK NODE s with two edges
#                s -> a and s -> b, both minimum length 0, both weighted by
#                how much that edge wants to be vertical. Pulling both tight
#                puts a and b at the same x. Slack cannot be had for both
#                unless the edge is vertical, so the optimiser buys as much
#                of it as the weights justify.
#
# Then: minimise the total weighted length of every edge, subject to the
# minimum lengths. That is exactly the ranking problem, so the same solver
# answers it -- which is dot's real trick, and the reason this file is a few
# hundred lines rather than a few thousand.
#
# WHAT MAKES IT DIFFERENT FROM THE RELAXATION IT REPLACES is that separation
# and straightness are in ONE objective. A bend cannot be shoved across a
# group box by the ordering, because the shove would stretch two weighted
# edges and the optimiser would rather move the box.
#
# STATE: THE DEFAULT, as of 2026-08. It spent its first weeks flagged off
# and measurably worse -- three edges through nodes, containment broken --
# and each of those fell to work elsewhere: the cluster walls below made
# containment a hard constraint rather than an outvotable preference, and
# the router (funnel, fit, obstacle gates, and their iterating dodging in
# svg.janet) learned to draw the tighter arrangement this formulation
# produces without touching anything. When it finally measured clean the
# user compared the pictures and chose the lobes. The relaxation remains
# behind VISUALIZE_RELAX for comparison runs; docs/dotgen-audit.md carries
# the full history, including the era when this file's own header called
# it not good enough.

# Weights, from dot's position.c. An edge between two real nodes matters
# least; an edge with one bend in it matters more, because a kink in a long
# edge is more visible than a node being slightly off-centre; an edge between
# two bends is the middle of a long chain and matters most, since that is
# what makes a chain read as one line.
(def- weight-real 1)
(def- weight-half 2)
(def- weight-both 8)

(defn- edge-weight [bend? a b]
  (cond
    (and (bend? a) (bend? b)) weight-both
    (or (bend? a) (bend? b)) weight-half
    weight-real))

(defn solve
  ``X for every name, as {name x}.

  `ordered` is {rank [names left to right]}; `widths` gives each name's full
  width; `edges` is the list of [from to] pairs to straighten, INCLUDING the
  segments of a bend chain, since those are what a long edge is made of.
  `gap` is a function of two adjacent names giving the space between them.

  `pin` optionally fixes a name's x -- used for a group's members, whose
  column is decided elsewhere.

  Returns nil when there is nothing to place, so a caller can fall back.``
  [ordered widths edges gap &opt bend? pin group-of]
  (default bend? (fn [_] false))
  (default pin (fn [_] nil))
  (default group-of (fn [_] nil))

  (def names @[])
  (each index (sort (keys ordered))
    (each name (ordered index) (array/push names name)))
  (if (empty? names)
    nil
    (do
      # -- build the auxiliary graph ------------------------------------
      # Every constraint is an edge {:to :min :weight}, held per source.
      (def out @{})
      (def all @[])
      (defn node! [name]
        (unless (out name) (put out name @[]) (array/push all name)))
      (each name names (node! name))

      (defn link [from to minimum weight]
        (node! from) (node! to)
        (array/push (out from) {:to to :min minimum :weight weight}))

      # SEPARATION. Adjacent in a rank means "at least this far apart", in
      # the order the crossing passes chose. These are the constraints that
      # must hold exactly; everything else is a preference.
      (each index (sort (keys ordered))
        (def row (ordered index))
        (for i 0 (- (length row) 1)
          (def a (row i))
          (def b (row (+ i 1)))
          (link a b
                (+ (/ (widths a) 2) (/ (widths b) 2) (gap a b))
                0)))

      # STRAIGHTNESS. One slack node per edge, pulling both ends together.
      # The slack node has no width and sits nowhere in particular; only the
      # two edges leaving it matter.
      (var slack-id 0)
      (each [from to] edges
        (when (and (out from) (out to))
          (def s [:slack (++ slack-id)])
          (def w (edge-weight bend? from to))
          (link s from 0 w)
          (link s to 0 w)))

      # CONTAINMENT, and this is the part that has to be a CONSTRAINT rather
      # than a preference.
      #
      # The first attempt tied each member to a shared slack node with a
      # heavy weight, and it lost: a member has many straightness edges
      # pulling it toward its own neighbours, and enough of them outvote one
      # heavy edge however heavy it is. `src.term`'s three members landed at
      # x=471, 503 and 774, and the box drawn round them swallowed
      # everything between.
      #
      # dot gives every cluster TWO VIRTUAL NODES -- a left wall and a right
      # wall (`make_lrvn`, then `contain_nodes` in position.c) -- and hangs
      # hard minimum lengths off them: the left wall is at least half a node
      # to the left of each rank's leftmost member, each rank's rightmost
      # member is at least half a node to the left of the right wall. The
      # box stops being a thing we draw around wherever the members ended up
      # and becomes an object in the graph with its own position, which the
      # solver has to respect because a minimum length cannot be traded away.
      #
      # KEEPOUT is the other half (`keepout_othernodes`): for each rank, the
      # nearest non-member on the left is constrained to sit left of the left
      # wall, and the nearest on the right to sit right of the right wall.
      # Without it the walls are honoured and strangers walk straight through
      # them, because nothing said they could not.
      (def walls @{})
      (when group-of
        (def margin (* 2 (gap (first names) (first names))))
        (each index (sort (keys ordered))
          (def row (ordered index))
          # Which slots on this rank belong to which group.
          (def slots @{})
          (eachp [i name] row
            (when-let [key (group-of name)]
              (put slots key (array/push (or (slots key) @[]) i))))
          (eachp [key here] slots
            (unless (walls key)
              (put walls key {:left [:wall-left key] :right [:wall-right key]}))
            (def wall (walls key))
            (def lo (min ;here))
            (def hi (max ;here))
            (def leftmost (row lo))
            (def rightmost (row hi))
            # The walls bracket the members on every rank the group occupies.
            (link (wall :left) leftmost (+ (/ (widths leftmost) 2) margin) 0)
            (link rightmost (wall :right) (+ (/ (widths rightmost) 2) margin) 0)
            # And strangers stay outside them. Only the NEAREST on each side
            # needs the constraint: separation already holds the rest in
            # order behind it.
            (when (pos? lo)
              (def outsider (row (- lo 1)))
              (unless (= key (group-of outsider))
                (link outsider (wall :left)
                      (+ (/ (widths outsider) 2) margin) 0)))
            (when (< hi (- (length row) 1))
              (def outsider (row (+ hi 1)))
              (unless (= key (group-of outsider))
                (link (wall :right) outsider
                      (+ (/ (widths outsider) 2) margin) 0))))))

      # -- solve ---------------------------------------------------------
      # Longest-path for a feasible start: every node at least `min` past
      # everything pointing at it. The aux graph is acyclic by construction
      # -- separation runs left to right along a rank, and a slack node has
      # no edges into it -- so this terminates.
      (def x @{})
      (each name all (put x name 0))
      (def incoming @{})
      (each name all (put incoming name 0))
      (eachp [from links] out
        (each l links (put incoming (l :to) (+ 1 (incoming (l :to))))))
      (def queue (filter |(zero? (incoming $)) all))
      (var head 0)
      (while (< head (length queue))
        (def name (queue head))
        (++ head)
        (each l (out name)
          (put x (l :to) (max (x (l :to)) (+ (x name) (l :min))))
          (put incoming (l :to) (- (incoming (l :to)) 1))
          (when (zero? (incoming (l :to))) (array/push queue (l :to)))))

      # Then relax toward minimum weighted length, the same way the ranker
      # does: a node moves to the weighted median of what pulls on it,
      # clamped to what its constraints allow. A weighted median rather than
      # a mean because the objective is a sum of absolute lengths, and the
      # median is what minimises that.
      (def into @{})
      (each name all (put into name @[]))
      (eachp [from links] out
        (each l links
          (array/push (into (l :to)) {:from from :min (l :min) :weight (l :weight)})))

      (var moved true)
      (var rounds 0)
      (while (and moved (< rounds 32))
        (set moved false)
        (++ rounds)
        (each name all
          (unless (pin name)
            # The window this node may occupy without breaking a minimum
            # length in either direction.
            (var floor (- math/inf))
            (var ceiling math/inf)
            (each l (into name)
              (set floor (max floor (+ (x (l :from)) (l :min)))))
            (each l (out name)
              (set ceiling (min ceiling (- (x (l :to)) (l :min)))))
            # Everything pulling, with its weight. Zero-weight separation
            # edges are constraints only -- they bound the window above and
            # say nothing about where in it the node should sit.
            (def pulls @[])
            (each l (into name)
              (when (pos? (l :weight))
                (repeat (l :weight) (array/push pulls (+ (x (l :from)) (l :min))))))
            (each l (out name)
              (when (pos? (l :weight))
                (repeat (l :weight) (array/push pulls (- (x (l :to)) (l :min))))))
            (unless (empty? pulls)
              (def sorted-pulls (sorted pulls))
              (def want (sorted-pulls (div (length sorted-pulls) 2)))
              (def target (min ceiling (max floor want)))
              (when (and (>= ceiling floor)
                         (> (math/abs (- target (x name))) 0.01))
                (put x name target)
                (set moved true))))))

      # A pinned name is honoured by placing it and letting the round above
      # move everything else around it.
      (each name all
        (when-let [at (pin name)] (put x name at)))

      # Only the real names go back; slack nodes were scaffolding.
      (def out-x @{})
      (each name names (put out-x name (x name)))
      out-x)))
