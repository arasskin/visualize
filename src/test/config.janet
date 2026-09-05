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

  (t/is= ["src.visualize"] ((state-of "(hide src.visualize)") :hidden))
  (t/is= ["src.visualize"] ((state-of `(hide "src.visualize")`) :hidden))
  (t/is= ["a name with spaces"] ((state-of `(hide "a name with spaces")`) :hidden))
  (t/is= ["src.test"] ((state-of "(hide src/test)") :hidden)
         "a slash is taken too, since a path is a natural thing to type"))

(t/test "a hex colour is written bare, because a hash starts a comment"

  (t/is= "#22a6f2" (get-in (state-of "(box web 22a6f2)") [:groups 0 :color]))
  (t/is= "#ff4d6d" (get-in (state-of "(box web red)") [:groups 0 :color]))

  (def [state problems] (run "(box web #22a6f2)"))
  (t/is= [] (state :groups) "nothing was grouped")
  (t/ok (string/find "parenthesis" (problems 0)))

  (def [_ quoted] (run `(box web "#22a6f2")`))
  (t/ok (string/find "not a colour" (quoted 0)))

  (def [_ bad] (run "(box web nonsense)"))
  (t/ok (bad 0)))

(t/test "a comment is a line that does nothing, wherever it sits"
  (def [state problems] (run "# just a note" "   " "(hide src.test) # and why"))
  (t/is= {} (table ;(kvs problems)) "none of the three is a complaint")
  (t/is= ["src.test"] (state :hidden) "and the form still ran"))

(t/test "the language cannot say anything but its own verbs"

  (each forbidden ["(os/shell \"echo hi\")"
                   "(file/open \"/tmp/x\" :w)"
                   "(slurp \"/etc/passwd\")"
                   "(each f [1 2] (hide f))"
                   "(def home \"src\")"]
    (def [_ problems] (run forbidden))
    (t/ok (problems 0) (string forbidden " must not be a config form")))

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

  (defn about [line] (((run line) 1) 0))

  (t/ok (string/find "`hide`" (about "(box src.web) (hide)"))
        "the broken form is named")
  (t/ok (not (string/find "`box`" (about "(box src.web) (hide)")))
        "and the one before it is not")

  (t/ok (string/find "wobble" (about "(lines) (wobble x)")))
  (t/ok (string/find "`lines`" (about "(box a red) (lines extra)")))

  (t/ok (string/find "parenthesis" (about "(hide src.test")))
  (t/ok (string/find "parentheses" (about "hide src.test"))))

(t/test "an arity complaint shows THAT verb's shape"

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

  (t/is= "@" (get-in (state-of "(prefix @ src)") [:aliases 0 :alias]))
  (t/is= "lib" (get-in (state-of "(prefix lib deps.vendor)") [:aliases 0 :alias])))

(t/test "a bound prefix expands in later names"
  (def state (state-of "(prefix ~ src.visualize)" "(hide ~.color)" "(only ~)"))
  (t/is= ["src.visualize.color"] (state :hidden))
  (t/is= ["src.visualize"] (state :only))

  (def grouped (state-of "(prefix ~ src)" "(box ~.test 22a6f2)"))
  (t/is= "src.test" (get-in grouped [:groups 0 :prefix]))
  (t/is= "#22a6f2" (get-in grouped [:groups 0 :color])))

(t/test "the longest alias wins"

  (def state (state-of "(prefix ~ src)" "(prefix ~~ src.visualize)"
                       "(hide ~.test)" "(hide ~~.color)"))
  (t/is= ["src.test" "src.visualize.color"] (state :hidden))
  (def other (state-of "(prefix ~~ src.visualize)" "(prefix ~ src)"
                       "(hide ~~.color)"))
  (t/is= ["src.visualize.color"] (other :hidden)))

(t/test "rebinding a token is refused"

  (def [state problems] (run "(prefix ~ src)" "(prefix ~ test)" "(hide ~.a)"))
  (t/ok (string/find "already bound" (problems 1)))
  (t/is= 1 (length (state :aliases)))
  (t/is= ["src.a"] (state :hidden) "the first binding stands"))

