# The config language, and the source rewriting that makes it readable.

(import ../src/config)
(import ../src/tilde)
(import ../src/color)
(import ./harness :as t)

(defn- run [& lines] (config/run lines))
(defn- state-of [& lines] (first (config/run lines)))

(t/test "the reader survives the notation the Python tools established"
  # Each of these is a Janet reader collision, and each one appears in real
  # config files. See src/tilde.janet.
  (t/is= `(show-only "~")` (tilde/prepare "(show-only ~)")
         "a bare ~ would otherwise kill the parser outright")
  (t/is= `(hide "~.OttoClip")` (tilde/prepare "(hide ~.OttoClip)"))
  (t/is= `(group "~.Shared" "#a54a4a")` (tilde/prepare "(group ~.Shared #a54a4a)")
         "#rrggbb would otherwise be a comment to end of line")
  (t/is= `(hide "~.Otto.")` (tilde/prepare "(hide ~.Otto.)")
         "a trailing dot is meaningful and must survive"))

(t/test "rewriting leaves strings and comments alone"
  (t/is= `(hide "~.literal")` (tilde/prepare `(hide "~.literal")`)
         "a tilde already inside a string is not rewritten twice")
  (t/is= "# a note with #hash" (tilde/prepare "# a note with #hash"))
  (t/is= "#; note about ~ and #abc" (tilde/prepare ";; note about ~ and #abc")
         "a ; comment becomes a # comment rather than a splice")
  (t/is= `(hide "~.A") #; trailing` (tilde/prepare "(hide ~.A) ;; trailing")))

(t/test "hide and show-only collect prefixes"
  (def state (state-of "(hide ~.Tests)" "(hide WebKit)" "(show-only ~)"))
  (t/is= ["~.Tests" "WebKit"] (state :hidden))
  (t/is= ["~"] (state :only)))

(t/test "saying a thing twice is not an error"
  # Stating an outcome rather than toggling is what makes a config readable:
  # a line means the same thing wherever it sits, and re-running the file
  # cannot land you in the opposite state.
  (def state (state-of "(hide ~.Tests)" "(hide ~.Tests)"))
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
  (def state (state-of "(group ~.A)" "(group ~.B)" "(group ~.C)"))
  (def hues (map |($ :color) (state :groups)))
  (t/is= 3 (length (distinct hues)))
  (t/ok (not (index-of color/ungrouped hues))
        "no group may wear the colour ungrouped nodes already have"))

(t/test "an explicit colour wins and the automatic ones move around it"
  # (group ~.a) (group ~.b red) where ~.a already drew red: the named colour
  # keeps it and ~.a is reassigned, so the boxes stay distinguishable.
  (def state (state-of "(group ~.A)" "(group ~.B red)"))
  (def by-prefix (table ;(mapcat |[($ :prefix) ($ :color)] (state :groups))))
  (t/is= "#ff4d6d" (by-prefix "~.B"))
  (t/ok (not= "#ff4d6d" (by-prefix "~.A"))))

(t/test "regrouping a prefix recolours rather than duplicating"
  (def state (state-of "(group ~.A)" "(group ~.A blue)"))
  (t/is= 1 (length (state :groups)))
  (t/is= "#22a6f2" (((state :groups) 0) :color)))

(t/test "a bad colour complains on its own line and the rest still runs"
  (def [state problems] (run "(group ~.A nonsense)" "(hide ~.B)"))
  (t/ok (problems 0) "the bad line is reported")
  (t/ok (string/find "not a colour" (problems 0)))
  (t/is= ["~.B"] (state :hidden) "the good line still took effect")
  (t/ok (not (problems 1))))

(t/test "the ungrouped colour is refused as a group colour"
  # The box would be the same colour as every ungrouped node and say nothing.
  (def [_ problems] (run (string "(group ~.A " color/ungrouped ")")))
  (t/ok (problems 0))
  (t/ok (string/find "invisible" (problems 0))))

(t/test "an unknown verb is reported, not fatal"
  (def [state problems] (run "(explode ~.A)" "(hide ~.B)"))
  (t/ok (problems 0))
  (t/is= ["~.B"] (state :hidden)))

(t/test "a blank line and a comment do nothing at all"
  (def [state problems] (run "" "   " ";; just a note" "# also a note"))
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
         ((state-of `(each f ["SwiftUI" "WebKit"] (hide f))`) :hidden)
         "the loop variable resolves rather than being taken literally")
  (t/is= ["~.X"]
         ((state-of `(do (def mine "~.X") (hide mine))`) :hidden)
         "a def binds for the rest of the body")
  (t/is= ["WebKit"]
         ((state-of "(when true (hide WebKit))") :hidden)
         "a bare name inside a body is still a literal"))

(t/test "the sandbox has no way to reach the machine"
  # A config is edited through a web page. The blast radius of a typo there
  # should be a wrong-looking graph, not a deleted directory.
  (each forbidden ["(os/shell \"echo hi\")"
                   "(file/open \"/tmp/x\" :w)"
                   "(slurp \"/etc/passwd\")"
                   "(net/connect \"127.0.0.1\" \"80\")"
                   "(import ./src/config)"]
    (def [_ problems] (run forbidden))
    (t/ok (problems 0) (string forbidden " must not be available"))))
