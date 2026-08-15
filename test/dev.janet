# The dev repl: hot reload, post-mortem fibers, parked breakpoints, and a
# socket you can type at.
#
# The claims here were each verified against the vendored runtime before the
# module was written, because two of them fail SILENTLY when wrong: without
# `*redef*` set before compilation a reload changes no caller and everything
# still returns 200, and a debug signal under the ev scheduler is printed and
# dropped rather than delivered anywhere. These tests keep both facts pinned.

(import ../src/dev)
(import ./harness :as t)

(def tmp (string/trimr (or (os/getenv "TMPDIR") "/tmp") "/"))

(t/test "reload re-evaluates into the live environment"
  # The whole point of dev mode: a caller compiled BEFORE the edit sees the
  # definition that arrived after it. Requires *redef* at compile time, which
  # is why it is set here before the scratch module is required.
  (put root-env *redef* true)
  (def dir (string tmp "/visualize-dev-test-" (os/time) "-" (os/getpid)))
  (os/mkdir dir)
  (def path (string dir "/hotmod.janet"))
  (spit path "(defn answer [] 1)\n(defn wrapped [] (answer))\n")
  (def env (require path))
  # Under *redef* a binding is a box -- {:ref @[fn]} -- not a {:value fn};
  # that box IS the indirection that makes redefinition reach old callers.
  (defn call [sym]
    (def entry (env sym))
    ((or (entry :value) (first (entry :ref)))))
  (t/is= 1 (call 'wrapped))
  (spit path "(defn answer [] 2)\n(defn wrapped [] (answer))\n")
  (dev/reload "hotmod")
  (t/is= 2 (call 'wrapped) "the already-compiled caller sees the new definition")
  (put root-env *redef* nil)
  (os/rm path)
  (os/rmdir dir))

(t/test "reload refuses to pretend outside dev mode"
  # Without *redef* the reload would compile, return, and change no caller --
  # the failure mode is silence, so the guard has to be loud.
  (def [ok err] (protect (dev/reload "hotmod")))
  (t/ok (not ok))
  (t/ok (string/find "dev mode" (string err))))

(t/test "a crashing handler is banked with its stack"
  (array/clear dev/crashed)
  (def handler (dev/watched (fn [req]
                              (def local-x (* 2 (req :n)))
                              (error "boom"))))
  (def [ok err] (protect (handler {:n 21})))
  (t/ok (not ok) "the error still propagates, so the 500 still happens")
  (t/is= "boom" (string err))
  (t/is= 1 (length dev/crashed))
  # The bank holds the stack, not a transcript of it: locals included.
  (def frame (first (debug/stack (first dev/crashed))))
  (t/is= 42 (get-in frame [:locals 'local-x]))
  (array/clear dev/crashed))

(t/test "a breakpoint parks the request; continue releases it"
  (defn priced [x]
    (def doubled (* x 2))
    (+ doubled 1))
  # pc 3 is past the prologue: `doubled` is computed when the break fires.
  (debug/fbreak priced 3)
  (def handler (dev/watched (fn [req] (priced (req :n)))))
  (def done (ev/chan 1))
  (ev/go (fn [] (ev/give done (handler {:n 21}))))
  # The request is in flight; wait for it to hit the breakpoint and park.
  (var waited 0)
  (while (and (empty? dev/parked) (< waited 200))
    (ev/sleep 0.01)
    (++ waited))
  (t/is= 1 (length dev/parked))
  (def id (first (keys dev/parked)))
  # Mid-flight introspection: the parked fiber's locals are live.
  (def park (dev/parked id))
  (t/is= 42 (get-in (first (debug/stack (park :fiber))) [:locals 'doubled]))
  (debug/unfbreak priced 3)
  (dev/continue id)
  (t/is= 43 (ev/take done) "the parked request finishes with the right answer")
  (t/is= 0 (length dev/parked)))

(t/test "the socket repl evaluates, keeps state, and debugs its own errors"
  (def path (string tmp "/visualize-dev-repl-test.sock"))
  (def server (dev/serve path (make-env root-env) "test"))
  (def conn (net/connect :unix path))
  (defn read-until
    # Deadlined, because the failure mode of a repl test is a suite that
    # hangs forever at a prompt that never came.
    [what]
    (def got @"")
    (while (not (string/find what got))
      (ev/with-deadline 5
        (if-let [chunk (:read conn 4096)]
          (buffer/push-string got chunk)
          (error (string "connection closed waiting for " what)))))
    (string got))
  (t/ok (string/find "test:1:" (read-until "> ")) "a prompt arrives")
  (:write conn "(+ 40 2)\n")
  (t/ok (string/find "42" (read-until "42")))
  (:write conn "(def kept 7)\n")
  (read-until "> ")
  (:write conn "(* kept 6)\n")
  (t/ok (string/find "42" (read-until "42")) "definitions persist across forms")
  # An error opens the dot-command debugger ON the failed fiber, in-band.
  (:write conn "(error :kaboom)\n")
  (t/ok (string/find "kaboom" (read-until "debug[1]")) "the trace precedes the debugger")
  (:write conn "(.signal)\n")
  (t/ok (string/find ":kaboom" (read-until ":kaboom")) "dot-commands see the fiber")
  (:write conn "(quit)\n")
  (read-until "exiting debug[1]")
  (:write conn "(+ 1 1)\n")
  (t/ok (string/find "2" (read-until "2")) "back at the top repl afterwards")
  (:close conn)
  (:close server)
  (try (os/rm path) ([_] nil)))
