(import ../../src.server/config)
(import ../../src.server/config-graph :as diagram)
(import ../../src.server/worker)
(import ../../src.server/json)
(import ./harness :as t)

(t/test "config graphs contain distinct commands and shared prefix ancestry"
  (def graph (diagram/model ["fold b" "box b" "box b.a" "fold b.a" "lines"]))
  (def nodes (tabseq [node :in (graph :nodes)] (node :id) node))
  (t/is= 7 (length nodes))
  (t/is= [0 1 2 3] ((nodes "p:b") :lines))
  (t/is= [2 3] ((nodes "p:b.a") :lines))
  (t/is= [["p:b" "c0"] ["p:b" "c1"] ["p:b" "p:b.a"]
          ["p:b.a" "c2"] ["p:b.a" "c3"]] (graph :edges))
  (t/is= "lines" ((nodes "c4") :label)))

(t/test "config dependencies run from broad prefixes to commands"
  (t/is= [["p:src" "p:src.server"] ["p:src.server" "p:src.server.parsers"]
          ["p:src.server.parsers" "c0"]]
         ((diagram/model ["fold src.server.parsers"]) :edges)))

(t/test "prefix actions affect descendants but not similarly named siblings or metadata"
  (def lines ["box b" "#fold b.a" "box b.a blue" "fold bee" "lines"
              "@visualize terminal 1 socket /tmp/one.sock"])
  (def base (diagram/visible lines))
  (def disabled (diagram/change lines {"action" "subtree-comment" "node" "p:b" "base" base}))
  (t/is= ["#box b" "#fold b.a" "#box b.a blue" "fold bee" "lines"
          "@visualize terminal 1 socket /tmp/one.sock"] disabled)
  (def enabled (diagram/change disabled {"action" "subtree-comment" "node" "p:b" "base" (diagram/visible disabled)}))
  (t/is= ["box b" "fold b.a" "box b.a blue" "fold bee" "lines"
          "@visualize terminal 1 socket /tmp/one.sock"] enabled)
  (t/is= ["box b" "fold bee" "lines" "@visualize terminal 1 socket /tmp/one.sock"]
         (diagram/change lines {"action" "subtree-delete" "node" "p:b.a" "base" base}))
  (t/is= ["#fold b.a" "box b.a blue" "fold bee" "lines" "@visualize terminal 1 socket /tmp/one.sock"]
         (diagram/change lines {"action" "subtree-delete" "node" "c0" "base" base})))

(t/test "stale diagrams cannot delete a different command after another edit"
  (t/ok (try (do (diagram/change ["box c" "box b"]
    {"action" "subtree-delete" "node" "c0" "base" ["box b"]}) false) ([_] true)))
  (t/is= ["box c" "box b"] (diagram/change ["box c"] {"action" "append" "command" "box b"})))

(t/test "implicit prefixes retain their subtree when commented"
  (def lines ["box src.web" "#fold src.web.app" "box src.web.other"])
  (def nodes (tabseq [node :in ((diagram/model lines) :nodes)] (node :id) node))
  (t/is= [0 1 2] ((nodes "p:src.web") :lines))
  (t/is= [1] ((nodes "p:src.web.app") :lines))
  (t/is= true ((nodes "p:src.web.app") :commented))
  (def disabled (diagram/change lines {"action" "subtree-comment" "node" "p:src" "base" lines}))
  (t/is= ["#box src.web" "#fold src.web.app" "#box src.web.other"] disabled)
  (t/is= [0 1 2] ((find |(= ($ :id) "p:src.web") ((diagram/model disabled) :nodes)) :lines)))

(t/test "blank files, notes, malformed commands, and hostile labels remain editable"
  (t/is= [] ((diagram/model ["" "@visualize placement 1 top 0"]) :nodes))
  (def lines ["box \"a<b&c>\"" "broken command" "# a note"])
  (def graph (diagram/model lines))
  (def svg (diagram/render graph))
  (t/ok (string/find "a&lt;b&amp;c&gt;" svg))
  (t/ok (not (string/find "<b&c>" svg)))
  (t/is= [] (diagram/change ["lines"] {"action" "subtree-delete" "node" "c0" "base" ["lines"]})))

(t/test "new commands are validated and appended exactly once"
  (each command ["(fold b)" "box b\nfold b" "hide" "lines extra" "box b nonsense" "#fold b"]
    (t/ok (try (do (diagram/change [] {"action" "append" "command" command}) false) ([_] true))))
  (t/is= ["lines" "box b # keep"]
         (diagram/change ["lines"] {"action" "append" "command" "box b # keep"})))

