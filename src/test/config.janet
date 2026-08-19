# The config language.

(import ../visualize/config)
(import ../visualize/color)
(import ./harness :as t)

(defn- run [& lines] (config/run lines))
(defn- state-of [& lines] (first (config/run lines)))

(t/test "hide and only collect prefixes"
  (def state (state-of "(hide src.test)" "(hide WebKit)" "(only \"\")"))
  (t/is= ["src.test" "WebKit"] (state :hidden))
  (t/is= [""] (state :only) "the empty prefix is everything of ours"))

(t/test "saying a thing twice is not an error"
  # Stating an outcome rather than toggling is what makes a config readable:
  # a line means the same thing wherever it sits, and re-running the file
  # cannot land you in the opposite state.
  (def state (state-of "(hide \"~.Tests\")" "(hide \"~.Tests\")"))
  (t/is= ["~.Tests"] (state :hidden)))

(t/test "flags are set, never flipped"
  (def state (state-of "(lines)" "(lines)"))
  (t/ok (state :sized)))

(t/test "groups take the palette in order and never repeat"
  (def state (state-of "(box \"~.A\")" "(box \"~.B\")" "(box \"~.C\")"))
  (def hues (map |($ :color) (state :groups)))
  (t/is= 3 (length (distinct hues)))
  (t/ok (not (index-of color/ungrouped hues))
        "no group may wear the colour ungrouped nodes already have"))

(t/test "an explicit colour wins and the automatic ones move around it"
  # (box ~.a) (box ~.b red) where ~.a already drew red: the named colour
  # keeps it and ~.a is reassigned, so the boxes stay distinguishable.
  (def state (state-of "(box \"~.A\")" "(box \"~.B\" red)"))
  (def by-prefix (table ;(mapcat |[($ :prefix) ($ :color)] (state :groups))))
  (t/is= "#ff4d6d" (by-prefix "~.B"))
  (t/ok (not= "#ff4d6d" (by-prefix "~.A"))))

(t/test "regrouping a prefix recolours rather than duplicating"
  (def state (state-of "(box \"~.A\")" "(box \"~.A\" blue)"))
  (t/is= 1 (length (state :groups)))
  (t/is= "#22a6f2" (((state :groups) 0) :color)))

(t/test "a bad colour complains on its own line and the rest still runs"
  (def [state problems] (run "(box \"~.A\" nonsense)" "(hide \"~.B\")"))
  (t/ok (problems 0) "the bad line is reported")
  (t/ok (string/find "not a colour" (problems 0)))
  (t/is= ["~.B"] (state :hidden) "the good line still took effect")
  (t/ok (not (problems 1))))

