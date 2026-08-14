# The pseudo-terminal, tested against /bin/sh.
#
# DELIBERATELY NOT TESTED AGAINST A REAL HARNESS. Claude Code and pi both run
# through this unchanged -- that is the whole point of the module -- but a
# suite that spawned one would cost API calls, need network, and fail on a
# machine that has neither. `/bin/sh` proves every property that matters:
# that the child gets a REAL terminal, that typing reaches it, that the size
# can be changed, and that the thing dies when told to.

(import ../visualize/pty)
(import ./harness :as t)

(defn- capture
  ``Run a shell command on a pty and return everything it printed.

  The pump BLOCKS, so it gets its own thread -- see the note in visualize/pty.janet.
  Reading from the main thread instead is what starved the scheduler in
  development, and the symptom was a server that stopped answering while the
  terminal was busy.``
  [script &opt rows cols]
  (default rows 24)
  (default cols 80)
  (def out-chan (ev/thread-chan 512))
  (ev/thread
    (fn [[chan lines columns text]]
      (def session (pty/open ["/bin/sh" "-c" text] lines columns))
      (pty/pump session (fn [chunk] (ev/give chan chunk)))
      (ev/give chan :eof)
      :done)
    [out-chan rows cols script] :nt (ev/thread-chan 4))
  (def seen @"")
  (var running true)
  (while running
    (def chunk (ev/take out-chan))
    (if (string? chunk)
      (buffer/push-string seen chunk)
      (set running false)))
  (string seen))

(t/test "the child gets a REAL terminal, not a pipe"
  # The whole reason this module exists. An agent harness checks isatty() and
  # behaves completely differently when the answer is no -- piped, Claude Code
  # answers once and exits instead of running its TUI.
  (def out (capture "test -t 0 && echo IS_TTY; tty"))
  (t/ok (string/find "IS_TTY" out) "isatty() must be true inside the child")
  (t/ok (string/find "/dev/tty" out) "the child is attached to a tty device"))

(t/test "a terminal ends lines with CRLF"
  # The give-away that this is a terminal rather than a pipe: the line
  # discipline translates \n into \r\n on the way out.
  (t/ok (string/find "\r\n" (capture "echo hello"))))

(t/test "the window size reaches the child"
  (def out (capture "stty size" 40 120))
  (t/ok (string/find "40 120" out)
        "forkpty's winsize argument is what the child sees"))

(t/test "typing reaches the program and its output comes back"
  (def out-chan (ev/thread-chan 512))
  (def ready (ev/thread-chan 4))
  (ev/thread
    (fn [[rc oc]]
      (def session (pty/open ["/bin/sh" "-i"] 24 80))
      (ev/give rc session)
      (pty/pump session (fn [chunk] (ev/give oc chunk)))
      (ev/give oc :eof)
      :done)
    [ready out-chan] :nt (ev/thread-chan 4))
  (def session (ev/take ready))
  (def seen @"")
  (ev/sleep 0.4)
  (pty/write-input session "echo TYPED-OK\n")
  # Read until the answer shows up rather than for a fixed number of chunks.
  # A pty splits output wherever it likes -- the echoed command and its result
  # may arrive together or several reads apart -- so counting chunks is a race
  # that passes on a quiet machine and fails on a busy one.
  (var found false)
  (var reads 0)
  (while (and (not found) (< reads 40))
    (++ reads)
    (def chunk (ev/take out-chan))
    (if (string? chunk)
      (do (buffer/push-string seen chunk)
          # The echoed input contains the string too, so only a line that is
          # the OUTPUT counts: the shell echoes `echo TYPED-OK`, and the
          # result is the bare word on a line of its own.
          (when (string/find "\nTYPED-OK" (string seen)) (set found true)))
      (break)))
  (pty/write-input session "exit\n")
  (t/ok found "what was written to the pty was executed by the shell")
  (pty/close session))

(t/test "resize is applied by the kernel"
  # Checked against the DEVICE rather than by asking the program, because a
  # long-running shell caches the size it started with and only a full-screen
  # program redraws on SIGWINCH. The kernel is the authority here.
  #
  # This is also the test that would have caught the ioctl problem: the FFI
  # path returned success while changing nothing, because `ioctl` is variadic
  # and libffi cannot call it on arm64. `resize` uses `stty` for that reason.
  (def ready (ev/thread-chan 4))
  (def out-chan (ev/thread-chan 512))
  (ev/thread
    (fn [[rc oc]]
      (def session (pty/open ["/bin/sh" "-i"] 24 80))
      (ev/give rc session)
      (pty/pump session (fn [chunk] (ev/give oc chunk)))
      (ev/give oc :eof)
      :done)
    [ready out-chan] :nt (ev/thread-chan 4))
  (def session (ev/take ready))
  (ev/sleep 0.3)
  (t/ok (pty/resize session 40 120) "stty reported success")
  (ev/sleep 0.2)
  (def asked (os/spawn ["stty" "-f" (session :device) "size"] :px {:out :pipe}))
  (def answer (string/trim (or (:read (asked :out) :all) "")))
  (os/proc-wait asked)
  (t/is= "40 120" answer "the kernel agrees the terminal is now this size")
  (pty/close session))

(t/test "a session reports the device it is attached to"
  # Needed by `resize`, and worth asserting on its own: without the device
  # path there is no non-variadic way to set the window size at all.
  (def ready (ev/thread-chan 4))
  (ev/thread
    (fn [rc]
      (def session (pty/open ["/bin/sh" "-c" "sleep 5"] 24 80))
      (ev/give rc session)
      :done)
    ready :nt (ev/thread-chan 4))
  (def session (ev/take ready))
  (t/ok (string/has-prefix? "/dev/" (session :device)))
  (t/ok (> (session :pid) 0))
  (pty/close session))

(t/test "closing a session stops the program"
  (def ready (ev/thread-chan 4))
  (ev/thread
    (fn [rc]
      (ev/give rc (pty/open ["/bin/sh" "-c" "sleep 30"] 24 80))
      :done)
    ready :nt (ev/thread-chan 4))
  (def session (ev/take ready))
  (t/ok (pty/alive? session) "it is running before being closed")
  (pty/close session)
  (ev/sleep 0.4)
  # alive? also reaps, so a closed child does not linger as a zombie.
  (t/ok (not (pty/alive? session)) "and gone afterwards"))

(t/test "the harness is argv, not a code path"
  # The coupling claim, asserted: nothing in this module names a program. If
  # this passes for `echo` it passes for `claude` and `pi`, which were both
  # driven through the same code during development.
  (t/ok (string/find "from-any-program" (capture "echo from-any-program"))))
