# A test harness in forty lines, because a dependency is a dependency.
#
# `visualize` ships its own runtime and nothing else, so pulling in a test
# framework to check a colour ramp would be the one thing in the tree that
# needed fetching. These four functions are all the suite uses.

(var- passed 0)
(var- failed @[])
(var- current "")

(defn- begin [name] (set current name))

(defmacro test
  ``Run a named group of checks.

  A macro rather than a function: the body has to run AFTER the group name is
  set, and a function would evaluate its arguments before being called -- so
  every failure would be filed under the previous group's name.

  A failing assertion is collected rather than thrown, so one bad check does
  not hide the twenty after it.``
  [name & body]
  ~(do (,begin ,name) ,;body))

(defn ok
  "Assert a truthy value."
  [value &opt why]
  (if value
    (++ passed)
    (array/push failed (string current ": " (or why "expected a truthy value"))))
  value)

(defn- frozen
  ``A value with mutability normalised away, recursively.

  `deep=` treats @{} and {} as different, and every function here that builds
  a table returns the mutable one while every expectation is written as a
  literal struct. Comparing those directly fails on the container type rather
  than on the contents, which is never the thing under test.``
  [value]
  (case (type value)
    :table (struct ;(mapcat |[(frozen $) (frozen (value $))] (keys value)))
    :struct (struct ;(mapcat |[(frozen $) (frozen (value $))] (keys value)))
    :array (tuple ;(map frozen value))
    :tuple (tuple ;(map frozen value))
    :buffer (string value)
    value))

(defn is=
  ``Assert equality, reporting BOTH values on failure.

  Compares by VALUE, not by container type: `deep=` says @{"a" 1} and
  {"a" 1} differ, and since the code returns mutable tables while the
  expectations are written as literals, that difference would fail every
  assertion for a reason that has nothing to do with the code.``
  [expected actual &opt why]
  (if (deep= (frozen expected) (frozen actual))
    (++ passed)
    (array/push failed
                (string current ": " (or why "mismatch")
                        "\n      expected " (string/format "%q" expected)
                        "\n      actual   " (string/format "%q" actual))))
  actual)

(defn report
  "Print the tally and exit non-zero if anything failed, so `jpm`/CI notice."
  []
  (if (empty? failed)
    (printf "  ok  %d assertions" passed)
    (do
      (printf "  FAIL  %d passed, %d failed" passed (length failed))
      (each line failed (print "    - " line))))
  (length failed))
