# A graph written out by hand, rather than read out of a program.
#
# Every other spec here answers "what does this FILE depend on", and the
# scan turns one file into one node. This one is different in kind: a
# `.visualize` file is not source that happens to have structure, it IS the
# structure, and one file describes as many nodes as it likes.
#
#     auth  the login service
#         database
#         crypto
#
#     database  where things are kept
#         disk
#
# A label at the left margin opens a block. What follows the label on that
# line is a description, and is read but not drawn -- see the note on
# `:nodes` below. Every indented line under it names something the block
# depends on.
#
# WHY THIS EXISTS. A drawing is useful before the code is, and there are
# things worth drawing that no parser can see: services behind an API, the
# order a migration has to run in, what a team owns. Written here, they get
# the same boxes, folds and prefixes as everything scanned -- the config
# language does not know or care which spec made a node.
#
# EVERY LABEL MENTIONED IS A NODE, whether or not it opens a block of its
# own. Writing `database` under `auth` is naming a thing; requiring a block
# before it counts would mean every leaf needs an empty stanza, and a file
# full of those says nothing the edges did not already say.

(import ../names)

# A label runs to the end of the word: what follows on the line is prose
# about it. Kept deliberately narrow -- a name a config can be written
# against, in the same alphabet a node name already uses.
(def- label-char '(+ (range "AZ") (range "az") (range "09") "_" "-" "."))

# The label at the head of a block, and the description after it. The
# description is captured so the shape of the line is checked rather than
# skipped; nothing draws it yet.
(def- heading
  ~(* (! (set " \t"))
      (<- (some ,label-char))
      (any (set " \t"))
      (<- (any (if-not "\n" 1)))))

# A dependency: indented, then a label, then nothing that matters.
(def- dependency
  ~(* (some (set " \t"))
      (<- (some ,label-char))
      (any (if-not "\n" 1))))

(defn- parse [text path]
  (def nodes @[])           # every label seen, in the order first seen
  (def seen @{})
  (def edges @[])           # [from to], as node names
  (var current nil)

  # PREFIXED BY THE FILE THEY CAME FROM, the way every scanned node is
  # prefixed by the directory it sits in. `auth` in `docs/services.visualize`
  # is `docs.services.visualize.auth`, so two files may both describe an
  # `auth` without colliding, and `(box docs.services.visualize)` boxes one
  # file's graph the way `(box src.web)` boxes a directory.
  #
  # THE STEM, not the file's node name: `.visualize` in the middle of every
  # label would be a segment that says nothing, since a declared node can
  # only have come from one kind of file. The extension is not lost -- it
  # goes under the title, at the small size, exactly as it does on a file
  # node (see `:extension` below and `label-markup` in layout.janet).
  (def prefix (names/safe-name (names/stem (or path ""))))
  (defn note [label]
    (def name (if (empty? prefix)
                (names/safe-name label)
                (string prefix "." (names/safe-name label))))
    (unless (seen name)
      (put seen name true)
      (array/push nodes name))
    name)

  (each line (string/split "\n" text)
    (cond
      # A blank line ends nothing -- a block runs until the next heading --
      # but it is the natural paragraph break and costs nothing to allow.
      (empty? (string/trim line)) nil

      # A COMMENT, because a hand-written file wants one. `#` is the
      # comment character every other plain-text format in this project
      # uses, including visualize.conf.
      (string/has-prefix? "#" (string/trim line)) nil

      # Indented: a dependency of whichever block is open. One with no
      # block above it is a line in a file that has not said what it is
      # about yet, and is dropped rather than guessed at.
      (peg/match ~(* (set " \t")) line)
      (when-let [hit (peg/match dependency line)
                 label (first hit)]
        (when current
          (def to (note label))
          (unless (= to current) (array/push edges [current to]))))

      # Anything else opens a block.
      (when-let [hit (peg/match heading line)
                 label (first hit)]
        (set current (note label)))))

  # `:nodes` IS WHAT MAKES THIS SPEC DIFFERENT, and the scan reads it only
  # when it is there -- a spec that does not report nodes still gets the one
  # node its file always got. See `build` in scan.janet.
  #
  # `:edges` likewise: they are already node names on both ends, because
  # this file names its own nodes and nothing has to be resolved against a
  # tree of files.
  # THE EXTENSION EVERY DECLARED NODE WEARS. It is the same for all of them
  # -- they all came from this file -- so it is reported once rather than
  # repeated onto each name, and `build` puts it on the labels.
  {:nodes nodes :edges edges :extension (names/extension (or path ""))})

(def spec
  {:name "visualize"
   :ext [".visualize"]
   :parse parse})
