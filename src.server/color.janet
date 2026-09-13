(def palette
  ["#ff4d6d"
   "#3bceac"
   "#ffa62b"
   "#8367c7"
   "#22a6f2"
   "#f5c518"
   "#ee6c4d"
   "#06d6a0"
   "#c04cfd"
   "#8ac926"
   "#ff70a6"
   "#118ab2"])

(def ungrouped "#7ea8c4")

(def named
  {"red" "#ff4d6d"
   "green" "#3bceac"
   "orange" "#ffa62b"
   "purple" "#8367c7"
   "blue" "#22a6f2"
   "yellow" "#f5c518"
   "orange-red" "#ee6c4d"
   "teal" "#06d6a0"
   "magenta" "#c04cfd"
   "yellow-green" "#8ac926"
   "pink" "#ff70a6"
   "dark-blue" "#118ab2"
   "grey" "#8d99ae"
   "gray" "#8d99ae"})

(def- hex-color (peg/compile ~(* (6 :h) -1)))

(defn as-hex

  [color]
  (def text (string/ascii-lower (string/trim (string color))))

  (if-let [hit (named text)]
    hit
    (when (peg/match hex-color text)
      (string "#" text))))

(defn- channels

  [color]
  (map |(scan-number (string "0x" (string/slice color $ (+ $ 2)))) [1 3 5]))

(defn- to-hex

  [parts]
  (string "#" (string/join (map |(string/format "%02x"
                                                (math/round (max 0 (min 255 $))))
                                parts))))

(defn tint

  [color weight]

  (def strength (+ 0.62 (* 0.38 (max 0 (min 1 weight)))))
  (to-hex (map |(- 255 (* (- 255 $) strength)) (channels color))))

(defn luminance

  [color]
  (def linear
    (map (fn [c]
           (def v (/ c 255))
           (if (<= v 0.04045)
             (/ v 12.92)
             (math/pow (/ (+ v 0.055) 1.055) 2.4)))
         (channels color)))
  (+ (* 0.2126 (linear 0)) (* 0.7152 (linear 1)) (* 0.0722 (linear 2))))

(defn contrast

  [one two]
  (def a (luminance one))
  (def b (luminance two))
  (def light (max a b))
  (def dark (min a b))
  (/ (+ light 0.05) (+ dark 0.05)))

(def- depths [0.34 0.26 0.20 0.15 0.10 0.05 0])

(defn ink

  [fill]
  (if (< (luminance fill) 0.18)
    "#f7f7f7"
    (do
      (def parts (channels fill))
      (or (some (fn [depth]
                  (def candidate (to-hex (map |(* $ depth) parts)))
                  (when (>= (contrast candidate fill) 4.5) candidate))
                depths)
          "#000000"))))

(defn ink-on-page

  [hue]
  (def parts (channels hue))
  (or (some (fn [depth]
              (def candidate (to-hex (map |(* $ depth) parts)))
              (when (>= (contrast candidate "#ffffff") 4.5) candidate))
            [0.55 0.45 0.34 0.26 0.20 0.15 0.10])
      "#000000"))

(defn ramp

  [counts]
  (def tiers (sorted (distinct (values counts))))
  (def last (- (length tiers) 1))
  (if (< last 1)
    (table ;(mapcat |[$ 1] (keys counts)))
    (do

      (def rank-of (table ;(mapcat |[(tiers $) (/ $ last)] (range (length tiers)))))
      (table ;(mapcat |[$ (rank-of (counts $))] (keys counts))))))

(def for-drawing
  {:ungrouped ungrouped
   :ink ink-on-page
   :tint |(tint $ 0.3)})