(t/test "a token substitutes only at the head"

  (def state (state-of "(prefix ~ src.config)" "(box ~~.something)"))
  (t/is= "src.config~.something" (get-in state [:groups 0 :prefix]))

  (t/is= ["a.~.b"] ((state-of "(prefix ~ src)" "(hide a.~.b)") :hidden)))

(t/test "any token at all can be a prefix"

  (each token [",x" "`q" "@" "%%" "!" "->"]
    (def [state problems] (run (string "(prefix " token " src)")
                               (string "(hide " token ".a)")))
    (t/is= @{} problems (string token " must bind"))
    (t/is= ["src.a"] (state :hidden) (string token " must substitute"))))

(t/test "an unbound token is just a name"

  (t/is= ["~.color"] ((state-of "(hide ~.color)") :hidden)))

(t/test "a prefix without both halves is refused"
  (def [_ p1] (run "(prefix ~)"))
  (t/ok (p1 0) "a token with nothing to stand for")
  (def [_ p2] (run "(prefix)"))
  (t/ok (p2 0) "neither half"))

(t/test "the docs are generated from the grammar"

  (def documented (map |($ :name) (config/docs)))
  (each name documented
    (def [_ problems] (run (string "(" name " src.a x)")))

    (when (problems 0)
      (t/ok (not (string/find "there is no verb" (problems 0)))
            (string name " is documented, so it must exist"))))

  (def [_ unknown] (run "(no-such-verb x)"))
  (each name documented
    (t/ok (string/find name (unknown 0))
          (string name " must be offered when a verb is misspelled"))))

(t/test "the docs carry each argument's kind"

  (def by-name (tabseq [d :in (config/docs)] (d :name) d))
  (t/is= ["name" "color?"] (get-in by-name ["box" :args]))
  (t/is= ["name"] (get-in by-name ["hide" :args]) "no second slot to fill")
  (t/is= ["alias" "name"] (get-in by-name ["prefix" :args]))
  (t/is= [] (get-in by-name ["lines" :args]))

  (each d (config/docs)
    (each a (d :args) (t/ok (string? a) (string (d :name) "'s args are strings"))))

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

  (each d (config/docs)
    (t/ok (and (d :blurb) (not (empty? (d :blurb))))
          (string (d :name) " must say what it does"))))

(t/test "a verb whose name starts with another still parses"

  (def names (map |($ :name) (config/docs)))
  (each name names
    (each other names
      (when (and (not= name other) (string/has-prefix? name other))
        (t/ok (< (index-of other names) (index-of name names))
              (string other " must be tried before " name)))))

  (each d (config/docs)
    (def [_ problems] (run (string "(" (d :name) " a b)")))
    (when (problems 0)
      (t/ok (not (string/find "there is no verb" (problems 0)))
            (string (d :name) " must be reachable")))))

(t/test "a prefix binds before any line that uses it"

  (def below (state-of "(hide ~.color)" "(prefix ~ src.visualize)"))
  (t/is= ["src.visualize.color"] (below :hidden))
  (def above (state-of "(prefix ~ src.visualize)" "(hide ~.color)"))
  (t/is= (above :hidden) (below :hidden) "the same file either way round")

  (def together (state-of "(hide ~.a)" "(prefix ~ src) (hide ~.b)"))
  (t/is= ["src.a" "src.b"] (together :hidden)))

(t/test "two passes do not double-report a line"
  (def [_ bad] (run "(prefix ~)"))
  (t/is= 1 (length bad) "a bad prefix line complains once")

  (def [state rebound] (run "(prefix ~ src)" "(prefix ~ test)" "(hide ~.a)"))
  (t/ok (string/find "already bound" (rebound 1)))
  (t/is= nil (rebound 0))
  (t/is= ["src.a"] (state :hidden)))

(t/test "the file still reads top to bottom within a pass"

  (def state (state-of "(box a)" "(prefix ~ src)" "(box b)"))
  (t/is= ["a" "b"] (map |($ :prefix) (state :groups))))

(def- scratch "/tmp/visualize-config-file-test.conf")

