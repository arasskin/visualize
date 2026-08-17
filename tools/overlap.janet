# How well does the finished picture read?
#
#     ./bin/janet tools/overlap.janet             score the current tree
#     ./bin/janet tools/overlap.janet some.svg    score an SVG already drawn
#
# The layout's own obstruction check answers this for the straight line it
# is CONSIDERING; this asks it of the finished SVG, which is the picture a
# reader actually gets. The two can disagree -- a curve chosen to clear one
# node can be bent into another, and a bend moved by a later pass takes its
# edge with it -- so the only trustworthy count is the one taken from the
# output.
#
# Node overlap comes at three tolerances because "overlap" is not one thing:
# crossing a node is a bug, clipping its outline is usually a bug, and
# passing within a fifth of a node-width is a judgement call. An edge is not
# counted against the two ellipses it lands on, which it is entitled to
# touch. The number to keep at zero is the first.
#
# CROSSINGS are counted here too, and from the drawing rather than from the
# layout's own tally, for the same reason as above: the ordering pass counts
# crossings between the STRAIGHT lines of adjacent ranks, and a routed curve
# can cross where the straight lines did not. This is the whole-picture
# number test/layered.janet pins.
#
# TAKING A FILE is what makes comparisons honest. The tool draws itself, so
# "before" and "after" of a code change are different graphs -- the change
# adds nodes -- and the only fair comparison is two SVGs rendered from the
# SAME tree by different code. Render each side to a file, score both.
(import ../src/scan) (import ../src/parsers) (import ../src/config)
(import ../src/select) (import ../src/layout)

(def svg
  (if-let [path (get (dyn :args) 1)]
    (slurp path)
    (do
      (def specs (parsers/load "./src/parsers"))
      (def graph (scan/scan "." specs))
      (def [state _] (config/run (string/split "\n" (string/trimr (slurp "config.janet")))))
      (def trimmed (select/drop-nodes (select/keep graph (state :only)) (state :hidden)))
      (def [ok drawn] (layout/draw trimmed {:layout "layered" :groups (state :groups)
                                            :sized (state :sized) :filled (state :filled)
                                            :font (state :font)}))
      drawn)))

# Every ellipse: centre and radii.
(def ellipses @[])
(var at 0)
(var found (string/find "<ellipse" svg at))
(while found
  (def chunk (string/slice svg found (+ found 200)))
  (def m (peg/match ~(* (thru `cx="`) (<- (some (if-not `"` 1)))
                        `" cy="` (<- (some (if-not `"` 1)))
                        `" rx="` (<- (some (if-not `"` 1)))
                        `" ry="` (<- (some (if-not `"` 1))))
                    chunk))
  (when m
    (array/push ellipses {:x (scan-number (m 0)) :y (scan-number (m 1))
                          :rx (scan-number (m 2)) :ry (scan-number (m 3))}))
  (set at (+ found 8))
  (set found (string/find "<ellipse" svg at)))

# Every edge path's d, with the pair it joins.
(def paths @[])
(set at 0)
(set found (string/find `<g class="edge">` svg at))
(while found
  (def chunk (string/slice svg found (min (length svg) (+ found 900))))
  (def m (peg/match ~(* (thru "<title>") (<- (some (if-not "<" 1)))
                        (thru `d="`) (<- (some (if-not `"` 1))))
                    chunk))
  (when m (array/push paths {:title (m 0) :d (m 1)}))
  (set at (+ found 16))
  (set found (string/find `<g class="edge">` svg at)))

# Sample each path and count points that land inside an unrelated ellipse.
(defn points-of [d]
  (def nums @[])
  (each piece (string/split " " d)
    (each part (string/split "," (string/slice piece (if (peg/match ~(range "AZ") piece) 1 0)))
      (when-let [n (scan-number part)] (array/push nums n))))
  (partition 2 nums))

(var hits 0)
(var grazes 0)
(var nears 0)
(var checked 0)
(defn own-ellipses [pts]
  # The ellipses this edge is entitled to touch: the ones its ends sit on.
  (def ends [(first pts) (last pts)])
  (def mine @{})
  (each e ellipses
    (each end ends
      (def dx (/ (- (end 0) (e :x)) (max 0.001 (e :rx))))
      (def dy (/ (- (end 1) (e :y)) (max 0.001 (e :ry))))
      # On or just outside the outline is where an arrow lands.
      (when (< (+ (* dx dx) (* dy dy)) 1.6) (put mine e true))))
  mine)

(each p paths
  (def pts (points-of (p :d)))
  (when (>= (length pts) 2)
    (def mine (own-ellipses pts))
    (++ checked)
    (var bad false)
    (var grazed false)
    (var near false)
    # Walk the polyline through its control points -- close enough to the
    # curve for counting, and it never reports a hit the curve avoids.
    (for i 0 (- (length pts) 1)
      (def a (pts i)) (def b (pts (+ i 1)))
      (for k 0 21
        (def t (/ k 20))
        (def px (+ (a 0) (* t (- (b 0) (a 0)))))
        (def py (+ (a 1) (* t (- (b 1) (a 1)))))
        (each e ellipses
          (unless (mine e)
          (def dx (/ (- px (e :x)) (max 0.001 (e :rx))))
          (def dy (/ (- py (e :y)) (max 0.001 (e :ry))))
          # Well inside, so touching an endpoint's own ellipse is not a hit.
          (def d2 (+ (* dx dx) (* dy dy)))
          (when (< d2 0.55) (set bad true))
          (when (< d2 1.0) (set grazed true))
          (when (< d2 1.44) (set near true))))))
    (when bad (++ hits))
    (when grazed (++ grazes))
    (when near (++ nears))))
