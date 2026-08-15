# Colour arithmetic, checked against the values the Python tools produce.
#
# These numbers are not invented here: they are what swiftdepgraph.py's tint,
# ink, ink_on_page and ramp return for the same inputs. Keeping them means a
# port that drifts is a port that fails, rather than one that quietly draws a
# different-looking graph.

(import ../src/color :as color)
(import ./harness :as t)

(t/test "as-hex resolves names, hex and rubbish"
  (t/is= "#ff4d6d" (color/as-hex "red"))
  (t/is= "#aabbcc" (color/as-hex "#AABBCC"))
  (t/is= "#22a6f2" (color/as-hex "blue"))
  (t/is= "#8d99ae" (color/as-hex "gray") "gray and grey are the same colour")
  (t/is= nil (color/as-hex "nope"))
  (t/is= nil (color/as-hex "#ff") "a short hex is not a colour"))

(t/test "tint holds the hue and lands on the endpoints Python gives"
  (t/is= "#ff91a4" (color/tint "#ff4d6d" 0))
  (t/is= "#ff4d6d" (color/tint "#ff4d6d" 1))
  (t/is= "#ff91a4" (color/tint "#ff4d6d" -5) "weights clamp at 0")
  (t/is= "#ff4d6d" (color/tint "#ff4d6d" 5) "weights clamp at 1"))

(t/test "ink and ink-on-page clear WCAG"
  (t/is= "#42141c" (color/ink "#ff4d6d"))
  (t/is= "#8c2a3c" (color/ink-on-page "#ff4d6d"))
  (t/is= "#f7f7f7" (color/ink "#101010") "a dark fill inverts to near-white")
  # The property the exact values above exist to protect.
  (each hue color/palette
    (t/ok (>= (color/contrast (color/ink hue) hue) 4.5)
          (string "ink is legible on " hue))
    (t/ok (>= (color/contrast (color/ink-on-page hue) "#ffffff") 4.5)
          (string "ink-on-page is legible for " hue))))

(t/test "ramp ranks rather than scales"
  # The long tail is the point: 13 is far from 5, but both are one tier apart.
  (t/is= {"a" 0 "b" 0 "c" 0.5 "d" 1}
         (color/ramp {"a" 1 "b" 1 "c" 5 "d" 13}))
  (t/is= {"only" 1} (color/ramp {"only" 3})
         "a single tier is fully bright rather than divided by zero"))

(t/test "the palette is distinct and excludes the ungrouped colour"
  (t/is= (length color/palette) (length (distinct color/palette)))
  (t/ok (not (index-of color/ungrouped color/palette))
        "a group must never be handed the colour ungrouped nodes wear"))
