(import ../../src.server/config)
(import ./harness :as t)

(t/test "as-hex resolves names, hex and rubbish"
  (t/is= "#ff4d6d" (config/as-hex "red"))
  (t/is= "#aabbcc" (config/as-hex "AABBCC") "bare hex, and case does not matter")
  (t/is= nil (config/as-hex "#aabbcc")
         "a leading hash is a comment in the config, so it is not a colour here")
  (t/is= "#22a6f2" (config/as-hex "blue"))
  (t/is= "#8d99ae" (config/as-hex "gray") "gray and grey are the same colour")
  (t/is= nil (config/as-hex "nope"))
  (t/is= nil (config/as-hex "ff") "a short hex is not a colour"))

(t/test "tint holds the hue and lands on the endpoints Python gives"
  (t/is= "#ff91a4" (config/tint "#ff4d6d" 0))
  (t/is= "#ff4d6d" (config/tint "#ff4d6d" 1))
  (t/is= "#ff91a4" (config/tint "#ff4d6d" -5) "weights clamp at 0")
  (t/is= "#ff4d6d" (config/tint "#ff4d6d" 5) "weights clamp at 1"))

(t/test "ink and ink-on-page clear WCAG"
  (t/is= "#42141c" (config/ink "#ff4d6d"))
  (t/is= "#8c2a3c" (config/ink-on-page "#ff4d6d"))
  (t/is= "#f7f7f7" (config/ink "#101010") "a dark fill inverts to near-white")

  (each hue config/palette
    (t/ok (>= (config/contrast (config/ink hue) hue) 4.5)
          (string "ink is legible on " hue))
    (t/ok (>= (config/contrast (config/ink-on-page hue) "#ffffff") 4.5)
          (string "ink-on-page is legible for " hue))))

(t/test "ramp ranks rather than scales"

  (t/is= {"a" 0 "b" 0 "c" 0.5 "d" 1}
         (config/ramp {"a" 1 "b" 1 "c" 5 "d" 13}))
  (t/is= {"only" 1} (config/ramp {"only" 3})
         "a single tier is fully bright rather than divided by zero"))

(t/test "the palette is distinct and excludes the ungrouped colour"
  (t/is= (length config/palette) (length (distinct config/palette)))
  (t/ok (not (index-of config/ungrouped config/palette))
        "a group must never be handed the colour ungrouped nodes wear"))

(defn- run [& lines] (config/run lines))
(defn- state-of [& lines] (first (config/run lines)))

(t/test "hide and only collect prefixes"
  (def state (state-of "hide src.test" "hide WebKit" "only \"\""))
  (t/is= ["src.test" "WebKit"] (state :hidden))
  (t/is= [""] (state :only) "the empty prefix is everything of ours"))

(t/test "saying a thing twice is not an error"

  (def state (state-of "hide \"~.Tests\"" "hide \"~.Tests\""))
  (t/is= ["~.Tests"] (state :hidden)))

(t/test "animate asks for the flash"
  (t/ok ((state-of "animate") :animated))
  (t/ok (not ((state-of "lines") :animated))
        "and nothing else turns it on"))

(t/test "flags are set, never flipped"
  (def state (state-of "lines" "lines"))
  (t/ok (state :sized)))

(t/test "groups take the palette in order and never repeat"
  (def state (state-of "box \"~.A\"" "box \"~.B\"" "box \"~.C\""))
  (def hues (map |($ :color) (state :groups)))
  (t/is= 3 (length (distinct hues)))
  (t/ok (not (index-of config/ungrouped hues))
        "no group may wear the colour ungrouped nodes already have"))

(t/test "an explicit colour wins and the automatic ones move around it"

  (def state (state-of "box \"~.A\"" "box \"~.B\" red"))
  (def by-prefix (table ;(mapcat |[($ :prefix) ($ :color)] (state :groups))))
  (t/is= "#ff4d6d" (by-prefix "~.B"))
  (t/ok (not= "#ff4d6d" (by-prefix "~.A"))))

