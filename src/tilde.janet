# Making `~` and `#rrggbb` mean what a config author means by them.
#
# The config language is real Janet, which buys loops, defs and helpers for
# free (see src/config.janet). It costs two collisions with Janet's reader,
# both in the notation the Python tools already established and neither
# negotiable -- `(show-only ~)` and `(group ~.Shared #a54a4a)` are what every
# existing config says.
#
#   `~`        Janet reads as (quasiquote ...). A bare `~` with nothing after
#              it does not merely read oddly, it KILLS THE PARSER -- the
#              reader hits end-of-form waiting for something to quote and the
#              parser reports "parser is dead".
#
#   `#a54a4a`  Janet reads as a COMMENT to end of line, so the colour and the
#              closing paren both vanish and the form never terminates.
#
# So the source is rewritten before it is read: the tilde forms become plain
# strings, and a `#rrggbb` becomes the string it obviously is. Both are
# textual substitutions on a character scan that knows about string literals
# and comments, so a `#` inside a real comment stays a comment and a `~`
# inside a string stays a tilde.
#
# THE ALTERNATIVE WAS A DIFFERENT NOTATION -- `(group :Shared "a54a4a")` or
# similar -- and it was rejected because it would break every config file
# these tools already have, to save forty lines here.

(defn- hex-at?
  ``Is there a #rrggbb starting at `i`?

  Exactly six hex digits, and not seven -- `#abcdefg` is a comment that
  happens to start with hex, not a colour with a letter stuck on.``
  [text i]
  (def n (length text))
  (and (< (+ i 6) (+ n 1))
       (= (text i) (chr "#"))
       (do
         (var ok true)
         (for k (+ i 1) (+ i 7)
           (unless (and (< k n)
                        (let [c (text k)]
                          (or (and (>= c (chr "0")) (<= c (chr "9")))
                              (and (>= c (chr "a")) (<= c (chr "f")))
                              (and (>= c (chr "A")) (<= c (chr "F"))))))
             (set ok false)))
         ok)
       # Nothing identifier-ish may follow, or `#abcdef0` would read as a
       # colour plus a stray digit.
       (let [after (+ i 7)]
         (or (>= after n)
             (let [c (text after)]
               (not (or (and (>= c (chr "0")) (<= c (chr "9")))
                        (and (>= c (chr "a")) (<= c (chr "z")))
                        (and (>= c (chr "A")) (<= c (chr "Z")))
                        (= c (chr "_")))))))))

(defn- name-char?
  "Part of a prefix like `~.Otto.Shared`? Dots included, since they separate."
  [c]
  (or (and (>= c (chr "0")) (<= c (chr "9")))
      (and (>= c (chr "a")) (<= c (chr "z")))
      (and (>= c (chr "A")) (<= c (chr "Z")))
      (= c (chr "_")) (= c (chr ".")) (= c (chr "-")) (= c (chr "/"))))

(defn prepare
  ``Rewrite a config's source so Janet's reader sees what the author meant.

  `~`, `~.Foo` and `~.Foo.` become ordinary double-quoted strings, and a bare
  `#rrggbb` becomes one too. Everything else is passed through untouched,
  including strings and comments -- a `#` inside a comment is still a comment
  and a `~` inside a string is still a tilde.

  Returns the rewritten source. Offsets are NOT preserved: a rewritten line is
  longer than the one that produced it. Nothing downstream needs them, because
  errors are reported per LINE and the evaluator rewrites one line at a time.``
  [source]
  (def out @"")
  (def n (length source))
  (var i 0)
  # How deep inside brackets we are, so `;` can be told apart from splice:
  # at top level it starts a comment, inside a form it is Janet's own.
  (var depth 0)
  (while (< i n)
    (def c (source i))
    (case c
      (chr "(") (++ depth)
      (chr "[") (++ depth)
      (chr "{") (++ depth)
      (chr ")") (-- depth)
      (chr "]") (-- depth)
      (chr "}") (-- depth))
    (when (< depth 0) (set depth 0))
    (cond
      # A string literal: copy it whole, escapes and all, so its contents are
      # never rewritten.
      (= c (chr "\""))
      (do
        (buffer/push-byte out c)
        (++ i)
        (while (and (< i n) (not= (source i) (chr "\"")))
          (when (= (source i) (chr "\\"))
            (buffer/push-byte out (source i))
            (++ i))
          (when (< i n)
            (buffer/push-byte out (source i))
            (++ i)))
        (when (< i n) (buffer/push-byte out (source i)) (++ i)))

      # A colour. Checked BEFORE the comment case, since both start with `#`.
      (hex-at? source i)
      (do
        (buffer/push-string out (string "\"" (string/slice source i (+ i 7)) "\""))
        (+= i 7))

      # A real comment: copy to end of line untouched.
      (= c (chr "#"))
      (do
        (while (and (< i n) (not= (source i) (chr "\n")))
          (buffer/push-byte out (source i))
          (++ i)))

      # A LISP COMMENT. Janet comments with `#`, but every config these tools
      # have ever written uses `;` -- it is what the Python reader took, and
      # the starter file and all the existing .al files are full of it. In
      # Janet `;` is splice, so `;; note` reads as a splice of a symbol and
      # produces gibberish rather than nothing.
      #
      # Only at the START of a form, never inside one: a `;` in argument
      # position is a real splice and `(hide ;names)` should keep working.
      (and (= c (chr ";")) (zero? depth))
      (do
        (buffer/push-byte out (chr "#"))
        (++ i)
        (while (and (< i n) (not= (source i) (chr "\n")))
          (buffer/push-byte out (source i))
          (++ i)))

      # A tilde form. `~` alone, or `~` followed by a name.
      (= c (chr "~"))
      (do
        (var j (+ i 1))
        (while (and (< j n) (name-char? (source j))) (++ j))
        (buffer/push-string out (string "\"" (string/slice source i j) "\""))
        (set i j))


      (do (buffer/push-byte out c) (++ i))))
  (string out))
