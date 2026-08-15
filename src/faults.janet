# What went wrong lately, kept where the thing that can fix it will look.
#
# THE GAP THIS CLOSES. Server errors went to stderr, and stderr is the one
# place nobody working on this tool is looking: the agent lives in a pane
# inside the page, the supervisor's stderr goes to /dev/null unless a knob
# says otherwise, and a person only sees the terminal they launched from if
# they happen to still be looking at it. So a tool whose whole purpose is
# making a codebase visible was hiding its own failures.
#
# A ring in memory, not a file. These are for the session that is happening
# now -- the agent asks "what just broke?", gets the last few faults with
# their stacks, and fixes one. Anything worth keeping past a restart belongs
# in a commit message, and this project has plenty of those.
#
# Recording must never fail the request that reported it: a fault here is
# already a bad moment, and an error in the error path is how a server ends
# up with no error path at all.

(def- capacity 64)

(def faults
  "The ring, oldest first. Each entry {:at :kind :where :what :trace :count}."
  @[])

(defn- same? [entry kind where what]
  (and (= (entry :kind) kind)
       (= (entry :where) where)
       (= (entry :what) what)))

(defn record
  ``Note that something went wrong. `kind` groups it (:request, :parse,
  :harness), `where` is the path or subsystem, `what` the message, `trace`
  an optional string.

  REPEATS COLLAPSE. A failing poll fails several times a second, and sixty
  identical entries would push out the one different fault that explains
  them. An immediate repeat bumps a count and refreshes the time instead.``
  [kind where what &opt trace]
  (def last-entry (last faults))
  (if (and last-entry (same? last-entry kind where what))
    (do (put last-entry :count (inc (last-entry :count)))
        (put last-entry :at (os/time)))
    (do
      (array/push faults @{:at (os/time)
                           :kind kind
                           :where (string where)
                           :what (string what)
                           :trace trace
                           :count 1})
      (when (> (length faults) capacity) (array/remove faults 0))))
  nil)

(defn recent
  "The last `n` faults, newest last, as plain structs for the wire."
  [&opt n]
  (default n 10)
  (def from (max 0 (- (length faults) n)))
  (map (fn [entry]
         {"at" (entry :at) "kind" (string (entry :kind))
          "where" (entry :where) "what" (entry :what)
          "count" (entry :count) "trace" (or (entry :trace) "")})
       (slice faults from)))

(defn count-since
  "How many faults have been recorded since `at` (an os/time), repeats
  counted individually -- the number the page puts in its state line."
  [at]
  (var total 0)
  (each entry faults
    (when (>= (entry :at) at) (+= total (entry :count))))
  total)

(defn clear
  "Forget everything. For a repl session that has read what it needed."
  []
  (array/clear faults)
  nil)

(defn print-recent
  ``Print the last `n` faults for a person or an agent at the repl: one
  header line each, and the trace indented under it when there is one.``
  [&opt n]
  (default n 10)
  (def entries (recent n))
  (if (empty? entries)
    (print "no faults recorded")
    (each entry entries
      # NOT `when`: that is a macro, and binding over it turns the field
      # lookups below into a macro call that quietly answers nil. The
      # printf then fails on nil, inside the very function a person is
      # calling to find out what failed.
      (def clock (os/date (get entry "at") true))
      (printf "%02d:%02d:%02d  %s  %s%s"
              (clock :hours) (clock :minutes) (clock :seconds)
              (get entry "kind") (get entry "where")
              (if (> (get entry "count") 1)
                (string "  (x" (get entry "count") ")") ""))
      (printf "    %s" (get entry "what"))
      (when (not (empty? (get entry "trace")))
        (each line (string/split "\n" (string/trimr (get entry "trace")))
          (printf "    %s" line)))))
  nil)
