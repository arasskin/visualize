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

(t/test "animate asks for the flash"
  (t/ok ((state-of "(animate)") :animated))
  (t/ok (not ((state-of "(lines)") :animated))
        "and nothing else turns it on"))

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
  (t/ok (badargs 0) "a verb without its argument is refused"))

(t/test "a complaint names the form that failed, not the first one"
  # A line holds as many forms as you like, and the compose bar writes more
  # than one whenever it appends to a selected line: type `hide` with a box
  # line picked and the line becomes `(box src.web) (hide)`. Reading the verb
  # off the FRONT of the line reported `box` for a mistake in `hide`.
  (defn about [line] (((run line) 1) 0))

  (t/ok (string/find "`hide`" (about "(box src.web) (hide)"))
        "the broken form is named")
  (t/ok (not (string/find "`box`" (about "(box src.web) (hide)")))
        "and the one before it is not")

  (t/ok (string/find "wobble" (about "(lines) (wobble x)")))
  (t/ok (string/find "`lines`" (about "(box a red) (lines extra)")))

  # A line that fails as a WHOLE has no single form to blame, and still says
  # the useful thing.
  (t/ok (string/find "parenthesis" (about "(hide src.test")))
  (t/ok (string/find "parentheses" (about "hide src.test"))))

(t/test "an arity complaint shows THAT verb's shape"
  # One canned sentence used to serve every verb, and it ended "and a colour
  # is rrggbb or a name" -- so `(lines extra)` complained about a colour it
  # does not take, and every arity error read like a box error.
  (defn about [line] (((run line) 1) 0))

  (t/ok (string/find "(hide p)" (about "(hide)"))
        "hide is shown taking a prefix")
  (t/ok (not (string/find "colour" (about "(hide)")))
        "and no colour, which it does not take")

  (t/ok (string/find "(lines)" (about "(lines extra)")))
  (t/ok (string/find "nothing else" (about "(lines extra)"))
        "a verb with no arguments says so")

  (t/ok (string/find "(prefix name p)" (about "(prefix ~)"))
        "prefix is shown taking both of its arguments")

  # box is the one verb the old message was accidentally right about.
  (t/ok (string/find "(box p color?)" (about "(box)")))
  (t/ok (string/find "colour" (about "(box)"))
        "and it alone mentions a colour")
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

(t/test "the docs carry each argument's kind"
  # THE EDITOR COMPLETES BY KIND, not by position: a second argument to `box`
  # is a colour and a second argument to `hide` is nothing at all. That is
  # decided by this table and shipped to the page, so the completion follows
  # the grammar rather than a copy of it written in JavaScript.
  (def by-name (tabseq [d :in (config/docs)] (d :name) d))
  (t/is= ["name" "color?"] (get-in by-name ["box" :args]))
  (t/is= ["name"] (get-in by-name ["hide" :args]) "no second slot to fill")
  (t/is= ["alias" "name"] (get-in by-name ["prefix" :args]))
  (t/is= [] (get-in by-name ["lines" :args]))
  # Strings, since this crosses into JSON.
  (each d (config/docs)
    (each a (d :args) (t/ok (string? a) (string (d :name) "'s args are strings"))))

  # The colours the editor offers are the ones the parser accepts.
  (def named (config/colours))
  (t/ok (index-of "blue" named))
  (each colour named
    (t/ok (not (nil? (color/as-hex colour)))
          (string colour " must be a colour the config accepts"))))

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

(def- scratch "/tmp/visualize-config-file-test.conf")

(t/test "reading a config gives one entry per written line"
  # A trailing newline is one empty string on the end, and it is dropped --
  # it is how a text file ends, not a line someone wrote.
  (spit scratch "(lines)\n(hide src.test)\n")
  (t/is= ["(lines)" "(hide src.test)"] (config/read-config scratch))
  (spit scratch "(lines)")
  (t/is= ["(lines)"] (config/read-config scratch)
         "a file with no trailing newline reads the same"))

(t/test "a config round trips unchanged"
  (spit scratch "(lines)\n(hide src.test)\n")
  (def lines (config/read-config scratch))
  (config/write-config scratch lines)
  (t/is= lines (config/read-config scratch))
  (t/is= "(lines)\n(hide src.test)\n" (string (slurp scratch))
         "and the file is the lines, newline-terminated"))

(t/test "the editor's actions are the ones the page can send"
  (t/is= ["a" "b"] (config/edit ["a" "b"] "run" -1))
  (t/is= ["b"] (config/edit ["a" "b"] "delete" 0))
  (t/is= ["a" "b"] (config/edit ["a" "b"] "delete" 9)
         "an index off the end deletes nothing")
  (t/is= ["a" "" "b"] (config/edit ["a" "b"] "insert-above" 1))
  (t/is= ["a" "" "b"] (config/edit ["a" "b"] "insert-below" 0))
  (t/is= [""] (config/edit [] "insert-below" -1)
         "the first line of an empty file"))

(os/rm scratch)

(t/test "visualize keeps its own notes in the config file"
  # A LINE THAT BEGINS `@visualize` IS THE PROGRAM'S, not yours: it records
  # what the last run had open so a crash does not strand a live session
  # behind a socket nobody remembers.
  (t/ok (config/note? "@visualize terminal 3 socket /tmp/a.sock"))
  (t/ok (config/note? "   @visualize terminal 3 socket /tmp/a.sock")
        "leading space is still a note")
  (t/ok (not (config/note? "(hide src)")))
  (t/ok (not (config/note? "# @visualize in a comment is a comment")))

  (def lines ["(lines)" "@visualize terminal 3 socket /tmp/a.sock" "(box src)"])
  (t/is= [["3" "/tmp/a.sock"]] (config/terminals lines))

  # WHAT THE EDITOR IS SHOWN, at every point it is shown anything. The page
  # load stripped the notes and the edit reply did not, so the first delete
  # handed the browser a list with a note in it: the note appeared as an
  # editable row, and every index after that pointed one line off what had
  # been clicked. The two answers have to be the same answer.
  (def shown (filter |(not (config/note? $)) lines))
  (t/is= ["(lines)" "(box src)"] shown
         "a note is never a row the editor shows")
  # And an edit made against that shorter list still lands on the right line.
  (t/is= ["(lines)"] (config/edit shown "delete" 1)
         "an index from the editor means the line the editor showed")

  # A NOTE IS NOT A CONFIG LINE, so the parser passes over it in silence --
  # complaining that one is not a call would be complaining about a line
  # nobody typed.
  (def [_ problems] (config/run lines))
  (t/is= @{} problems "a note draws no complaint"))

(t/test "notes are rewritten whole, never appended to"
  # They are a record of what is open NOW: a pane that has gone has to leave
  # the file, so the set is replaced rather than added to.
  (def lines ["(lines)" "@visualize terminal 3 socket /tmp/old.sock"])
  (def after (config/remember-terminals lines [["4" "/tmp/new.sock"]]))
  (t/is= [["4" "/tmp/new.sock"]] (config/terminals after))
  (t/ok (not (find |(string/find "old.sock" $) after))
        "the pane that went is gone from the file")

  # THE CONFIG IS UNTOUCHED, in its order -- the blank between it and the
  # notes is the separator, which belongs to them.
  (t/is= ["(lines)"]
         (filter |(and (not (config/note? $)) (not (empty? (string/trim $)))) after))

  # NOTHING OPEN, NOTHING WRITTEN -- and the separator goes with them, or
  # opening and closing panes would leave a blank line behind every round.
  (t/is= ["(lines)"] (config/remember-terminals lines []))
  (t/is= ["(lines)"] (config/remember-terminals after [])
         "including the blank it added on the way in")

  # Round trip: what is written is what is read back.
  (def pairs [["harness" "/tmp/h.sock"] ["2" "/tmp/2.sock"]])
  (t/is= pairs (config/terminals (config/remember-terminals [] pairs))))

(t/test "a nested project is drawn by its own config"
  # A directory of this test's own, so nothing here depends on the repo.
  (def root (string (os/getenv "TMPDIR") "vz-nest-" (string (os/time))))
  (os/mkdir root)
  (os/mkdir (string root "/lib"))
  # THE NAMES A NESTED CONFIG PREFIXES ARE THE ONES ITS PROJECT HOLDS, so
  # the fixture has to hold them: `vendor` and `helper` are lib's own, and
  # a name it does not have is a name it only refers to. See `holds?`.
  (os/mkdir (string root "/lib/vendor"))
  (spit (string root "/lib/helper.py") "x = 1\n")
  (defn conf [dir text] (spit (string root dir "/visualize.conf") text))

  (conf "/lib" "(box vendor)\n(fold vendor)\n")
  (def [state problems] (config/run @["(visualize lib)"] root))
  (t/is= @{} problems)
  # THE CHILD'S NAMES WEAR THE CHILD'S PATH. `vendor` in lib's own config is
  # `lib.vendor` in the drawing that contains it.
  (t/is= ["lib.vendor"] (map |($ :prefix) (state :groups)))
  (t/is= ["lib.vendor"] (state :folded))

  # A VERB THAT NAMES NOTHING IS A WHOLE-DRAWING DECISION, and a subproject
  # does not get to make it for the graph it sits in.
  (conf "/lib" "(lines)\n(animate)\n(box vendor)\n")
  (def [s2 _] (config/run @["(visualize lib)"] root))
  (t/ok (not (s2 :sized)) "a nested (lines) does not size the parent")
  (t/ok (not (s2 :animated)) "a nested (animate) does not animate the parent")
  (t/is= ["lib.vendor"] (map |($ :prefix) (s2 :groups)))

  # ONLY THE NAME SLOTS MOVE. A colour is not a node name and must survive
  # untouched; an alias is not one either, and binding one in a child would
  # leak a token into the parent's namespace.
  # `q` rather than a letter `vendor` starts with: with `v` bound, the name
  # `vendor` expands to `vendorendor`, which is what a PREFIX alias means and
  # is true of a parent config too. Not the thing under test here.
  (conf "/lib" "(box vendor red)\n(prefix q other)\n")
  (def [s3 _] (config/run @["(visualize lib)"] root))
  (t/is= [["lib.vendor" "#ff4d6d"]] (map |[($ :prefix) ($ :color)] (s3 :groups)))
  (t/is= [] (s3 :aliases) "a child's alias does not reach the parent")

  # AN ALIAS IS INLINED, NOT DROPPED. The binding cannot travel -- its token
  # would land in the parent's namespace -- but the names that USE it have to
  # keep meaning what the child said. Dropping the binding alone left
  # `(box v)` arriving as `lib.v`, matching nothing and silently doing
  # nothing.
  (conf "/lib" "(prefix v vendor)\n(box v)\n(fold v.deep)\n(hide v)\n")
  (def [s8 _] (config/run @["(visualize lib)"] root))
  (t/is= ["lib.vendor"] (map |($ :prefix) (s8 :groups)))
  (t/is= ["lib.vendor.deep"] (s8 :folded) "an alias at the head of a longer name")
  (t/is= ["lib.vendor"] (s8 :hidden) "the bare token is the path itself")

  # BOUND BELOW WHAT USES IT, which is legal in a config and stays legal in a
  # nested one: the bindings are read in a pass of their own first, exactly
  # as `run` does it.
  (conf "/lib" "(box v)\n(prefix v vendor)\n")
  (def [s9 _] (config/run @["(visualize lib)"] root))
  (t/is= ["lib.vendor"] (map |($ :prefix) (s9 :groups)))

  # THE TWO NAMESPACES DO NOT MEET. A parent and a child may bind the same
  # token to different things; each keeps its own meaning, and the child's
  # never reaches the parent -- where a second binding would be an error.
  (conf "/lib" "(prefix v vendor)\n(box v)\n")
  (def [s10 p10]
    (config/run @["(prefix v main.thing)" "(hide v)" "(visualize lib)"] root))
  (t/is= @{} p10)
  (t/is= ["main.thing"] (s10 :hidden) "the parent's v is the parent's")
  (t/is= ["lib.vendor"] (map |($ :prefix) (s10 :groups)) "the child's v is the child's")

  # THE PARENT STILL WINS: its own lines are applied first and the nested
  # ones after, so both are present and nothing the parent said was lost.
  (conf "/lib" "(fold vendor)\n")
  (def [s4 _] (config/run @["(visualize lib)" "(hide lib.vendor)"] root))
  (t/is= ["lib.vendor"] (s4 :hidden))
  (t/is= ["lib.vendor"] (s4 :folded))

  # A DIRECTORY WITH NOTHING TO SAY says nothing: it has no config of its
  # own, which is a fact rather than a mistake.
  (os/mkdir (string root "/quiet"))
  (def [s5 p5] (config/run @["(visualize quiet)"] root))
  (t/is= @{} p5)
  (t/is= [] (s5 :folded))

  # A NAME THE PROJECT DOES NOT HOLD IS NOT ITS OWN. `os` and `pydantic` are
  # nodes but not files: nothing under lib is called os, so `lib.os` would
  # match nothing at all -- which is how a real config with twenty-six such
  # hides drew every one of them anyway. They mean the same external here as
  # they do to the parent, and travel unprefixed.
  (conf "/lib" "(hide os)\n(hide vendor)\n")
  (def [s11 _] (config/run @["(visualize lib)"] root))
  (t/is= ["os" "lib.vendor"] (s11 :hidden)
         "an external keeps its name, a real one takes the prefix")

  # A NAME THAT IS NO DIRECTORY IS A TYPO, and the difference is worth
  # saying. `(visualize otto)` where the directory is `otto-ios` matched
  # nothing, drew nothing, and said nothing -- indistinguishable from a
  # nesting that had failed.
  (def [_ p5b] (config/run @["(visualize nope)"] root))
  (t/ok (p5b 0) "a name that is no directory is a complaint")

  # An empty name would read as "the project at the root", which is this one.
  (def [_ p6] (config/run @[`(visualize "")`] root))
  (t/ok (p6 0) "an empty nested name is a complaint")

  # WITHOUT A ROOT there is no directory to read from, so nesting is simply
  # not attempted -- which is what every caller that passes only lines gets.
  (def [s7 p7] (config/run @["(visualize lib)"]))
  (t/is= @{} p7)
  (t/is= [] (s7 :folded)))

(t/test "nesting goes as deep as the directories do"
  (def root (string (os/getenv "TMPDIR") "vz-deep-" (string (os/time))))
  (os/mkdir root)
  (os/mkdir (string root "/a"))
  (os/mkdir (string root "/a/b"))
  (spit (string root "/a/visualize.conf") "(visualize b)\n")
  (spit (string root "/a/b/leaf.py") "x = 1\n")
  (spit (string root "/a/b/visualize.conf") "(box leaf)\n(fold leaf)\n")

  # A CHILD'S OWN `visualize` IS A LINE LIKE ANY OTHER. `(visualize b)` in a
  # carries a name, so the paste puts a's prefix on it and it arrives as
  # `(visualize a.b)` -- already pointing at the right directory, and read
  # by the same paste that produced it. Nothing recurses but the paste.
  (def [state problems] (config/run @["(visualize a)"] root))
  (t/is= @{} problems)
  (t/is= ["a.b.leaf"] (map |($ :prefix) (state :groups)))
  (t/is= ["a.b.leaf"] (state :folded))

  # And naming the deep one directly is the same thing said in one line.
  (def [s2 _] (config/run @["(visualize a.b)"] root))
  (t/is= ["a.b.leaf"] (s2 :folded)))

(t/test "a directory may have a dot in its name"
  # THE MAPPING IS NOT REVERSIBLE, which is why the directory is found by
  # NAMING the directories rather than by turning the name back into a path.
  # `my.lib` is one directory whose name has a dot in it, and splitting on
  # dots would send this looking for `my/lib`.
  (def root (string (os/getenv "TMPDIR") "vz-dot-" (string (os/time))))
  (os/mkdir root)
  (os/mkdir (string root "/my.lib"))
  (os/mkdir (string root "/my.lib/inner"))
  (spit (string root "/my.lib/thing.py") "x = 1\n")
  (spit (string root "/my.lib/inner/deep.py") "y = 2\n")
  (spit (string root "/my.lib/visualize.conf") "(box thing)\n(visualize inner)\n")
  (spit (string root "/my.lib/inner/visualize.conf") "(fold deep)\n")

  (def [state problems] (config/run @["(visualize my.lib)"] root))
  (t/is= @{} problems)
  (t/is= ["my.lib.thing"] (map |($ :prefix) (state :groups)))
  # ...and a second level, reached THROUGH the dotted name.
  (t/is= ["my.lib.inner.deep"] (state :folded)))
