# Which code is this process actually running?
#
# THE QUESTION THAT COST TWO DEBUGGING ROUNDS. The server and the
# supervisor are separate processes started at different moments; the page
# is a third party loaded at another. Fixes landed on disk while all three
# kept running the code they were born with, and the failures that
# followed were debugged as if the fixes were live. Nothing in the system
# could say "you are looking at yesterday's code".
#
# The stamp answers it: the newest modification time across the sources,
# formatted readably, captured ONCE at process start (module load is
# process start). Two processes with different stamps are running
# different code, and the page -- which receives both stamps with every
# poll -- says so in its state line. Mtimes rather than a git rev because
# the tool must work where git is absent, and because an edited file
# matters whether or not it was committed.

(def- root (os/realpath (string (dyn :current-file) "/../..")))

(defn- newest-in
  "The latest mtime among the files of `dir` that pass `keep?`."
  [dir keep?]
  (def names (or (try (os/dir dir) ([_] nil)) []))
  (var latest 0)
  (each name names
    (when (keep? name)
      (def when (or (os/stat (string dir "/" name) :modified) 0))
      (when (> when latest) (set latest when))))
  latest)

(defn compute
  "The stamp for the sources as they are on disk right now."
  []
  (def janet? |(string/has-suffix? ".janet" $))
  (def latest
    (max (newest-in root janet?)
         (newest-in (string root "/src") janet?)
         (newest-in (string root "/web") (fn [_] true))))
  (def d (os/date (math/floor latest)))
  (string/format "%d%02d%02d-%02d%02d%02d"
                 (d :year) (inc (d :month)) (inc (d :month-day))
                 (d :hours) (d :minutes) (d :seconds)))

# Captured at load, which is process start: this is the code THIS process
# runs, however long it lives and whatever lands on disk after.
(def born (compute))
