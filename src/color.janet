# Colour: the palette, and the arithmetic that keeps every fill legible.
#
# Two rules run this file. A group's colour is stored as ONE hue and every fill
# drawn from it is a tint of that hue, so a named colour and a palette colour
# go through identical code and cannot drift apart. And no label is ever
# painted without checking it against what is behind it -- `ink` and
# `ink-on-page` below walk a hue down toward black until it clears WCAG's
# 4.5:1, rather than picking black or white and hoping.

# The hues an unclaimed group draws from, in an order that puts consecutive
# groups far apart on the wheel -- adjacent boxes are what you most need to
# tell apart, and a palette walking the spectrum in order would put two blues
# side by side.
#
# Deliberately off the primary axes: pure blues and reds are what every
# corporate deck already looks like. These are pushed somewhere warmer, so
# `red` here is a coral and `green` a mint.
(def palette
  ["#ff4d6d"    # red
   "#3bceac"    # green
   "#ffa62b"    # orange
   "#8367c7"    # purple
   "#22a6f2"    # blue
   "#f5c518"    # yellow
   "#ee6c4d"    # orange-red
   "#06d6a0"    # teal
   "#c04cfd"    # magenta
   "#8ac926"    # yellow-green
   "#ff70a6"    # pink
   "#118ab2"])  # dark-blue

# What a node wears when no group claims it. Softer and less saturated than
# the palette's blue on purpose: it has to read as "no group" beside a real
# group rather than as another colour carrying meaning. It still takes the
# connectivity ramp, so hubs among the ungrouped files still show.
(def ungrouped "#7ea8c4")

# Plain names, hyphenated where one word will not do. They land on the
# palette's version of each hue rather than the primary -- ask for red and you
# get the palette's red, which is the point.
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

(def- hex-color (peg/compile ~(* "#" (6 :h) -1)))

(defn as-hex
  ``One colour as "#rrggbb", or nil if it is not a colour at all.

  A group carries only this. Every fill drawn from it is a tint at some
  brightness, so there is nothing else to store.``
  [color]
  (def text (string/trim (string color)))
  (def border (or (named (string/ascii-lower text)) text))
  (when (peg/match hex-color border)
    (string/ascii-lower border)))

(defn- channels
  "The three bytes of a #rrggbb, as numbers."
  [color]
  (map |(scan-number (string "0x" (string/slice color $ (+ $ 2)))) [1 3 5]))

(defn- to-hex
  "Three 0-255 numbers back into a #rrggbb, clamped and rounded."
  [parts]
  (string "#" (string/join (map |(string/format "%02x"
                                                (math/round (max 0 (min 255 $))))
                                parts))))

(defn tint
  ``A colour lightened toward white, less so as `weight` goes 0 -> 1.

  This is the ramp: a file nothing references comes out pale and a hub comes
  out nearly the full hue, so the busy parts of the graph catch the eye.

  Each channel keeps its distance from white in proportion, which holds the
  hue steady down the ramp -- a flat mix toward white would drift the pale end
  toward grey.``
  [color weight]
  # 0.62 is the palest a node gets. A low floor washes this palette out -- its
  # hues are light to begin with, so 40% of a mint is barely a colour -- and
  # most files sit at the bottom of the ramp, which would leave the graph
  # looking bleached. Keep the range narrow and clearly coloured.
  (def strength (+ 0.62 (* 0.38 (max 0 (min 1 weight)))))
  (to-hex (map |(- 255 (* (- 255 $) strength)) (channels color))))

(defn luminance
  "Relative luminance, per WCAG -- 0 is black, 1 is white."
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
  "WCAG contrast ratio between two colours, 1 (same) to 21 (black on white)."
  [one two]
  (def a (luminance one))
  (def b (luminance two))
  (def light (max a b))
  (def dark (min a b))
  (/ (+ light 0.05) (+ dark 0.05)))

# How far to walk a hue down toward black looking for legibility. The first
# shade that clears the bar keeps the most colour, so these run bright-to-dark
# and the search stops early.
(def- depths [0.34 0.26 0.20 0.15 0.10 0.05 0])

(defn ink
  ``Label text for a node of this fill, as dark or light as it needs to be.

  Not a flat black/white pick: on the deeper hues plain black only reaches
  about 3.9:1, under the 4.5:1 WCAG wants for body text, and white on those is
  worse. So the text is a heavily darkened version of the fill's OWN hue,
  deepened until it clears the bar -- which reads as belonging to the node
  rather than stamped on it.

  Very dark fills invert to near-white instead, since there is no darker
  version of them left to use.``
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
  ``Label text for an UNFILLED node: the hue, deepened until it reads against
  the page rather than against a fill.

  `ink`'s twin, and the difference is what the text sits on. `ink` darkens
  until it clears 4.5:1 against the FILL behind it and inverts to near-white
  when the fill is too dark to darken against -- correct there, invisible
  here, where there is nothing behind the text but the page.

  So this asks the same question against white and never inverts. Any hue
  darkened far enough clears the bar against a white ground, which is why the
  fallback is unreachable in practice.``
  [hue]
  (def parts (channels hue))
  (or (some (fn [depth]
              (def candidate (to-hex (map |(* $ depth) parts)))
              (when (>= (contrast candidate "#ffffff") 4.5) candidate))
            [0.55 0.45 0.34 0.26 0.20 0.15 0.10])
      "#000000"))

(defn ramp
  ``Map each node's count onto a 0-1 brightness, by RANK not ratio.

  Scaling against the busiest node looks right and reads wrong: these counts
  are long-tailed -- one hub with 13 edges against a floor of 1 or 2 -- so a
  straight ratio squashes almost every node into the pale end and the only
  thing visible is the hub.

  Ranking spends the whole ramp on the distribution that actually exists.
  Nodes sharing a count share a brightness, so the colour still means "this
  many connections" rather than "this position in a list".``
  [counts]
  (def tiers (sorted (distinct (values counts))))
  (def last (- (length tiers) 1))
  (if (< last 1)
    (table ;(mapcat |[$ 1] (keys counts)))
    (do
      # Rank lookup built once. Scanning the tier list per node would be
      # quadratic, and a big repo has thousands of nodes.
      (def rank-of (table ;(mapcat |[(tiers $) (/ $ last)] (range (length tiers)))))
      (table ;(mapcat |[$ (rank-of (counts $))] (keys counts))))))
