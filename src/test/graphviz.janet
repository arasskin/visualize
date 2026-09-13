(import ../../src.server/graphviz)
(import ./harness :as t)

(def- sample
  `digraph {
    graph [bgcolor="transparent"];
    subgraph cluster_outer {
      label="outer";
      subgraph cluster_inner {
        label="inner";
        a [class="folded fresh", color="#22a6f2",
           label=<hello &amp; world<BR/><FONT POINT-SIZE="8">.cljd 42</FONT>>];
      }
      b [label="café 日本語"];
    }
    a -> b;
  }`)

(t/test "embedded Graphviz needs neither dot nor installed plugins"
  (def saved-path (os/getenv "PATH"))
  (def saved-plugins (os/getenv "GVBINDIR"))
  (defer (do (os/setenv "PATH" saved-path) (os/setenv "GVBINDIR" saved-plugins))
    (os/setenv "PATH" "/nonexistent")
    (os/setenv "GVBINDIR" "/nonexistent")
    (def svg (graphviz/render sample))
    (each fragment ["<svg" "cluster_outer" "cluster_inner" "hello &amp; world"
                    ".cljd 42" "café 日本語" "folded fresh" "#22a6f2" `class="edge"`]
      (t/ok (string/find fragment svg) (string "preserves " fragment)))))

(t/test "malformed DOT returns diagnostics without breaking subsequent renders"
  (for i 0 20
    (def err (try (do (graphviz/render "digraph { a -> }") nil) ([e] (string e))))
    (t/ok (and err (string/find "syntax error" err)))
    (t/ok (string/find "<svg" (graphviz/render sample))))
  (t/ok (try (do (graphviz/render "digraph {}\0junk") false) ([_] true))))

(t/test "changing labels and layouts do not retain the previous drawing"
  (for i 0 30
    (def label (string "node_" i "_end"))
    (def svg (graphviz/render (string "digraph { a [label=\"" label "\"]; a -> b }")))
    (t/ok (string/find label svg))
    (t/ok (not (string/find "cluster_outer" svg))))
  (t/ok (string/find "<svg" (graphviz/render "digraph {}"))))

(t/test "Graphviz calls from concurrent workers stay isolated"
  (def results (ev/thread-chan 4))
  (def supervisors (ev/thread-chan 4))
  (for worker 0 4
    (ev/thread
      (fn [[out id]]
        (def answer (try
          (do
            (for i 0 15
              (def label (string "worker_" id "_render_" i))
              (def svg (graphviz/render (string "digraph { a [label=\"" label "\"]; a -> b }")))
              (unless (string/find label svg) (error "another worker's graph leaked into this result")))
            true)
          ([err] (string err))))
        (ev/give out answer))
      [results worker] :n supervisors))
  (for i 0 4 (t/is= true (ev/take results)))
  (for i 0 4 (ev/take supervisors)))
