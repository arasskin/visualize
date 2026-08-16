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
# STATE: NOT THE DEFAULT, AND NOT YET GOOD ENOUGH TO BE. Set VISUALIZE_AUX to
# use it. On this tool's own graph it draws 946 wide against the relaxation's
# 1161 -- the compaction dot's formulation is known for -- and it is worse
# where it matters: three edges cross a node against none, because group
# containment does not hold. `src.term`'s members land at x=471, 503 and 774,
# so the box drawn round them sprawls three hundred units and swallows
# whatever is between.
#
# The cause is the weights. Containment here is one heavy edge per member to
# a shared slack node, which loses to the many straightness edges pulling
# each member toward its own neighbours. dot does not do it this way: it adds
# LR constraint edges between a cluster's bounding nodes (`contain_nodes`,
# `keepout_othernodes`, `separate_subclust` in position.c), so containment is
# a hard minimum length rather than a preference that can be outvoted. Until
# those go in, this file is a demonstration that the formulation ports, not a
# replacement for the pass that ships.

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

      # CONTAINMENT, which is dot's contain_nodes in position.c. A group's
      # members want one column: each is tied to a per-group slack node with
      # a weight heavy enough to beat the straightness of an ordinary edge,
      # so the box stays a box while the column as a whole is still free to
      # move wherever the rest of the graph wants it.
      (def group-slack @{})
      (each name names
        (when-let [key (group-of name)]
          (unless (group-slack key)
            (put group-slack key [:group key]))
          (link (group-slack key) name 0 weight-both)))

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
