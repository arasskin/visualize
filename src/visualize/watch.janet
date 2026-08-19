# Noticing that the source changed, so nobody has to press a button.
#
# THE BUTTON THIS REPLACES. "Regenerate" existed because the scan is cached
# and something had to say when the cache was stale -- which made the person
# responsible for knowing that they had just edited a file, and made the
# graph wrong until they remembered. A tool for seeing a codebase should not
# need to be told the codebase changed.
#
# BY MTIME, NOT BY EVENT. No kqueue, no FSEvents, no inotify: those are three
# platform APIs behind an FFI this project would then own forever, and the
# question they answer -- "did anything change?" -- is answered well enough
# by walking the same file list the scan walks and comparing modification
# times. The walk is the cheap half of the scan (a stat per file, and the
# skip rules keep node_modules to one stat), and it runs a few times a
# second at most.
#
# ON THE EVENT LOOP, in an ordinary fiber. The walk is stat-bound and short;
# a thread would mean copying the spec list per tick and marshalling results
# back for no gain.

(import ./scan)

# THE CONFIG IS NOT IN THE LIST, and does not need excluding from it. Editing
# it through the page once closed a loop -- the page saved, the fingerprint
# moved, the watcher announced that the source had changed, the page redrew
# and saved again, and the server span at 7% CPU printing nothing -- but that
# was when the config was `config.janet` and the Janet parser claimed it.
# `visualize.conf` is an extension no parser claims, so `find-files` never
# returns it and the fingerprint never sees it.

(defn- fingerprint
  ``One number standing for the state of the tree: every file's mtime and
  size, summed with its path. Different content, different number -- and
  the same number for a tree nobody has touched, which is the common case
  and the one that has to be cheap.

  Size as well as mtime because a filesystem's mtime granularity is a
  second on some systems, and an edit that lands within the same second as
  the last one would otherwise look like nothing happened.``
  [root]
  (var sum 0)
  (var count 0)
  (each job (scan/find-files root)
    (def stats (os/stat (job :path)))
    (when stats
      (++ count)
      # The path contributes too, so a rename with identical timestamps is
      # still a change.
      (+= sum (+ (get stats :modified 0)
                 (get stats :size 0)
                 (length (job :rel)))))
  )
  [sum count])

(defn watching
  ``Watch `root` and call `changed` when the source has moved.

  Returns a function that stops the watch. `every` is the poll interval in
  seconds; the default is a compromise between noticing an edit quickly and
  not walking the tree constantly.

  The first fingerprint is taken WITHOUT firing: the tree existing is not a
  change, and a page that just loaded should not immediately be told to
  redraw what it is already showing.``
  [root changed &opt every]
  (default every 0.7)
  (var running true)
  (var last (fingerprint root))
  (ev/go
    (fn []
      (while running
        (ev/sleep every)
        (when running
          (def now (try (fingerprint root) ([_] nil)))
          (when (and now (not= now last))
            (set last now)
            # A failure in the callback must not end the watch: the next
            # edit deserves the same chance as this one.
            (try (changed) ([err] (eprintf "watch: %s" (string err)))))))))
  (fn [] (set running false)))
