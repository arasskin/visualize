# Every test file, run in one process.
#
#     janet src/test/core.janet
#
# Imported rather than shelled out to, so the tally at the end is a tally of
# everything rather than one exit code per file.
#
# A TEST FILE RUNS ITS CHECKS AT IMPORT TIME, so this list is also the order
# they run in -- and that order matters more than it should.
#
# `term` goes LAST because its tests spawn host processes, ptys and
# shells, and a module imported after them fails to load: Janet reports
# "could not read file" while reading the next source file, not while running
# any test. The suite is fine either side of that line; it is the loading that
# breaks. Rather than leave a trap for whoever adds the next test file, the
# rule is stated here: pure modules first, process-spawning ones after.
(import ./harness :as t)
(import ./color)
(import ./config)
(import ./select)
(import ./http)
(import ./json)
(import ./scan)
(import ./graph)
# These spawn real processes (and the watchdog a real thread). Nothing may
# be imported below them.

(os/exit (t/report))