(t/test "reading a config gives one entry per written line"

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

  (t/ok (config/note? "@visualize terminal 3 socket /tmp/a.sock"))
  (t/ok (config/note? "   @visualize terminal 3 socket /tmp/a.sock")
        "leading space is still a note")
  (t/ok (not (config/note? "(hide src)")))
  (t/ok (not (config/note? "# @visualize in a comment is a comment")))

  (def lines ["(lines)" "@visualize terminal 3 socket /tmp/a.sock" "(box src)"])
  (t/is= [["3" "/tmp/a.sock"]] (config/terminals lines))

  (def shown (filter |(not (config/note? $)) lines))
  (t/is= ["(lines)" "(box src)"] shown
         "a note is never a row the editor shows")

  (t/is= ["(lines)"] (config/edit shown "delete" 1)
         "an index from the editor means the line the editor showed")

  (def [_ problems] (config/run lines))
  (t/is= @{} problems "a note draws no complaint"))

(t/test "notes are rewritten whole, never appended to"

  (def lines ["(lines)" "@visualize terminal 3 socket /tmp/old.sock"])
  (def after (config/remember-terminals lines [["4" "/tmp/new.sock"]]))
  (t/is= [["4" "/tmp/new.sock"]] (config/terminals after))
  (t/ok (not (find |(string/find "old.sock" $) after))
        "the pane that went is gone from the file")

  (t/is= ["(lines)"]
         (filter |(and (not (config/note? $)) (not (empty? (string/trim $)))) after))

  (t/is= ["(lines)"] (config/remember-terminals lines []))
  (t/is= ["(lines)"] (config/remember-terminals after [])
         "including the blank it added on the way in")

  (def pairs [["harness" "/tmp/h.sock"] ["2" "/tmp/2.sock"]])
  (t/is= pairs (config/terminals (config/remember-terminals [] pairs))))

(t/test "a nested project is drawn by its own config"

  (def root (string (os/getenv "TMPDIR") "vz-nest-" (string (os/time))))
  (os/mkdir root)
  (os/mkdir (string root "/lib"))

  (os/mkdir (string root "/lib/vendor"))
  (spit (string root "/lib/helper.py") "x = 1\n")
  (defn conf [dir text] (spit (string root dir "/visualize.conf") text))

  (conf "/lib" "(box vendor)\n(fold vendor)\n")
  (def [state problems] (config/run @["(visualize lib)"] root))
  (t/is= @{} problems)

  (t/is= ["lib.vendor"] (map |($ :prefix) (state :groups)))
  (t/is= ["lib.vendor"] (state :folded))

  (conf "/lib" "(lines)\n(animate)\n(box vendor)\n")
  (def [s2 _] (config/run @["(visualize lib)"] root))
  (t/ok (not (s2 :sized)) "a nested (lines) does not size the parent")
  (t/ok (not (s2 :animated)) "a nested (animate) does not animate the parent")
  (t/is= ["lib.vendor"] (map |($ :prefix) (s2 :groups)))

  (conf "/lib" "(box vendor red)\n(prefix q other)\n")
  (def [s3 _] (config/run @["(visualize lib)"] root))
  (t/is= [["lib.vendor" "#ff4d6d"]] (map |[($ :prefix) ($ :color)] (s3 :groups)))
  (t/is= [] (s3 :aliases) "a child's alias does not reach the parent")

  (conf "/lib" "(prefix v vendor)\n(box v)\n(fold v.deep)\n(hide v)\n")
  (def [s8 _] (config/run @["(visualize lib)"] root))
  (t/is= ["lib.vendor"] (map |($ :prefix) (s8 :groups)))
  (t/is= ["lib.vendor.deep"] (s8 :folded) "an alias at the head of a longer name")
  (t/is= ["lib.vendor"] (s8 :hidden) "the bare token is the path itself")

  (conf "/lib" "(box v)\n(prefix v vendor)\n")
  (def [s9 _] (config/run @["(visualize lib)"] root))
  (t/is= ["lib.vendor"] (map |($ :prefix) (s9 :groups)))

  (conf "/lib" "(prefix v vendor)\n(box v)\n")
  (def [s10 p10]
    (config/run @["(prefix v main.thing)" "(hide v)" "(visualize lib)"] root))
  (t/is= @{} p10)
  (t/is= ["main.thing"] (s10 :hidden) "the parent's v is the parent's")
  (t/is= ["lib.vendor"] (map |($ :prefix) (s10 :groups)) "the child's v is the child's")

  (conf "/lib" "(fold vendor)\n")
  (def [s4 _] (config/run @["(visualize lib)" "(hide lib.vendor)"] root))
  (t/is= ["lib.vendor"] (s4 :hidden))
  (t/is= ["lib.vendor"] (s4 :folded))

  (os/mkdir (string root "/quiet"))
  (def [s5 p5] (config/run @["(visualize quiet)"] root))
  (t/is= @{} p5)
  (t/is= [] (s5 :folded))

  (conf "/lib" "(hide os)\n(hide vendor)\n")
  (def [s11 _] (config/run @["(visualize lib)"] root))
  (t/is= ["os" "lib.vendor"] (s11 :hidden)
         "an external keeps its name, a real one takes the prefix")

  (def [_ p5b] (config/run @["(visualize nope)"] root))
  (t/ok (p5b 0) "a name that is no directory is a complaint")

  (def [_ p6] (config/run @[`(visualize "")`] root))
  (t/ok (p6 0) "an empty nested name is a complaint")

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

  (def [state problems] (config/run @["(visualize a)"] root))
  (t/is= @{} problems)
  (t/is= ["a.b.leaf"] (map |($ :prefix) (state :groups)))
  (t/is= ["a.b.leaf"] (state :folded))

  (def [s2 _] (config/run @["(visualize a.b)"] root))
  (t/is= ["a.b.leaf"] (s2 :folded)))

