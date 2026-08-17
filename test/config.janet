# The config language.

(import ../src/config)
(import ../src/color)
(import ./harness :as t)

(defn- run [& lines] (config/run lines))
(defn- state-of [& lines] (first (config/run lines)))

(t/test "hide and show-only collect prefixes"
  (def state (state-of "(hide \"~.Tests\")" "(hide WebKit)" "(show-only \"~\")"))
  (t/is= ["~.Tests" "WebKit"] (state :hidden))
  (t/is= ["~"] (state :only)))

(t/test "saying a thing twice is not an error"
  # Stating an outcome rather than toggling is what makes a config readable:
  # a line means the same thing wherever it sits, and re-running the file
  # cannot land you in the opposite state.
  (def state (state-of "(hide \"~.Tests\")" "(hide \"~.Tests\")"))
  (t/is= ["~.Tests"] (state :hidden)))

(t/test "flags are set, never flipped"
  (def state (state-of "(show-lines)" "(show-lines)" "(fill-color)"))
  (t/ok (state :sized))
  (t/ok (state :filled))
  (t/ok (not (state :sized-coloring))))

(t/test "show-lines-coloring implies the numbers"
  # A colour ramp with nothing to read it against is a picture you cannot check.
  (def state (state-of "(show-lines-coloring)"))
  (t/ok (state :sized))
  (t/ok (state :sized-coloring)))

(t/test "groups take the palette in order and never repeat"
  (def state (state-of "(group \"~.A\")" "(group \"~.B\")" "(group \"~.C\")"))
  (def hues (map |($ :color) (state :groups)))
  (t/is= 3 (length (distinct hues)))
  (t/ok (not (index-of color/ungrouped hues))
        "no group may wear the colour ungrouped nodes already have"))

(t/test "an explicit colour wins and the automatic ones move around it"
  # (group ~.a) (group ~.b red) where ~.a already drew red: the named colour
  # keeps it and ~.a is reassigned, so the boxes stay distinguishable.
  (def state (state-of "(group \"~.A\")" "(group \"~.B\" red)"))
  (def by-prefix (table ;(mapcat |[($ :prefix) ($ :color)] (state :groups))))
  (t/is= "#ff4d6d" (by-prefix "~.B"))
  (t/ok (not= "#ff4d6d" (by-prefix "~.A"))))

(t/test "regrouping a prefix recolours rather than duplicating"
  (def state (state-of "(group \"~.A\")" "(group \"~.A\" blue)"))
  (t/is= 1 (length (state :groups)))
  (t/is= "#22a6f2" (((state :groups) 0) :color)))

(t/test "a bad colour complains on its own line and the rest still runs"
  (def [state problems] (run "(group \"~.A\" nonsense)" "(hide \"~.B\")"))
  (t/ok (problems 0) "the bad line is reported")
  (t/ok (string/find "not a colour" (problems 0)))
  (t/is= ["~.B"] (state :hidden) "the good line still took effect")
  (t/ok (not (problems 1))))

(t/test "the ungrouped colour is refused as a group colour"
  # The box would be the same colour as every ungrouped node and say nothing.
  (def [_ problems] (run (string "(group \"~.A\" \"" color/ungrouped "\")")))
  (t/ok (problems 0))
  (t/ok (string/find "invisible" (problems 0))))

(t/test "an unknown verb is reported, not fatal"
  (def [state problems] (run "(explode \"~.A\")" "(hide \"~.B\")"))
  (t/ok (problems 0))
  (t/is= ["~.B"] (state :hidden)))

(t/test "a blank line and a comment do nothing at all"
  (def [state problems] (run "" "   " "# just a note" "# also a note"))
  (t/is= @{} problems)
  (t/is= [] (state :hidden)))

(t/test "a bare name is a literal, as it was in the Python reader"
  # `(group SwiftUI)` grouped the framework and `(group ~.A red)` named a
  # colour -- neither was ever a variable. Janet would call both unknown
  # symbols, so the evaluator resolves an unbound name to itself.
  (t/is= ["WebKit"] ((state-of "(hide WebKit)") :hidden))
  (t/is= ["SwiftUI" "WebKit"]
         (map |($ :prefix) ((state-of "(group SwiftUI) (group WebKit)") :groups))))