(t/test "append and subtree toggles cannot create duplicate lines"
  (t/is= ["fold b" "box c"]
    (diagram/change ["fold b" "box c"] {"action" "append" "command" "fold b"}))
  (def lines ["#fold b" "fold b" "box c"])
  (t/is= ["#fold b" "box c"]
    (diagram/change lines {"action" "subtree-comment" "node" "p:b" "base" lines}))
  (t/is= ["fold b" "box c"]
    (diagram/change lines {"action" "subtree-comment" "node" "c0" "base" lines})))

(t/test "the joined un modifier comments out every command type without appending itself"
  (each command ["box src" "box src blue" "fold src" "hide src" "only src" "visualize src" "lines" "animate"]
    (def lines [command "# a note" "@visualize placement pane bottom 0"])
    (def disabled (diagram/change lines {"action" "append" "command" (string "un" command)}))
    (t/is= [(string "#" command) "# a note" "@visualize placement pane bottom 0"] disabled)
    (t/is= disabled (diagram/change disabled {"action" "append" "command" (string "un" command)}))
    (t/is= [] (diagram/change [] {"action" "append" "command" (string "un" command)}))
    (t/is= lines (diagram/change disabled {"action" "append" "command" command}))))

(t/test "command entry restores commented lines in place and appends only absent commands"
  (def lines ["lines" "  #fold  \"src\" # keep this note" "box src blue" "#fold other"
              "@visualize placement pane bottom 0"])
  (def restored ["lines" "  fold  \"src\" # keep this note" "box src blue" "#fold other"
                 "@visualize placement pane bottom 0"])
  (t/is= restored (diagram/change lines {"action" "append" "command" "fold src"}))
  (t/is= restored (diagram/change restored {"action" "append" "command" "fold src"}))
  (t/is= (array ;lines "hide src") (diagram/change lines {"action" "append" "command" "hide src"}))
  (t/is= ["fold src" "#fold src"]
    (diagram/change ["fold src" "#fold src"] {"action" "append" "command" "fold src"})))

(t/test "un matches parsed commands while preserving paths, colors, and comments"
  (def lines ["fold src" " fold  \"src\" # keep" "#fold src" "fold src.web" "fold src2" "box src blue"])
  (t/is= ["#fold src" "fold src.web" "fold src2" "box src blue"]
    (diagram/change lines {"action" "append" "command" "unfold src"}))
  (t/is= ["fold src" "#fold src" "fold src.web" "fold src2" "box src blue"]
    (diagram/change lines {"action" "append" "command" "unbox src red"}))
  (each command ["un fold src" "un" "unfold" "ununfold src" "unlines extra" "unfold src\nunlines"]
    (t/ok (try (do (diagram/change lines {"action" "append" "command" command}) false) ([_] true)))))

(t/test "prefix renaming rewrites descendants at every level and preserves the rest of each line"
  (def lines ["box src" "  # fold src.server.parsers  # keep src" "box src.server red"
              "hide src.serverless" "only src/web" "@visualize markdown 1 /src/file"])
  (defn renamed [prefix label]
    (diagram/change lines {"action" "rename-prefix" "node" (string "p:" prefix) "label" label "base" (diagram/visible lines)}))
  (t/is= ["box source" "  # fold source.server.parsers  # keep src" "box source.server red"
          "hide source.serverless" "only source.web" "@visualize markdown 1 /src/file"] (renamed "src" "source"))
  (t/is= ["box src" "  # fold src.backend.parsers  # keep src" "box src.backend red"
          "hide src.serverless" "only src/web" "@visualize markdown 1 /src/file"] (renamed "src.server" "backend"))
  (t/is= ["box src" "  # fold src.server.readers  # keep src" "box src.server red"
          "hide src.serverless" "only src/web" "@visualize markdown 1 /src/file"] (renamed "src.server.parsers" "readers"))
  (t/is= lines (renamed "src" "src"))
  (t/is= lines (renamed "src.server" "server"))
  (t/is= ["box src" "  # fold src.source.backend.parsers  # keep src" "box src.source.backend red"
          "hide src.serverless" "only src/web" "@visualize markdown 1 /src/file"] (renamed "src.server" "source.backend"))
  (t/ok (try (do (renamed "src.server" "source/backend") false) ([_] true))))

