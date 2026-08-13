# The harness session: a pty, a pump thread, and the backlog a page reads.
#
# Driven with /bin/sh rather than a real agent, for the same reasons the pty
# tests are: no API calls, no network, and the code path is identical -- the
# module takes argv and never asks what it is running.

(import ../src/harness)
(import ./harness :as check)

(defn- wait-for
  ``Poll until `ready?` passes or the patience runs out.

  A pty splits its output wherever it likes, so a fixed sleep is a race that
  passes on an idle machine. Returns whatever the last read produced.``
  [ready? &opt tries]
  (default tries 40)
  (var seen "")
  (var found false)
  (var n 0)
  (while (and (not found) (< n tries))
    (++ n)
    (ev/sleep 0.05)
    (def [text _] (harness/since 0))
    (set seen text)
    (when (ready? text) (set found true)))
  [found seen])

(check/test "a session starts, reports itself, and stops"
  (def started (harness/start ["/bin/sh" "-c" "echo READY; sleep 5"] (os/cwd) 24 80))
  (check/ok (started :running))
  (check/is= ["/bin/sh" "-c" "echo READY; sleep 5"] (started :argv))
  (def [found _] (wait-for |(string/find "READY" $)))
  (check/ok found "output reaches the backlog")
  (harness/stop)
  (check/ok (not ((harness/state) :running)) "and stopping really stops it"))

(check/test "since replays for a reload and returns only new output after that"
  # The property a page reload depends on: everything from 0, nothing twice.
  (harness/start ["/bin/sh" "-c" "echo ONE; sleep 5"] (os/cwd) 24 80)
  (wait-for |(string/find "ONE" $))
  (def [text at] (harness/since 0))
  (check/ok (string/find "ONE" text) "a fresh page gets the whole session")
  (def [again _] (harness/since at))
  (check/is= "" again "and a live page gets nothing it has already seen")
  (harness/stop))

(check/test "typing reaches the program"
  (harness/start ["/bin/sh" "-i"] (os/cwd) 24 80)
  (ev/sleep 0.3)
  (harness/send "echo TYPED-THROUGH\n")
  # The echoed command contains the word too, so wait for it on a line of its
  # own -- which is the output rather than the echo.
  (def [found _] (wait-for |(string/find "\nTYPED-THROUGH" $)))
  (check/ok found)
  (harness/stop))

(check/test "resize reaches the program"
  (harness/start ["/bin/sh" "-i"] (os/cwd) 24 80)
  (ev/sleep 0.3)
  (harness/resize 40 120)
  (ev/sleep 0.2)
  (harness/send "stty size\n")
  (def [found _] (wait-for |(string/find "40 120" $)))
  (check/ok found "the harness sees the new window size")
  (harness/stop))

(check/test "starting again replaces the session and bumps the generation"
  # The page watches this number: a change means its screen belongs to a dead
  # session and has to be thrown away rather than appended to.
  (def first (harness/start ["/bin/sh" "-c" "sleep 5"] (os/cwd) 24 80))
  (def second (harness/start ["/bin/sh" "-c" "sleep 5"] (os/cwd) 24 80))
  (check/ok (> (second :generation) (first :generation)))
  (check/is= 0 (second :chunks) "the backlog starts empty for a new session")
  (harness/stop))

(check/test "a program that exits is reported as not running"
  (harness/start ["/bin/sh" "-c" "echo BYE"] (os/cwd) 24 80)
  (wait-for |(string/find "BYE" $))
  # `since` drains the channel, which is where the end-of-file arrives.
  (var still true)
  (for i 0 40
    (when still
      (ev/sleep 0.05)
      (harness/since 0)
      (set still ((harness/state) :running))))
  (check/ok (not still) "the session reports itself finished")
  (harness/stop))

(check/test "sending to a stopped session is harmless"
  # The page can always race the program's exit, and a crash there would take
  # the whole server down with it.
  (harness/stop)
  (check/is= nil (harness/send "nothing is listening\n"))
  (check/is= nil (harness/resize 10 10)))
