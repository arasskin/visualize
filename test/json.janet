# The JSON that carries every edit to and from the browser.

(import ../visualize/json)
(import ./harness :as t)

(t/test "scalars encode as JSON, not as Janet"
  (t/is= "null" (json/encode nil))
  (t/is= "true" (json/encode true))
  (t/is= "false" (json/encode false))
  (t/is= "42" (json/encode 42) "a whole number keeps no decimal point")
  (t/is= `"hi"` (json/encode "hi")))

(t/test "a table keyed by NUMBER keeps its values"
  # The bug this exists for: per-line problems are keyed by line index, and
  # stringifying the key before looking the value up turned every message in
  # the editor into a silent `null`.
  (t/is= `{"1":"bad colour","3":"unknown verb"}`
         (json/encode @{1 "bad colour" 3 "unknown verb"})))

(t/test "a string cannot break out of the <script> block it is embedded in"
  # The page inlines this into a <script>; a literal </script> would end the
  # block early and drop the rest of the config into the document as HTML.
  (def encoded (json/encode "</script><img src=x onerror=alert(1)>"))
  (t/ok (not (string/find "</script>" encoded)))
  (t/ok (not (string/find "<" encoded)) "no raw < survives, escaped as \\u003c")
  (t/ok (not (string/find ">" encoded)))
  # Escaped on the way out, identical on the way back: the page still sees the
  # text the config actually contains.
  (t/is= "</script><img src=x onerror=alert(1)>" (json/decode encoded)))

(t/test "control characters and quotes are escaped"
  (t/is= `"a\nb"` (json/encode "a\nb"))
  (t/is= `"say \"hi\""` (json/encode `say "hi"`))
  (t/is= `"back\\slash"` (json/encode "back\\slash")))

(t/test "decoding reads what the page sends"
  (def got (json/decode `{"action":"run","index":3,"lines":["(hide ~.A)",""]}`))
  (t/is= "run" (got "action"))
  (t/is= 3 (got "index"))
  (t/is= ["(hide ~.A)" ""] (got "lines")))

(t/test "decoding handles the escapes encoding produces"
  (t/is= "</script>" (json/decode `"</script>"`)
         "what encode wrote, decode reads back")
  (t/is= "a\nb" (json/decode `"a\nb"`))
  (t/is= ["x"] (json/decode `["x"]`))
  (t/is= {} (json/decode "{}"))
  (t/is= [] (json/decode "[]")))

(t/test "a round trip through both is the identity"
  (def original {"lines" ["(show-only ~)" "(group ~.A red)"]
                 "problems" {"0" "went wrong"}
                 "error" ""
                 "svg" "<svg><path d=\"M0,0\"/></svg>"})
  (t/is= original (json/decode (json/encode original))))