(t/test "regrouping a prefix recolours rather than duplicating"
  (def state (state-of "box \"~.A\"" "box \"~.A\" blue"))
  (t/is= 1 (length (state :groups)))
  (t/is= "#22a6f2" (((state :groups) 0) :color)))

(t/test "a bad colour complains on its own line and the rest still runs"
  (def [state problems] (run "box \"~.A\" nonsense" "hide \"~.B\""))
  (t/ok (problems 0) "the bad line is reported")
  (t/ok (string/find "not a colour" (problems 0)))
  (t/is= ["~.B"] (state :hidden) "the good line still took effect")
  (t/ok (not (problems 1))))

(t/test "the ungrouped colour is refused as a group colour"

  (def bare (string/replace "#" "" config/ungrouped))
  (def [_ problems] (run (string "box \"~.A\" " bare "")))
  (t/ok (problems 0))
  (t/ok (string/find "invisible" (problems 0))))

(t/test "an unknown verb is reported, not fatal"
  (def [state problems] (run "(explode \"~.A\")" "hide \"~.B\""))
  (t/ok (problems 0))
  (t/is= ["~.B"] (state :hidden)))

(t/test "a blank line and a comment do nothing at all"
  (def [state problems] (run "" "   " "# just a note" "# also a note"))
  (t/is= @{} problems)
  (t/is= [] (state :hidden)))

(t/test "a bare name is a literal, and quoting is for awkward ones"

  (t/is= ["src.server"] ((state-of "hide src.server") :hidden))
  (t/is= ["src.server"] ((state-of `hide "src.server"`) :hidden))
  (t/is= ["a name with spaces"] ((state-of `hide "a name with spaces"`) :hidden))
  (t/is= ["src.test"] ((state-of "hide src/test") :hidden)
         "a slash is taken too, since a path is a natural thing to type"))

(t/test "a hex colour is written bare, because a hash starts a comment"

  (t/is= "#22a6f2" (get-in (state-of "box web 22a6f2") [:groups 0 :color]))
  (t/is= "#ff4d6d" (get-in (state-of "box web red") [:groups 0 :color]))

  (def [state problems] (run "box web #22a6f2"))
  (t/is= ["web"] (map |($ :prefix) (state :groups)) "the hash starts an inline comment")
  (t/is= {} problems)

  (def [_ quoted] (run `box web "#22a6f2"`))
  (t/ok (string/find "not a colour" (quoted 0)))

  (def [_ bad] (run "box web nonsense"))
  (t/ok (bad 0)))

(t/test "a comment is a line that does nothing, wherever it sits"
  (def [state problems] (run "# just a note" "   " "hide src.test # and why"))
  (t/is= {} (table ;(kvs problems)) "none of the three is a complaint")
  (t/is= ["src.test"] (state :hidden) "and the form still ran"))

(t/test "the language cannot say anything but its own verbs"

  (each forbidden ["(os/shell \"echo hi\")"
                   "(file/open \"/tmp/x\" :w)"
                   "(slurp \"/etc/passwd\")"
                   "(each f [1 2] hide f)"
                   "(def home \"src\")"]
    (def [_ problems] (run forbidden))
    (t/ok (problems 0) (string forbidden " must not be a config form")))

  (def [state clean] (run "hide ,home"))
  (t/is= @{} clean)
  (t/is= [",home"] (state :hidden)))

(t/test "a refusal says what to write instead"
  (def [_ unknown] (run "(explode src)"))
  (t/ok (string/find "no verb" (unknown 0)))
  (t/ok (string/find "box" (unknown 0)) "and lists the ones there are")
  (def [_ badargs] (run "hide"))
  (t/ok (badargs 0) "a verb without its argument is refused"))

