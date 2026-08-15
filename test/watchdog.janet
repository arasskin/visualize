# The watchdog: the one observer a stalled event loop cannot silence.
#
# The stall is manufactured the way the real bugs made them -- a busy-wait
# that never yields -- and the assertion listens on the notify channel
# rather than parsing stderr, which the reporting thread also prints to
# (the "test-loop" line in this suite's output is this test running, not a
# problem being reported).

(import ../src/watchdog)
(import ./harness :as t)

(t/test "the watchdog names a stalled event loop"
  (def heard (ev/thread-chan 4))
  (watchdog/start "test-loop" 0.02 0.2 heard)
  # Let the heartbeat establish before stalling.
  (ev/sleep 0.1)
  (def t0 (os/clock :monotonic))
  (while (< (- (os/clock :monotonic) t0) 0.5) nil)
  (def gap (ev/with-deadline 2 (ev/take heard)))
  (t/ok (> gap 0.4) "the reported stall covers the busy-wait")
  (t/ok (< gap 2) "and is not wildly inflated"))

(t/test "a healthy loop is never reported"
  (def heard (ev/thread-chan 4))
  (watchdog/start "quiet-loop" 0.02 0.2 heard)
  (ev/sleep 0.4)
  (t/is= 0 (ev/count heard) "beats flowing on time produce no reports"))
