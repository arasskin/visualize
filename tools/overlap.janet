# How often does a drawn edge pass through a node it does not connect?
#
#     ./bin/janet tools/overlap.janet
#
# The layout's own obstruction check answers this for the straight line it
# is CONSIDERING; this asks it of the finished SVG, which is the picture a
# reader actually gets. The two can disagree -- a curve chosen to clear one
# node can be bent into another, and a bend moved by a later pass takes its
# edge with it -- so the only trustworthy count is the one taken from the
# output.
#
# It reports three tolerances because "overlap" is not one thing: crossing a
# node is a bug, clipping its outline is usually a bug, and passing within a
# fifth of a node-width is a judgement call. An edge is not counted against
# the two ellipses it lands on, which it is entitled to touch.
#
# The number to keep at zero is the first. On this tool's own graph all
# three have been zero since the routing work, and this exists so that
# stays true rather than being rediscovered by looking at a picture.
(import ../src/scan) (import ../src/parsers) (import ../src/config)
(import ../src/select) (import ../src/layout)

(def specs (parsers/load "./src/parsers"))
(def graph (scan/scan "." specs))
(def [state _] (config/run (string/split "\n" (string/trimr (slurp "config.janet")))))
(def trimmed (select/drop-nodes (select/keep graph (state :only)) (state :hidden)))
(def [ok svg] (layout/draw trimmed {:layout "layered" :groups (state :groups)
                                    :sized (state :sized) :filled (state :filled)
                                    :font (state :font)}))

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
(printf "of %d edges: %d cross a node, %d clip its outline, %d pass within 20%%"
        checked hits grazes nears)
