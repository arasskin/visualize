# Shell: the files a script reaches for, read as paths rather than as names.
#
# THE ODD ONE OUT. Every other parser here resolves a symbolic name the
# language itself defines -- `otto.store`, `github.com/lib/pq`, `./store`.
# Shell has no such thing. A script names files by PATH, assembled at runtime
# out of variables, and there is no declaration anywhere saying what those
# paths will be. So this reads the paths it can see written down and says
# nothing about the rest.
#
# WHAT IT CATCHES: `source lib/util.sh` and its `.` spelling, a script run
# directly (`./build`, `bash scripts/deploy.sh`), and paths behind a single
# variable (`"$here/build"`). What it misses is everything assembled at
# runtime -- `"$dir/$name.sh"`, a path in an array, anything a case statement
# picks. That is not a gap to be closed later; it is what a text scan of a
# language with no declarations can honestly claim.

(def- space '(some (set " \t")))
(def- line-start '(+ (> -1 "\n") (! (> -1 1))))

# A path's characters, minus what would end it in shell: whitespace, quotes,
# and the operators that separate commands. `$` is IN, because a path may
# carry a variable and `strip-var` below deals with it.
(def- path-char '(if-not (+ (set " \t\n\"'();|&<>`") -1) 1))
(def- path ~(some ,path-char))

# The same path, with the quotes around it consumed if they are there, so a
# quoted and a bare path capture identically.
(def- quoted-path ~(+ (* `"` (<- ,path) `"`) (* "'" (<- ,path) "'") (<- ,path)))

# A path with a slash in it, which is what makes shell run a file rather than
# look one up on PATH. Requiring the slash is also what keeps `$0` out: a
# variable alone is a name, not a location.
#
# The slash is checked by LOOKAHEAD rather than matched in sequence. `(some
# path-char)` is greedy and a PEG does not backtrack inside it, so a rule
# written `(some path-char) "/" path` consumes the slash and then has nothing
# to match it with -- it never fires at all.
(def- no-slash '(if-not (+ (set " \t\n\"'();|&<>`") "/" -1) 1))
(def- slashed-path
  ~(* (? `"`) (> 0 (* (any ,no-slash) "/")) (<- ,path) (? `"`)))

# The same shape, matched but NOT captured -- for stepping over an
# interpreter to reach the script it was given.
(def- slashed-bare
  ~(* (? `"`) (> 0 (* (any ,no-slash) "/")) ,path (? `"`)))

# `$here/build` is `build` relative to the script -- and so is `${here}/build`
# and `"$here"/build`. ONE LEADING VARIABLE ONLY: a script's first variable is
# almost always where it lives, computed a line or two up from `dirname $0`,
# and dropping it turns the commonest shell idiom into a real edge.
#
# A HEURISTIC, and the only one here. It is wrong when the variable means
# something else -- `$PREFIX/bin/tool` becomes `bin/tool`, which may be a file
# in this repo and may not. The trade is deliberate: without it a script like
# this repo's own ./visualize, where every path is "$here/...", yields nothing
# at all. A variable ANYWHERE ELSE in the path leaves it alone, because
# `$dir/$name.sh` names a file no scan can know.
(defn- strip-var [text]
  (def peeled (string/trim text `"'`))
  (def cut (peg/match ~(* (+ (* "${" (some (if-not "}" 1)) "}")
                             (* "$" (some (+ (range "AZ") (range "az")
                                             (range "09") "_"))))
                          "/" (<- (any 1)) -1)
                      peeled))
  (def rest (if cut (first cut) peeled))
  # A variable left in the remainder means the path is assembled at runtime.
  (if (string/find "$" rest) nil rest))

# WHICH DIRECTORY A PATH IS RELATIVE TO depends on how it was written, and
# the two cases resolve differently.
#
# A path written plainly -- `source lib/util.sh` -- is relative to the script,
# because that is what shell does with it. It keeps a `./` so the scanner
# resolves it against the importing file; see resolve-relative in
# src/visualize/scan.janet.
#
# A path that came from a VARIABLE is not. `$here` is computed, and computed
# from `dirname $0` plus however many `..` the script needed -- this repo's
# src/test/run walks up two levels, so its `"$here/build"` means the root and
# not src/test/build. There is no way to know how far up from the text, so a
# stripped path is treated as ROOT-relative: that is what a `$here` is for.
# Emitted without the leading dot, which is how the scanner tells the two
# apart, and with a SCRIPT extension dropped since node names carry none.
# Only the extensions this parser can have produced: a `.c` reached by a
# misfiring variable strip stays `.c`, so it reads as the foreign file it is
# rather than as a node pretending to be ours.
(def- script-exts [".sh" ".bash" ".janet"])

(defn- drop-ext [text]
  (var out text)
  (each ext script-exts
    (when (string/has-suffix? ext out)
      (set out (string/slice out 0 (- (length out) (length ext))))))
  out)

(defn- as-relative [text]
  (def trimmed (string/trim text `"'`))
  (def rooted (not= trimmed (string/trim (or (strip-var text) "") `"'`)))
  (when-let [bare (strip-var text)]
    (def path (string/trim bare `"'`))
    (cond
      (empty? path) nil
      # An absolute path is somewhere else on the machine, not in this tree.
      (string/has-prefix? "/" path) nil
      rooted (drop-ext path)
      (string/has-prefix? "." path) path
      (string "./" path))))

# `:parse` receives RAW text -- the engine's comment blanking is for specs
# that hand it a PEG, and a spec with :parse takes over completely (see
# src/visualize/parser.janet). So the comments come out here, or the shebang
# and every path mentioned in a usage comment become edges.
#
# Blanked rather than deleted, so a `#` inside a quoted string is left alone
# by the quote-tracking and offsets do not shift.
(defn- decommented [text]
  (def out (buffer text))
  (var i 0)
  (var quote nil)
  (while (< i (length out))
    (def ch (out i))
    (cond
      quote (when (= ch quote) (set quote nil))
      (or (= ch (chr `"`)) (= ch (chr "'"))) (set quote ch)
      (= ch (chr "#"))
      (while (and (< i (length out)) (not= (out i) (chr "\n")))
        (put out i (chr " "))
        (++ i)))
    (++ i))
  (string out))

(defn- parse [raw _path]
  (def text (decommented raw))
  # THREE SHAPES, each matched on its own rather than by one loose pattern.
  # A single alternation that tried to cover all of them caught `$0` out of
  # `dirname "$0"` and missed every quoted path, because a rule that admits
  # quotes cannot also stop at them.
  #
  #   source lib/util.sh      a script pulled into this one
  #   bash scripts/deploy.sh  a script run by an interpreter
  #   ./build                 a script run directly
  #
  # Quotes are stripped by the capture rather than excluded from it, so
  # `"$here/build"` and `$here/build` read the same.
  (def found @[])
  # The rule captures the PATH, not the match: `(<- rule)` around the whole
  # thing hands back "source ./lib/util.sh" rather than the file.
  (defn collect [rule]
    (each hit (or (peg/match ~(any (+ ,rule 1)) text) [])
      (when-let [rel (as-relative hit)]
        (array/push found rel))))

  # `source x` and `. x`, at the head of a line or after a separator. The `.`
  # form needs the space: `.foo` is a filename, `. foo` is the command.
  (collect ~(* (+ ,line-start (set ";&|"))
               (any (set " \t"))
               (+ (* "source" ,space) (* "." ,space))
               ,quoted-path))

  # An interpreter given a script. Two shapes: a named one (`bash x.sh`), and
  # a path in command position followed by another path (`"$here/janet"
  # "$here/src/core.janet"`) -- which is how a script runs an interpreter it
  # shipped with. Without the second, `exec "$here/janet" "$here/core.janet"`
  # yields the interpreter and loses the script it was handed.
  (collect ~(* (+ ,line-start (set ";&|(") (set " \t"))
               (+ "bash" "sh" "zsh")
               ,space
               ,quoted-path))
  (collect ~(* (+ ,line-start (set ";&|("))
               (any (set " \t"))
               (? (* "exec" ,space))
               ,slashed-bare
               ,space
               ,slashed-path))

  # A script run directly, which in shell means a path with a slash in it.
  #
  # IN COMMAND POSITION ONLY -- the head of a statement, optionally behind
  # `exec`. Matching a slashed path anywhere would read `cp src/a.sh dst/` as
  # depending on both, and every path an `echo` mentions as a dependency.
  # What runs a file is being the command.
  (collect ~(* (+ ,line-start (set ";&|("))
               (any (set " \t"))
               (? (* "exec" ,space))
               ,slashed-path))

  {:imports (distinct found)})

(def spec
  {:name "bash"
   :ext [".sh" ".bash"]

   # A shell script is as often `build` as `build.sh`. Consulted only for a
   # file with no extension -- see parser/claims?. `env` is here because
   # `#!/usr/bin/env bash` is the portable spelling and the commonest one.
   :shebang ["sh" "bash" "zsh" "dash" "ksh"]

   # Comments to end of line, and heredocs whole: a heredoc body is data the
   # script prints, and a path inside one is being written rather than read.
   :comments ~(+ (* "#" (any (if-not "\n" 1)))
                 (* "<<" (? "-") (? (set `"'`)) (some (+ (range "AZ") (range "az")
                                                         (range "09") "_"))
                    (any (if-not "\n" 1))
                    (any (if-not "\n" 1))))

   :noise ~(+ (* "#" (any (if-not "\n" 1)))
              (* `"` (any (+ (* "\\" 1) (if-not (+ `"` "\n") 1))) `"`)
              (* "'" (any (if-not (+ "'" "\n") 1)) "'"))

   :parse parse})
