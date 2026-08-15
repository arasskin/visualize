# A witness that survives what it watches.
#
# THE BLIND SPOT THIS EXISTS FOR: everything else in this codebase observes
# from inside the event loop -- the repl, the request handlers, every
# eprintf. When the loop itself stalls (a blocking FFI call, a take
# suspended on an emptied channel), all of it goes silent at exactly the
# moment there is something to say. The ~10-second scroll freezes hid
# behind that silence through four wrong theories; the instrument that
# finally caught them had to be bolted on. This is that instrument, kept.
#
# The design is a heartbeat crossing a thread boundary. A fiber ON the
# loop gives a beat every `cadence` seconds; a real OS thread takes them
# and measures the gap between arrivals. The thread does not share the
# loop, so a stalled loop cannot silence it -- the missing beats ARE the
# signal. It reports on recovery rather than during, because the gap's
# length is the diagnosis: exactly-a-deadline means a timeout wearing a
# disguise, variable-and-ending-with-output means a buffer refilling.

(defn start
  ``Watch this process's event loop. Prints one line per stall to stderr:

      <name>: event loop stalled 10.0s

  `cadence` is the heartbeat interval, `limit` the gap that counts as a
  stall. `notify`, if given, is a thread-chan that also receives each
  stall's duration -- the tests listen there, and a caller could.``
  [name &opt cadence limit notify]
  (default cadence 0.1)
  (default limit 0.5)
  (def beat (ev/thread-chan 8))
  # The heartbeat, on the loop being watched. The guard keeps a dead or
  # slow watchdog from ever blocking the patient: a give to a full thread
  # channel suspends, and a watchdog that could stall the loop it watches
  # would be this codebase's most ironic bug yet.
  (ev/go
    (fn []
      (forever
        (ev/sleep cadence)
        (when (< (ev/count beat) 4)
          (try (ev/give beat true) ([_] nil))))))
  (ev/thread
    (fn [[chan label gap-limit note]]
      (var last (os/clock :monotonic))
      (forever
        (ev/take chan)
        (def now (os/clock :monotonic))
        (def gap (- now last))
        (set last now)
        (when (> gap gap-limit)
          (eprintf "%s: event loop stalled %.1fs" label gap)
          (when note (try (ev/give note gap) ([_] nil))))))
    [beat name limit notify] :nt (ev/thread-chan 4))
  nil)