(t/test "REAL JANET: the thing the flat reader could never do"
  # This is why the config is Janet rather than a hand-written dialect.
  (def state (state-of `(each n ["A" "B" "C"] (group (string "~." n)))`))
  (t/is= ["~.A" "~.B" "~.C"] (map |($ :prefix) (state :groups))))

(t/test "a bound name stays a variable, an unbound one becomes a literal"
  # The two rules meet here, and getting it wrong is silent either way: a
  # loop variable turned into a string would hide a file called "f".
  (t/is= ["SwiftUI" "WebKit"]
         ((state-of `(each f ["SwiftUI" "WebKit"] (hide ,f))`) :hidden)
         "the loop variable resolves rather than being taken literally")
  (t/is= ["~.X"]
         ((state-of `(do (def mine "~.X") (hide ,mine))`) :hidden)
         "a def binds for the rest of the body")
  (t/is= ["WebKit"]
         ((state-of "(when true (hide WebKit))") :hidden)
         "a bare name inside a body is still a literal"))

(t/test "a config is Janet, and can compute"
  # The verbs are macros, so a bare name is a name -- but a config that wants
  # a VARIABLE's value unquotes it, which is Janet's own notation for "not
  # the symbol, the thing". Both halves matter: without the first a config is
  # full of quotes, and without the second a loop cannot drive a verb.
  (t/is= ["SwiftUI" "WebKit"]
         ((state-of `(each f ["SwiftUI" "WebKit"] (hide ,f))`) :hidden)
         "a loop variable reaches the verb through an unquote")
  (t/is= ["~.X"] ((state-of `(do (def mine "~.X") (hide ,mine))`) :hidden)
         "so does a def")
  (t/is= ["web"] ((state-of "(hide web)") :hidden)
         "and a bare name is still just its own name"))

(t/test "a config can reach the whole language"
  # THE SANDBOX IS GONE, and this pins the decision rather than mourning it.
  # The verbs used to live in a hand-built environment with fifty whitelisted
  # builtins and no os, file or net -- because a config is edited through a
  # web page. It is now evaluated in this module's own environment, so a
  # config can call anything Janet can. The trade was made deliberately: the
  # server binds to 127.0.0.1, and the alternative was two hundred lines of
  # environment-building and symbol-rewriting.
  (t/ok (not ((last (run "(string \"a\" \"b\")")) 0))
        "an ordinary function call is not an error")
  (t/ok (not ((last (run "(os/time)")) 0))
        "and neither is one that reaches the machine"))

(t/test "the notations Janet's reader steals are refused, not misread"
  # `~` begins a quasiquote and `#` begins a comment, so these forms read as
  # something other than what they say. They used to work -- src/tilde.janet
  # rewrote the source first -- and when it was deleted they began producing
  # plausible wrong answers in silence: (hide ~.A) hid ".A", and a #rrggbb
  # colour vanished into a comment leaving the group uncoloured. Refusing
  # them is the whole point of this test.
  (def [_ bare] (run "(show-only ~)"))
  (t/ok (bare 0) "a bare ~ is refused")
  (def [_ dotted] (run "(hide ~.A)"))
  (t/ok (dotted 0) "so is ~.A, which would otherwise hide \".A\"")
  (t/ok (string/find "quasiquote" (dotted 0)) "and the message says why")
  (def [_ hashed] (run "(group web #22a6f2)"))
  (t/ok (hashed 0) "a bare #rrggbb is refused")
  (t/ok (string/find "comment" (hashed 0)) "and the message says why")
  # The quoted spellings are the supported ones and must still work.
  (def [state clean] (run "(hide \"~.A\")" "(group web \"#22a6f2\")"))
  (t/ok (not (clean 0)) "quoted forms are fine")
  (t/ok (not (clean 1)))
  (t/is= ["~.A"] (state :hidden)))