(t/test "renaming joins branches, quotes paths, and rejects stale or invalid edits"
  (def lines ["box src" "box source" "fold src.web" "fold source.web" "#fold source.web"])
  (t/is= ["box source" "fold source.web" "#fold source.web"]
    (diagram/change lines {"action" "rename-prefix" "node" "p:src" "label" "source" "base" lines}))
  (def quoted ["box \"src.web\" blue # note" "fold src.web.parsers"])
  (t/is= ["box \"my source.web\" blue # note" "fold \"my source.web.parsers\""]
    (diagram/change quoted {"action" "rename-prefix" "node" "p:src" "label" "my source" "base" quoted}))
  (each label ["" "..." "a..b" ".a" "a." "a. .b" "a/b" "bad\nline" "bad\"quote"]
    (t/ok (try (do (diagram/change lines {"action" "rename-prefix" "node" "p:src" "label" label "base" lines}) false) ([_] true))))
  (t/ok (try (do (diagram/change lines {"action" "rename-prefix" "node" "p:src" "label" "source" "base" ["box src"]}) false) ([_] true)))
  (t/ok (try (do (diagram/change lines {"action" "rename-prefix" "node" "c0" "label" "source" "base" lines}) false) ([_] true))))

(t/test "renaming a segment merges sibling branches without changing their parent"
  (def lines ["box src.server" "box src.backend" "fold src.server.parsers" "fold src.backend.parsers" "box other.server"])
  (t/is= ["box src.backend" "fold src.backend.parsers" "box other.server"]
    (diagram/change lines {"action" "rename-prefix" "node" "p:src.server" "label" "backend" "base" lines})))

(t/test "dotted renames introduce prefixes and merge matching descendant commands"
  (def lines ["box src.server" "fold src.server.parsers" "#hide src.server.parsers.deep"
              "box src.backend.api" "fold src.backend.api.parsers" "box other.server"])
  (def moved (diagram/change lines {"action" "rename-prefix" "node" "p:src.server"
                                    "label" "backend.api" "base" lines}))
  (t/is= ["box src.backend.api" "fold src.backend.api.parsers" "#hide src.backend.api.parsers.deep"
          "box other.server"] moved)
  (def graph (diagram/model moved))
  (t/ok (index-of ["p:src" "p:src.backend"] (graph :edges)))
  (t/ok (index-of ["p:src.backend" "p:src.backend.api"] (graph :edges)))
  (t/ok (not (find |(= ($ :id) "p:src.server") (graph :nodes))))
  (t/is= ["box project.src" "fold project.src.web"]
    (diagram/change ["box src" "fold src.web"] {"action" "rename-prefix" "node" "p:src"
      "label" "project.src" "base" ["box src" "fold src.web"]})))

(t/test "graph edits synchronize file views and preserve recovered panes"
  (def root (string "/tmp/vz-config-graph-" (os/getpid)))
  (os/mkdir root)
  (def file (string root "/visualize_config"))
  (spit file "box b\nbox b.a\nbox  \"b\"\n")
  (def w (worker/start root (fn [_] nil)))
  (defer (do (:stop w) (os/rm file) (os/rmdir root))
    (defn edit [sent] (json/decode (:call w :edit (merge sent {"file" file "diagram" true}))))
    (def first (edit {"action" "reload"}))
    (t/is= ["box b" "box b.a"] (first "lines"))
    (def duplicate (edit {"action" "append" "command" "box b"}))
    (t/is= (first "lines") (duplicate "lines"))
    (t/is= (first "diagram") (duplicate "diagram"))
    (t/is= "box b\nbox b.a\n" (string (slurp file)))
    (t/is= (first "diagram") ((edit {"action" "reload"}) "diagram"))
    (:call w :notes [["1" "/tmp/test.sock"]])
    (:call w :markdown {"1" file})
    (edit {"action" "append" "command" "fold b"})
    (edit {"action" "append" "command" "lines"})
    (def current (edit {"action" "reload"}))
    (t/is= "lines" (last (current "lines")))
    (t/ok (try (do (edit {"action" "subtree-delete" "node" "p:b" "base" (first "lines")}) false) ([_] true)))
    (edit {"action" "subtree-comment" "node" "p:b" "base" (current "lines")})
    (def disk (config/read-config file))
    (t/ok (index-of "#box b" disk))
    (t/ok (index-of "#box b.a" disk))
    (t/ok (index-of "#fold b" disk))
    (t/is= [["1" "/tmp/test.sock"]] (config/terminals disk))
    (t/is= {"1" file} (config/markdown disk))
    (def before (slurp file))
    (edit {"action" "reload"})
    (t/is= before (slurp file))
    (def renamed (edit {"action" "rename-prefix" "node" "p:b" "label" "renamed"
                       "base" ((edit {"action" "reload"}) "lines")}))
    (t/ok (index-of "#box renamed.a" (renamed "lines")))
    (t/is= (renamed "lines") ((edit {"action" "reload"}) "lines"))
    (t/is= [["1" "/tmp/test.sock"]] (config/terminals (config/read-config file)))))