(t/test "the ungrouped colour is refused as a group colour"
  # The box would be the same colour as every ungrouped node and say nothing.
  # Written bare, since a hash would comment the line out before it could be
  # refused for being the wrong colour.
  (def bare (string/replace "#" "" color/ungrouped))
  (def [_ problems] (run (string "(box \"~.A\" " bare ")")))
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

(t/test "a bare name is a literal, and quoting is for awkward ones"
  # A config is mostly names, so quoting every one of them would be noise.
  # Quotes exist for a name with a space in it, not as the normal case.
  (t/is= ["src.visualize"] ((state-of "(hide src.visualize)") :hidden))
  (t/is= ["src.visualize"] ((state-of `(hide "src.visualize")`) :hidden))
  (t/is= ["a name with spaces"] ((state-of `(hide "a name with spaces")`) :hidden))
  (t/is= ["src.test"] ((state-of "(hide src/test)") :hidden)
         "a slash is taken too, since a path is a natural thing to type"))

(t/test "a hex colour is written bare, because a hash starts a comment"
  # SIX HEX DIGITS, no hash. `#` is the comment character wherever it
  # appears, so a colour cannot spell itself with one -- and the stored form
  # gains the hash because that is what SVG wants.
  (t/is= "#22a6f2" (get-in (state-of "(box web 22a6f2)") [:groups 0 :color]))
  (t/is= "#ff4d6d" (get-in (state-of "(box web red)") [:groups 0 :color]))
  # A hash in the colour position comments the rest of the line out, which
  # takes the closing parenthesis with it -- so the line is unclosed, and
  # that is what it is told.
  (def [state problems] (run "(box web #22a6f2)"))
  (t/is= [] (state :groups) "nothing was grouped")
  (t/ok (string/find "parenthesis" (problems 0)))
  # Quoted is refused too: the reader keeps the hash, and it is not a colour.
  (def [_ quoted] (run `(box web "#22a6f2")`))
  (t/ok (string/find "not a colour" (quoted 0)))
  # Something in the colour position that is neither is refused, rather than
  # silently drawing the group in the next palette hue.
  (def [_ bad] (run "(box web nonsense)"))
  (t/ok (bad 0)))

(t/test "a comment is a line that does nothing, wherever it sits"
  (def [state problems] (run "# just a note" "   " "(hide src.test) # and why"))
  (t/is= {} (table ;(kvs problems)) "none of the three is a complaint")
  (t/is= ["src.test"] (state :hidden) "and the form still ran"))

(t/test "the language cannot say anything but its own verbs"
  # THE POINT OF A GRAMMAR. This used to be a Janet environment -- first a
  # sandbox of whitelisted builtins, then the whole language -- and either
  # way the config inherited every feature Janet grew. Now the forms are
  # written out in one place and nothing else parses, so a config edited
  # through a web page cannot reach the machine because there is no way to
  # SAY it, not because a list said no.
  (each forbidden ["(os/shell \"echo hi\")"
                   "(file/open \"/tmp/x\" :w)"
                   "(slurp \"/etc/passwd\")"
                   "(each f [1 2] (hide f))"
                   "(def home \"src\")"]
    (def [_ problems] (run forbidden))
    (t/ok (problems 0) (string forbidden " must not be a config form")))
  # `(hide ,home)` is NOT on that list. A comma is an ordinary character in
  # a name now, so that line hides a node called `,home` -- it does not
  # splice anything, because there is nothing to splice with.
  (def [state clean] (run "(hide ,home)"))
  (t/is= @{} clean)
  (t/is= [",home"] (state :hidden)))

(t/test "a refusal says what to write instead"
  (def [_ unknown] (run "(explode src)"))
  (t/ok (string/find "no verb" (unknown 0)))
  (t/ok (string/find "box" (unknown 0)) "and lists the ones there are")
  (def [_ badargs] (run "(hide)"))
  (t/ok (badargs 0) "a verb without its argument is refused")
  (def [_ unclosed] (run "(hide src.test"))
  (t/ok (string/find "parenthesis" (unclosed 0)))
  (def [_ naked] (run "hide src.test"))
  (t/ok (string/find "parentheses" (naked 0))))

(t/test "a prefix binds a token to a path"
  (def state (state-of "(prefix ~ src.visualize)"))
  (t/is= [{:alias "~" :prefix "src.visualize"}] (state :aliases))
  # Any token will do -- an alias is a spelling, not a name.
  (t/is= "@" (get-in (state-of "(prefix @ src)") [:aliases 0 :alias]))
  (t/is= "lib" (get-in (state-of "(prefix lib deps.vendor)") [:aliases 0 :alias])))

(t/test "a bound prefix expands in later names"
  (def state (state-of "(prefix ~ src.visualize)" "(hide ~.color)" "(only ~)"))
  (t/is= ["src.visualize.color"] (state :hidden))
  (t/is= ["src.visualize"] (state :only))
  # Groups too, and the colour survives the expansion.
  (def grouped (state-of "(prefix ~ src)" "(box ~.test 22a6f2)"))
  (t/is= "src.test" (get-in grouped [:groups 0 :prefix]))
  (t/is= "#22a6f2" (get-in grouped [:groups 0 :color])))

(t/test "the longest alias wins"
  # `~` is a prefix of `~~`, so a name starting `~~` must not be read as `~`
  # followed by the rest. Most specific first, and for prefixes that is
  # longest first -- however the two were declared.
  (def state (state-of "(prefix ~ src)" "(prefix ~~ src.visualize)"
                       "(hide ~.test)" "(hide ~~.color)"))
  (t/is= ["src.test" "src.visualize.color"] (state :hidden))
  (def other (state-of "(prefix ~~ src.visualize)" "(prefix ~ src)"
                       "(hide ~~.color)"))
  (t/is= ["src.visualize.color"] (other :hidden)))

(t/test "rebinding a token is refused"
  # A config is read top to bottom, so a second binding would quietly change
  # what the lines above it meant.
  (def [state problems] (run "(prefix ~ src)" "(prefix ~ test)" "(hide ~.a)"))
  (t/ok (string/find "already bound" (problems 1)))
  (t/is= 1 (length (state :aliases)))
  (t/is= ["src.a"] (state :hidden) "the first binding stands"))

(t/test "a token substitutes only at the head"
  # `prefix` means prefix: the token is the head of the name and the rest is
  # ordinary characters, whatever they are. With `~` bound to src.config,
  # `~~.something` is src.config followed by `~.something`.
  (def state (state-of "(prefix ~ src.config)" "(box ~~.something)"))
  (t/is= "src.config~.something" (get-in state [:groups 0 :prefix]))
  # Not in the middle, and not at the end.
  (t/is= ["a.~.b"] ((state-of "(prefix ~ src)" "(hide a.~.b)") :hidden)))

(t/test "any token at all can be a prefix"
  # Nothing is excluded. The grammar ends a token at whitespace, parens and
  # quotes because it has to end somewhere; everything else is fair.
  (each token [",x" "`q" "@" "%%" "!" "->"]
    (def [state problems] (run (string "(prefix " token " src)")
                               (string "(hide " token ".a)")))
    (t/is= @{} problems (string token " must bind"))
    (t/is= ["src.a"] (state :hidden) (string token " must substitute"))))

(t/test "an unbound token is just a name"
  # No error: a token nothing bound selects nothing, which is what a
  # misspelled path does as well.
  (t/is= ["~.color"] ((state-of "(hide ~.color)") :hidden)))

(t/test "a prefix shortens the labels it covers"
  (def aliases [{:alias "~" :prefix "src.visualize"}])
  (t/is= "~.color" (config/alias-label aliases "src.visualize.color"))
  (t/is= "~" (config/alias-label aliases "src.visualize") "the path itself")
  (t/is= nil (config/alias-label aliases "src.test") "an unrelated node")
  # A DOT BOUNDARY, not a character one: `src.visualizer` merely starts with
  # the same letters and keeps its own name.
  (t/is= nil (config/alias-label aliases "src.visualizer.x"))
  # Longest first here too, so the alias that covers most shortens most.
  (def two [{:alias "~~" :prefix "src.visualize"} {:alias "~" :prefix "src"}])
  (t/is= "~~.color" (config/alias-label two "src.visualize.color"))
  (t/is= "~.test" (config/alias-label two "src.test")))

(t/test "a prefix without both halves is refused"
  (def [_ p1] (run "(prefix ~)"))
  (t/ok (p1 0) "a token with nothing to stand for")
  (def [_ p2] (run "(prefix)"))
  (t/ok (p2 0) "neither half"))

(t/test "the docs are generated from the grammar"
  # THE POINT of the verb table: help that cannot describe a verb the parser
  # does not have, or miss one it does. Asserted as a set equality rather
  # than a fixed list, so adding a verb does not have to touch this test --
  # which is the same property the table itself is for.
  (def documented (map |($ :name) (config/docs)))
  (each name documented
    (def [_ problems] (run (string "(" name " src.a x)")))
    # It parses as SOMETHING -- either cleanly, or with an argument
    # complaint. What it must never be is "there is no verb".
    (when (problems 0)
      (t/ok (not (string/find "there is no verb" (problems 0)))
            (string name " is documented, so it must exist"))))
  # And every verb the parser knows is documented: an undocumented verb is
  # invisible to anyone reading the help.
  (def [_ unknown] (run "(no-such-verb x)"))
  (each name documented
    (t/ok (string/find name (unknown 0))
          (string name " must be offered when a verb is misspelled"))))

(t/test "a usage line comes from the arguments the parser takes"
  (def by-name (tabseq [d :in (config/docs)] (d :name) d))
  (t/is= "(prefix name p)" (get-in by-name ["prefix" :usage]))
  (t/is= "(box p color?)" (get-in by-name ["box" :usage])
         "the optional colour is marked")
  (t/is= "(lines)" (get-in by-name ["lines" :usage])
         "a verb with no arguments")
  # Every verb documented must carry a blurb -- a usage line alone says the
  # shape and not the meaning.
  (each d (config/docs)
    (t/ok (and (d :blurb) (not (empty? (d :blurb))))
          (string (d :name) " must say what it does"))))

(t/test "a verb whose name starts with another still parses"
  # A PEG takes the first alternative that matches, so the rules are built
  # longest name first: with `lines` ahead of a hypothetical `lines-by-size`,
  # the longer verb would match the shorter rule and leave the rest of the
  # line unparsed. No pair in the table shares a head today -- this asserts
  # the ORDERING that makes adding one safe, since the trap is invisible
  # until the day someone does.
  (def names (map |($ :name) (config/docs)))
  (each name names
    (each other names
      (when (and (not= name other) (string/has-prefix? name other))
        (t/ok (< (index-of other names) (index-of name names))
              (string other " must be tried before " name)))))
  # And the whole table still parses, which is what the ordering protects.
  (each d (config/docs)
    (def [_ problems] (run (string "(" (d :name) " a b)")))
    (when (problems 0)
      (t/ok (not (string/find "there is no verb" (problems 0)))
            (string (d :name) " must be reachable")))))

(t/test "a prefix binds before any line that uses it"
  # WHERE IT SITS DOES NOT CHANGE WHAT THE FILE MEANS. A prefix declared at
  # the foot of the file used to bind after every line above it had already
  # matched, so (hide ~.color) hid a node literally called `~.color` --
  # silently, because an unbound token is a name like any other.
  (def below (state-of "(hide ~.color)" "(prefix ~ src.visualize)"))
  (t/is= ["src.visualize.color"] (below :hidden))
  (def above (state-of "(prefix ~ src.visualize)" "(hide ~.color)"))
  (t/is= (above :hidden) (below :hidden) "the same file either way round")
  # Selected by verb, not by line: a line may hold several forms, and the
  # binding on it has to land before the use beside it.
  (def together (state-of "(hide ~.a)" "(prefix ~ src) (hide ~.b)"))
  (t/is= ["src.a" "src.b"] (together :hidden)))

(t/test "two passes do not double-report a line"
  (def [_ bad] (run "(prefix ~)"))
  (t/is= 1 (length bad) "a bad prefix line complains once")
  # The rebinding complaint still lands on the second prefix, not the first.
  (def [state rebound] (run "(prefix ~ src)" "(prefix ~ test)" "(hide ~.a)"))
  (t/ok (string/find "already bound" (rebound 1)))
  (t/is= nil (rebound 0))
  (t/is= ["src.a"] (state :hidden)))

(t/test "the file still reads top to bottom within a pass"
  # Only `prefix` is hoisted. Everything else keeps its order, which is what
  # group needs for its colours.
  (def state (state-of "(box a)" "(prefix ~ src)" "(box b)"))
  (t/is= ["a" "b"] (map |($ :prefix) (state :groups))))