(t/test "commands are separated by lines and parentheses are rejected"
  (each text ["box b fold b" "(hide src.test)" "hide" "lines extra" "foldb"]
    (def [_ problems] (run text))
    (t/ok (problems 0)))
  (def [state problems] (run "box b" "fold b"))
  (t/is= {} problems)
  (t/is= ["b"] (state :folded)))

(t/test "an arity complaint shows THAT verb's shape"

  (defn about [line] (((run line) 1) 0))

  (t/ok (string/find "hide prefix" (about "hide"))
        "hide is shown taking a prefix")
  (t/ok (not (string/find "colour" (about "hide")))
        "and no colour, which it does not take")

  (t/ok (string/find "lines" (about "lines extra")))
  (t/ok (string/find "nothing else" (about "lines extra"))
        "a verb with no arguments says so")

  (t/ok (string/find "box prefix color?" (about "box")))
  (t/ok (string/find "colour" (about "box"))
        "and it alone mentions a colour")
)

(t/test "prefix is no longer a verb and paths are literal"
  (def [state problems] (run "prefix ~ src.server" "hide ~.color"))
  (t/ok (string/find "there is no verb" (problems 0)))
  (t/is= ["~.color"] (state :hidden))
  (t/is= nil (config/command "prefix ~ src.server"))
  (t/is= nil (find |(= ($ :name) "prefix") (config/docs))))

