(import ../../src.server/command)
(import ./harness :as t)

(t/test "file command quotes the path independently from the user's command"
  (def path "/tmp/a 'quoted' $(touch never) `false` ü.txt")
  (def args (command/argv "/bin/sh" "printf '%s'" path))
  (t/is= ["/bin/sh" "-l" "-i" "-c"] (slice args 0 4))
  (def child (os/spawn ["/bin/sh" "-c" (args 4)] :p {:out :pipe}))
  (t/is= path (string (:read (child :out) :all)))
  (:close (child :out))
  (t/is= 0 (os/proc-wait child)))

(t/test "file command rejects an empty command"
  (t/ok (try (do (command/argv "/bin/sh" "  " "/tmp/file") false) ([_] true))))
