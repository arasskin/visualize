# JSON, in as few lines as the browser protocol needs.
#
# Janet has no JSON in its core and the tool ships no dependencies, so this is
# the price of talking to a browser. It handles exactly what crosses the wire
# here -- objects, arrays, strings, numbers, booleans, null -- and nothing
# else. No streaming, no bignums, no `\uXXXX` surrogate pairs on the way out.
#
# ENCODING IS THE HALF THAT MATTERS FOR SAFETY. The result is embedded in a
# <script> block in the page, so `</script>` appearing inside a config line
# would end that block early and drop the rest of the file into the document
# as HTML. `<` is escaped for exactly that reason -- see `escape` below.

(defn- escape
  "One string as a JSON string literal, safe to embed in a <script> block."
  [text]
  (def out @"\"")
  (each byte text
    (cond
      (= byte (chr "\"")) (buffer/push-string out "\\\"")
      (= byte (chr "\\")) (buffer/push-string out "\\\\")
      (= byte (chr "\n")) (buffer/push-string out "\\n")
      (= byte (chr "\r")) (buffer/push-string out "\\r")
      (= byte (chr "\t")) (buffer/push-string out "\\t")
      # `</script>` inside a string would close the block the page embeds this
      # in, and everything after it would be parsed as HTML. Escaping `<` costs
      # nothing and closes that hole wherever the string ends up.
      (= byte (chr "<")) (buffer/push-string out "\\u003c")
      (= byte (chr ">")) (buffer/push-string out "\\u003e")
      (= byte (chr "&")) (buffer/push-string out "\\u0026")
      # Control characters are not legal raw in a JSON string.
      (< byte 0x20) (buffer/push-string out (string/format "\\u%04x" byte))
      (buffer/push-byte out byte)))
  (buffer/push-string out "\"")
  (string out))

(defn encode
  "A Janet value as JSON text."
  [value]
  (cond
    (nil? value) "null"
    (= value true) "true"
    (= value false) "false"
    (number? value) (if (= value (math/floor value))
                      (string (math/floor value))
                      (string value))
    (or (string? value) (buffer? value)) (escape value)
    (keyword? value) (escape (string value))
    (symbol? value) (escape (string value))
    (indexed? value) (string "[" (string/join (map encode value) ",") "]")
    (dictionary? value)
    # Sorted by the key AS WRITTEN, but looked up by the ORIGINAL key -- the
    # per-line problem table is keyed by integer, and stringifying the key
    # before the lookup silently turned every message into null.
    (string "{"
            (string/join
              (map (fn [k] (string (escape (string k)) ":" (encode (get value k))))
                   (sorted-by string (keys value)))
              ",")
            "}")
    (escape (string value))))

# -- decoding ---------------------------------------------------------------
# A plain recursive-descent reader over a byte offset. Only what the page
# sends ever reaches it.

(defn- skip-space [text at]
  (var i at)
  (while (and (< i (length text))
              (let [c (text i)]
                (or (= c 32) (= c 9) (= c 10) (= c 13))))
    (++ i))
  i)

(defn- read-string-at [text at]
  # `at` points at the opening quote.
  (var i (+ at 1))
  (def out @"")
  (while (and (< i (length text)) (not= (text i) (chr "\"")))
    (if (= (text i) (chr "\\"))
      (let [next (get text (+ i 1))]
        (cond
          (= next (chr "n")) (do (buffer/push-byte out 10) (+= i 2))
          (= next (chr "t")) (do (buffer/push-byte out 9) (+= i 2))
          (= next (chr "r")) (do (buffer/push-byte out 13) (+= i 2))
          (= next (chr "b")) (do (buffer/push-byte out 8) (+= i 2))
          (= next (chr "f")) (do (buffer/push-byte out 12) (+= i 2))
          (= next (chr "u"))
          (let [code (scan-number (string "0x" (string/slice text (+ i 2) (+ i 6))))]
            # Encoded back to UTF-8. Surrogate pairs are not reassembled --
            # nothing the page sends contains one, and pretending otherwise
            # would be a bug waiting rather than a feature.
            (cond
              (< code 0x80) (buffer/push-byte out code)
              (< code 0x800) (do (buffer/push-byte out (bor 0xc0 (brshift code 6)))
                                 (buffer/push-byte out (bor 0x80 (band code 0x3f))))
              (do (buffer/push-byte out (bor 0xe0 (brshift code 12)))
                  (buffer/push-byte out (bor 0x80 (band (brshift code 6) 0x3f)))
                  (buffer/push-byte out (bor 0x80 (band code 0x3f)))))
            (+= i 6))
          (do (buffer/push-byte out (or next (chr "\\"))) (+= i 2))))
      (do (buffer/push-byte out (text i)) (++ i))))
  [(string out) (+ i 1)])

(defn- read-value [text at]
  (def i (skip-space text at))
  (when (>= i (length text)) (error "unexpected end of JSON"))
  (def c (text i))
  (cond
    (= c (chr "\"")) (read-string-at text i)

    (= c (chr "{"))
    (do
      (var j (skip-space text (+ i 1)))
      (def out @{})
      (if (= (get text j) (chr "}"))
        [out (+ j 1)]
        (do
          (var running true)
          (while running
            (set j (skip-space text j))
            (def [key after-key] (read-string-at text j))
            (set j (skip-space text after-key))
            (unless (= (get text j) (chr ":")) (error "expected ':' in object"))
            (def [value after-value] (read-value text (+ j 1)))
            (put out key value)
            (set j (skip-space text after-value))
            (cond
              (= (get text j) (chr ",")) (++ j)
              (= (get text j) (chr "}")) (do (++ j) (set running false))
              (error "expected ',' or '}' in object")))
          [out j])))

    (= c (chr "["))
    (do
      (var j (skip-space text (+ i 1)))
      (def out @[])
      (if (= (get text j) (chr "]"))
        [out (+ j 1)]
        (do
          (var running true)
          (while running
            (def [value after] (read-value text j))
            (array/push out value)
            (set j (skip-space text after))
            (cond
              (= (get text j) (chr ",")) (++ j)
              (= (get text j) (chr "]")) (do (++ j) (set running false))
              (error "expected ',' or ']' in array")))
          [out j])))

    (string/has-prefix? "true" (string/slice text i)) [true (+ i 4)]
    (string/has-prefix? "false" (string/slice text i)) [false (+ i 5)]
    (string/has-prefix? "null" (string/slice text i)) [nil (+ i 4)]

    # A number: take the longest run that can belong to one and let
    # `scan-number` judge it.
    (do
      (var j i)
      (while (and (< j (length text))
                  (let [d (text j)]
                    (or (and (>= d (chr "0")) (<= d (chr "9")))
                        (= d (chr "-")) (= d (chr "+"))
                        (= d (chr ".")) (= d (chr "e")) (= d (chr "E")))))
        (++ j))
      (def found (scan-number (string/slice text i j)))
      (if (nil? found)
        (errorf "bad JSON at byte %d" i)
        [found j]))))

(defn decode
  "JSON text as Janet data. Objects become tables keyed by string."
  [text]
  (first (read-value (string text) 0)))