(t/test "a directory may have a dot in its name"

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

  (t/is= ["my.lib.inner.deep"] (state :folded)))

(t/test "an external hidden by a nested project stays that project's"

  (def root (string (os/getenv "TMPDIR") "vz-scope-" (string (os/time))))
  (os/mkdir root)
  (os/mkdir (string root "/childA"))
  (os/mkdir (string root "/childB"))
  (spit (string root "/visualize.conf")
        "(visualize childA) (visualize childB)\n")
  (spit (string root "/childA/visualize.conf") "(hide ?.)\n")
  (spit (string root "/childB/visualize.conf") "# nothing hidden\n")
  (spit (string root "/childA/a.py") "import zzz_libA\n")
  (spit (string root "/childB/b.py") "import zzz_libB\n")

  (def [state problems] (config/run (config/read-config
                                      (string root "/visualize.conf")) root))
  (t/is= 0 (length problems) "the nested configs ran cleanly")
  (t/ok (some |(string/find "@childA" $) (state :hidden))
        "the hide carries the project that wrote it")

  (spit (string root "/childA/visualize.conf") "(hide ?)\n")
  (def [state2 _] (config/run (config/read-config
                                (string root "/visualize.conf")) root))
  (t/ok (some |(string/find "@childA" $) (state2 :hidden))
        "written without the trailing dot, it is still scoped"))

(t/test "a label is what a pane has been called by hand"

  (def lines ["(lines)"
              "@visualize terminal 3 socket /tmp/x.sock"
              "@visualize label 3 the failing test"])
  (t/is= "the failing test" (get (config/labels lines) "3"))

  (t/is= "two words here"
         (get (config/labels ["@visualize label 7 two words here"]) "7"))

  (def cleared (config/remember-labels lines @{"3" ""}))
  (t/ok (not (some |(string/find "label" $) cleared))
        "clearing a label takes its line out of the file")
  (t/ok (some |(string/find "terminal 3 socket" $) cleared)
        "and leaves the socket note alone")

  (def renamed (config/remember-labels lines @{"3" "prod logs"}))
  (t/is= 1 (length (filter |(string/find "label" $) renamed))
         "one label line, not two")
  (t/is= "prod logs" (get (config/labels renamed) "3")))