# -- crossings, between the curves as drawn --------------------------------
#
# The control-point polyline above is fine for "did it enter this ellipse"
# but wrong for crossings: a bezier's control polygon crosses things the
# curve does not. So each path is flattened properly -- M/L/Q/C/S walked
# with the real curve arithmetic, sampled densely -- and crossings are
# segment intersections between the flattened curves of two edges that
# share no endpoint node. Edges meeting at a node always touch there and a
# reader does not count that as a crossing; nor does this.

(defn- flatten-d
  "The path as a dense polyline of [x y], following the actual curves."
  [d]
  (def out @[])
  (var cx 0) (var cy 0)
  (var px nil) (var py nil) # previous cubic control, for S reflection
  (def toks (peg/match ~(any (+ (* ($) (<- (range "AZ" "az")))
                                (<- (* (? "-") (some (range "09" ".."))))
                                1))
                       d))
  # Tokens interleave command letters and numbers; walk them.
  (var i 0)
  (defn num [] (def v (scan-number (toks i))) (++ i) v)
  (while (< i (length toks))
    (def tok (toks i))
    (if (number? tok)
      (++ i) # a position capture from ($) -- skip
      (if (peg/match ~(range "AZ" "az") tok)
        (do
          (++ i)
          (case tok
            "M" (do (set cx (num)) (set cy (num)) (array/push out [cx cy])
                    (set px nil))
            "L" (do (set cx (num)) (set cy (num)) (array/push out [cx cy])
                    (set px nil))
            "Q" (let [qx (num) qy (num) ex (num) ey (num) [sx sy] [cx cy]]
                  (for k 1 17
                    (def t (/ k 16)) (def u (- 1 t))
                    (array/push out [(+ (* u u sx) (* 2 u t qx) (* t t ex))
                                     (+ (* u u sy) (* 2 u t qy) (* t t ey))]))
                  (set cx ex) (set cy ey) (set px nil))
            (do # C and S are both cubics; S reflects the previous control.
              (def [c1x c1y]
                (if (= tok "S")
                  (if px [(- (* 2 cx) px) (- (* 2 cy) py)] [cx cy])
                  [(num) (num)]))
              (def c2x (num)) (def c2y (num))
              (def ex (num)) (def ey (num))
              (def [sx sy] [cx cy])
              (for k 1 17
                (def t (/ k 16)) (def u (- 1 t))
                (array/push out
                            [(+ (* u u u sx) (* 3 u u t c1x) (* 3 u t t c2x) (* t t t ex))
                             (+ (* u u u sy) (* 3 u u t c1y) (* 3 u t t c2y) (* t t t ey))]))
              (set px c2x) (set py c2y)
              (set cx ex) (set cy ey))))
        (++ i))))
  out)

(defn- ends-of
  "The two node names an edge's title joins, [from to]."
  [title]
  (string/split "->" (string/replace "-&gt;" "->" title)))

(defn- segments-cross? [a b c d]
  (defn side [p q r]
    (- (* (- (q 0) (p 0)) (- (r 1) (p 1)))
       (* (- (q 1) (p 1)) (- (r 0) (p 0)))))
  (and (neg? (* (side a b c) (side a b d)))
       (neg? (* (side c d a) (side c d b)))))

(def flat (map (fn [p] {:ends (ends-of (p :title)) :pts (flatten-d (p :d))})
               paths))
(var crossings 0)
(for i 0 (length flat)
  (for j (+ i 1) (length flat)
    (def a (flat i)) (def b (flat j))
    (def [af at] (a :ends)) (def [bf bt] (b :ends))
    (unless (or (= af bf) (= af bt) (= at bf) (= at bt))
      # One crossing per pair at most: two curves that weave count once,
      # because a reader unpicks the pair once.
      (var found false)
      (def ap (a :pts)) (def bp (b :pts))
      (for m 0 (- (length ap) 1)
        (unless found
          (for n 0 (- (length bp) 1)
            (unless found
              (when (segments-cross? (ap m) (ap (+ m 1)) (bp n) (bp (+ n 1)))
                (set found true))))))
      (when found (++ crossings)))))

# Drawn extent, from the svg header -- the layout already computed it, and
# the coordinate space inside is centred so min/max over elements would
# need the same bookkeeping for less authority.
(def size (peg/match ~(* (thru `width="`) (<- (some (if-not `"` 1)))
                         `" height="` (<- (some (if-not `"` 1))))
                     svg))

(printf "of %d edges: %d cross a node, %d clip its outline, %d pass within 20%%"
        checked hits grazes nears)
(printf "%d edge pairs cross; drawn %s x %s"
        crossings (get size 0 "?") (get size 1 "?"))