(t/test "the docs are generated from the grammar"

  (def documented (map |($ :name) (config/docs)))
  (each name documented
    (def [_ problems] (run (string name " src.a x")))

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
  (t/is= [] (get-in by-name ["lines" :args]))

  (each d (config/docs)
    (each a (d :args) (t/ok (string? a) (string (d :name) "'s args are strings"))))

  (def named (config/colours))
  (t/ok (index-of "blue" named))
  (each colour named
    (t/ok (not (nil? (config/as-hex colour)))
          (string colour " must be a colour the config accepts"))))

(t/test "a usage line comes from the arguments the parser takes"
  (def by-name (tabseq [d :in (config/docs)] (d :name) d))
  (t/is= "box prefix color?" (get-in by-name ["box" :usage])
         "the optional colour is marked")
  (t/is= "lines" (get-in by-name ["lines" :usage])
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
    (def [_ problems] (run (string (d :name) " a b")))
    (when (problems 0)
      (t/ok (not (string/find "there is no verb" (problems 0)))
            (string (d :name) " must be reachable")))))

(t/test "the file reads top to bottom"

  (def state (state-of "box a" "box b"))
  (t/is= ["a" "b"] (map |($ :prefix) (state :groups))))

(def- scratch "/tmp/visualize-config-file-test.conf")

(t/test "config files keep the first occurrence of each nonblank line"
  (def lines [" box b " "fold b" "box b" "#fold b" "fold b" "" ""
              "@visualize placement 1 top 0" "@visualize placement 1 top 0"])
  (def expected [" box b " "fold b" "#fold b" "" ""
                 "@visualize placement 1 top 0" "@visualize placement 1 top 0"])
  (t/is= expected (config/unique-lines lines))
  (def saved [" box b " "fold b" "#fold b" "" "@visualize terminal 1 placement top 0"])
  (spit scratch (string (string/join lines "\n") "\n"))
  (t/is= lines (config/read-config scratch))
  (config/write-config scratch lines)
  (t/is= saved (config/read-config scratch))
  (t/is= (string (string/join saved "\n") "\n") (string (slurp scratch)))
  (config/write-config scratch ["fold b" "box c" "fold b"])
  (t/is= "fold b\nbox c\n" (string (slurp scratch))))

(t/test "config cleanup compares commands rather than their spelling"
  (def lines ["  fold src # first" "fold   \"src\" # later" "fold\tsrc"
              "#fold src # disabled first" "  # fold \"src\" # disabled later"
              "box src blue" "box \"src\" \"blue\"" "box src red"
              "fold Src" "fold src.web" "lines # first" "lines"
              "fold \"a b\"" "fold \"a  b\"" "fold \"src#tag\"" "fold \"src#tag\" # later"
              "broken src" "broken  src" "# note" "" ""
              "@visualize placement pane top 0" "@visualize placement pane top 0"])
  (def expected ["  fold src # first" "#fold src # disabled first" "box src blue" "box src red"
                 "fold Src" "fold src.web" "lines # first" "fold \"a b\"" "fold \"a  b\""
                 "fold \"src#tag\"" "broken src" "broken  src" "# note" "" ""
                 "@visualize placement pane top 0" "@visualize placement pane top 0"])
  (t/is= expected (config/unique-lines lines))
  (t/is= expected (config/unique-lines expected))
  (def saved (array ;(slice expected 0 13) "" "@visualize terminal pane placement top 0"))
  (spit scratch (string (string/join lines "\n") "\n"))
  (t/is= lines (config/read-config scratch))
  (config/write-config scratch lines)
  (t/is= saved (config/read-config scratch))
  (t/is= (string (string/join saved "\n") "\n") (string (slurp scratch)))
  (config/write-config scratch lines)
  (t/is= saved (config/read-config scratch)))

(t/test "reading a config gives one entry per written line"

  (spit scratch "lines\nhide src.test\n")
  (t/is= ["lines" "hide src.test"] (config/read-config scratch))
  (spit scratch "lines")
  (t/is= ["lines"] (config/read-config scratch)
         "a file with no trailing newline reads the same"))

(t/test "a config round trips unchanged"
  (spit scratch "lines\nhide src.test\n")
  (def lines (config/read-config scratch))
  (config/write-config scratch lines)
  (t/is= lines (config/read-config scratch))
  (t/is= "lines\nhide src.test\n" (string (slurp scratch))
         "and the file is the lines, newline-terminated"))

(os/rm scratch)

(t/test "visualize keeps its own notes in the config file"

  (t/ok (config/note? "@visualize terminal 3 socket /tmp/a.sock"))
  (t/ok (config/note? "   @visualize terminal 3 socket /tmp/a.sock")
        "leading space is still a note")
  (t/ok (not (config/note? "hide src")))
  (t/ok (not (config/note? "# @visualize in a comment is a comment")))

  (def lines ["lines" "@visualize terminal 3 socket /tmp/a.sock" "box src"])
  (t/is= [["3" "/tmp/a.sock"]] (config/terminals lines))

  (def shown (filter |(not (config/note? $)) lines))
  (t/is= ["lines" "box src"] shown
         "a note is never a row the editor shows")

  (def [_ problems] (config/run lines))
  (t/is= @{} problems "a note draws no complaint"))

(t/test "notes are rewritten whole, never appended to"

  (def lines ["lines" "@visualize terminal 3 socket /tmp/old.sock"])
  (def after (config/remember-terminals lines [["4" "/tmp/new.sock"]]))
  (t/is= [["4" "/tmp/new.sock"]] (config/terminals after))
  (t/ok (not (find |(string/find "old.sock" $) after))
        "the pane that went is gone from the file")

  (t/is= ["lines"]
         (filter |(and (not (config/note? $)) (not (empty? (string/trim $)))) after))

  (t/is= ["lines"] (config/remember-terminals lines []))
  (t/is= ["lines"] (config/remember-terminals after [])
         "including the blank it added on the way in")

  (def pairs [["harness" "/tmp/h.sock"] ["2" "/tmp/2.sock"]])
  (t/is= (sorted-by first pairs) (config/terminals (config/remember-terminals [] pairs))))

(t/test "a nested project is drawn by its own config"

  (def root (string (os/getenv "TMPDIR") "vz-nest-" (string (os/time))))
  (os/mkdir root)
  (os/mkdir (string root "/lib"))

  (os/mkdir (string root "/lib/vendor"))
  (spit (string root "/lib/helper.py") "x = 1\n")
  (defn conf [dir text] (spit (string root dir "/visualize_config") text))

  (conf "/lib" "box vendor\nfold vendor\n")
  (def [state problems] (config/run @["visualize lib"] root))
  (t/is= @{} problems)

  (t/is= ["lib.vendor"] (map |($ :prefix) (state :groups)))
  (t/is= ["lib.vendor"] (state :folded))

  (conf "/lib" "lines\nanimate\nbox vendor\n")
  (def [s2 _] (config/run @["visualize lib"] root))
  (t/ok (not (s2 :sized)) "a nested lines does not size the parent")
  (t/ok (not (s2 :animated)) "a nested animate does not animate the parent")
  (t/is= ["lib.vendor"] (map |($ :prefix) (s2 :groups)))

  (conf "/lib" "box vendor red\n")
  (def [s3 _] (config/run @["visualize lib"] root))
  (t/is= [["lib.vendor" "#ff4d6d"]] (map |[($ :prefix) ($ :color)] (s3 :groups)))
  (conf "/lib" "box vendor\nfold vendor.deep\nhide vendor\n")
  (def [nested faults] (config/run @["hide main.thing" "visualize lib"] root))
  (t/is= @{} faults)
  (t/is= ["lib.vendor"] (map |($ :prefix) (nested :groups)))
  (t/is= ["lib.vendor.deep"] (nested :folded))
  (t/is= ["main.thing" "lib.vendor"] (nested :hidden))

  (conf "/lib" "fold vendor\n")
  (def [s4 _] (config/run @["visualize lib" "hide lib.vendor"] root))
  (t/is= ["lib.vendor"] (s4 :hidden))
  (t/is= ["lib.vendor"] (s4 :folded))

  (os/mkdir (string root "/quiet"))
  (def [s5 p5] (config/run @["visualize quiet"] root))
  (t/is= @{} p5)
  (t/is= [] (s5 :folded))

  (conf "/lib" "hide os\nhide vendor\n")
  (def [s11 _] (config/run @["visualize lib"] root))
  (t/is= ["os" "lib.vendor"] (s11 :hidden)
         "an external keeps its name, a real one takes the prefix")

  (def [_ p5b] (config/run @["visualize nope"] root))
  (t/ok (p5b 0) "a name that is no directory is a complaint")

  (def [_ p6] (config/run @[`visualize ""`] root))
  (t/ok (p6 0) "an empty nested name is a complaint")

  (def [s7 p7] (config/run @["visualize lib"]))
  (t/is= @{} p7)
  (t/is= [] (s7 :folded)))

(t/test "nesting goes as deep as the directories do"
  (def root (string (os/getenv "TMPDIR") "vz-deep-" (string (os/time))))
  (os/mkdir root)
  (os/mkdir (string root "/a"))
  (os/mkdir (string root "/a/b"))
  (spit (string root "/a/visualize_config") "visualize b\n")
  (spit (string root "/a/b/leaf.py") "x = 1\n")
  (spit (string root "/a/b/visualize_config") "box leaf\nfold leaf\n")

  (def [state problems] (config/run @["visualize a"] root))
  (t/is= @{} problems)
  (t/is= ["a.b.leaf"] (map |($ :prefix) (state :groups)))
  (t/is= ["a.b.leaf"] (state :folded))

  (def [s2 _] (config/run @["visualize a.b"] root))
  (t/is= ["a.b.leaf"] (s2 :folded)))

(t/test "a directory may have a dot in its name"

  (def root (string (os/getenv "TMPDIR") "vz-dot-" (string (os/time))))
  (os/mkdir root)
  (os/mkdir (string root "/my.lib"))
  (os/mkdir (string root "/my.lib/inner"))
  (spit (string root "/my.lib/thing.py") "x = 1\n")
  (spit (string root "/my.lib/inner/deep.py") "y = 2\n")
  (spit (string root "/my.lib/visualize_config") "box thing\nvisualize inner\n")
  (spit (string root "/my.lib/inner/visualize_config") "fold deep\n")

  (def [state problems] (config/run @["visualize my.lib"] root))
  (t/is= @{} problems)
  (t/is= ["my.lib.thing"] (map |($ :prefix) (state :groups)))

  (t/is= ["my.lib.inner.deep"] (state :folded)))

(t/test "an external hidden by a nested project stays that project's"

  (def root (string (os/getenv "TMPDIR") "vz-scope-" (string (os/time))))
  (os/mkdir root)
  (os/mkdir (string root "/childA"))
  (os/mkdir (string root "/childB"))
  (spit (string root "/visualize_config")
        "visualize childA\nvisualize childB\n")
  (spit (string root "/childA/visualize_config") "hide ?.\n")
  (spit (string root "/childB/visualize_config") "# nothing hidden\n")
  (spit (string root "/childA/a.py") "import zzz_libA\n")
  (spit (string root "/childB/b.py") "import zzz_libB\n")

  (def [state problems] (config/run (config/read-config
                                      (string root "/visualize_config")) root))
  (t/is= 0 (length problems) "the nested configs ran cleanly")
  (t/ok (some |(string/find "@childA" $) (state :hidden))
        "the hide carries the project that wrote it")

  (spit (string root "/childA/visualize_config") "hide ?\n")
  (def [state2 _] (config/run (config/read-config
                                (string root "/visualize_config")) root))
  (t/ok (some |(string/find "@childA" $) (state2 :hidden))
        "written without the trailing dot, it is still scoped"))

(t/test "pane placements round trip without replacing other metadata"
  (def positions {"config" ["bottom" 0] "harness" ["top" 1] "3" ["floating" 240 180]})
  (def lines ["lines" "@visualize terminal 3 socket /tmp/x.sock" "@visualize label 3 work"
              "@visualize placement old top 0"])
  (def saved (config/remember-placements lines positions))
  (t/is= positions (config/placements saved))
  (t/is= saved (config/remember-placements saved positions))
  (t/ok (some |(= $ "lines") saved))
  (t/ok (some |(string/find "terminal 3 socket" $) saved))
  (t/is= "work" (get (config/labels saved) "3"))
  (t/is= @{} (config/placements ["@visualize placement a top nope"
    "@visualize placement b bottom -1" "@visualize placement c floating 20"
    "@visualize placement d top 1.5" "@visualize placement e nowhere 2"])))

(t/test "a label is what a pane has been called by hand"

  (def lines ["lines"
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

(t/test "terminal records migrate all saved state onto one line"
  (def old ["box src" "" "" "fold src" "" ""
            "@visualize placement harness bottom 2 640 480"
            "@visualize label harness work placement socket \"quoted\""
            "@visualize terminal harness socket /tmp/h.sock"
            "@visualize markdown {\"harness\":\"/tmp/my project/notes.md\"}"
            "@visualize terminal other socket /tmp/o.sock"
            "@visualize placement other floating -10 80 320 200"
            "@visualize future setting"])
  (def expected ["box src" "" "fold src" ""
                "@visualize terminal harness socket /tmp/h.sock placement bottom 2 640 480 label \"work placement socket \\\"quoted\\\"\" document \"/tmp/my project/notes.md\""
                "@visualize terminal other socket /tmp/o.sock placement floating -10 80 320 200"
                "@visualize future setting"])
  (def file (string "/tmp/vz-record-migration-" (os/getpid)))
  (spit file (string (string/join old "\n") "\n"))
  (defer (os/rm file)
    (t/is= old (config/read-config file))
    (config/write-config file old)
    (t/is= expected (config/read-config file))
    (t/is= (string (string/join expected "\n") "\n") (string (slurp file)))
    (t/is= expected (config/read-config file))
    (t/is= (config/terminals old) (config/terminals expected))
    (t/is= (config/placements old) (config/placements expected))
    (t/is= (config/labels old) (config/labels expected))
    (t/is= (config/markdown old) (config/markdown expected))))

(t/test "terminal fields update independently and round trip quoted values"
  (def socket "/tmp/my project/\"shell\"\\terminal.sock")
  (def document "/tmp/my project/notes #1.md")
  (def label "socket placement document\n\"title\"")
  (var lines (config/remember-terminals ["lines"] [["1" socket]]))
  (set lines (config/remember-labels lines {"1" label}))
  (set lines (config/remember-placements lines {"1" ["top" 0 800 450]}))
  (set lines (config/remember-markdown lines {"1" document}))
  (t/is= 2 (length lines))
  (t/is= [["1" socket]] (config/terminals lines))
  (t/is= {"1" label} (config/labels lines))
  (t/is= {"1" document} (config/markdown lines))
  (t/is= {"1" ["top" 0 800 450]} (config/placements lines))
  (t/is= lines (config/tidy-lines lines))
  (set lines (config/remember-terminals lines [["1" "/tmp/new.sock"]]))
  (t/is= {"1" label} (config/labels lines))
  (t/is= {"1" document} (config/markdown lines))
  (t/is= {"1" ["top" 0 800 450]} (config/placements lines))
  (set lines (config/remember-markdown lines @{}))
  (set lines (config/remember-labels lines @{}))
  (set lines (config/remember-placements lines @{}))
  (t/is= ["lines" "@visualize terminal 1 socket /tmp/new.sock"] lines)
  (t/is= ["lines"] (config/remember-terminals lines [])))

(t/test "saving pane metadata never introduces command spacing"
  (var lines ["box src.graphviz"])
  (for i 0 10
    (set lines (config/remember-terminals lines [["1" "/tmp/a.sock"]]))
    (set lines (config/remember-labels lines {"1" "work"}))
    (set lines (config/remember-placements lines {"1" ["bottom" 0 600 400]}))
    (set lines (config/remember-markdown lines {"1" "/tmp/notes.md"})))
  (set lines (config/tidy-lines (array ;lines "fold src.graphviz")))
  (t/is= "fold src.graphviz" (last lines))
  (t/is= ["box src.graphviz" "fold src.graphviz"] (filter |(not (config/note? $)) lines))
  (t/is= 3 (length lines))
  (t/is= ["box a" "" "fold a"] (config/tidy-lines ["" "box a" "" " " "" "fold a" "" ""])))

(t/test "config reads neither rewrite nor create files"
  (def path (string "/tmp/vz-read-only-" (os/getpid)))
  (spit path "fold src\nfold src\n\n\n")
  (defer (os/rm path)
    (def before (os/stat path))
    (t/is= ["fold src" "fold src" "" ""] (config/read-config path))
    (t/is= "fold src\nfold src\n\n\n" (string (slurp path)))
    (t/is= (before :modified) (os/stat path :modified)))
  (t/ok (try (do (config/read-config path) false) ([_] true)))
  (t/ok (nil? (os/stat path)))
  (config/initialize path)
  (defer (os/rm path)
    (t/is= ["lines"] (config/read-config path))
    (spit path "fold src\n")
    (config/initialize path)
    (t/is= ["fold src"] (config/read-config path))))

(t/test "config writes preserve permissions and update a symlink's target"
  (def target (string "/tmp/vz-config-target-" (os/getpid)))
  (def link (string target "-link"))
  (spit target "lines\n")
  (os/chmod target 8r600)
  (os/symlink target link)
  (defer (do (os/rm link) (os/rm target))
    (config/write-config link ["fold src"])
    (t/is= :link (os/lstat link :mode))
    (t/is= "fold src\n" (string (slurp target)))
    (t/is= 8r600 (os/stat target :int-permissions))
    (def inode (os/stat target :inode))
    (config/write-config link ["fold src"])
    (t/is= inode (os/stat target :inode) "an unchanged save does not replace the file")))
