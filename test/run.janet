# Every test file, run in one process.
#
#     janet test/run.janet
#
# Imported rather than shelled out to, so the tally at the end is a tally of
# everything rather than one exit code per file.

(import ./harness :as t)
(import ./color)
(import ./config)
(import ./dot)
(import ./json)
(import ./pty)
(import ./scan)

(os/exit (t/report))
