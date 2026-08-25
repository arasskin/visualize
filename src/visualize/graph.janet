# The dependency graph: the first app built on visualize, and the one it
# needed for itself.
#
# THIS IS AN APP, NOT THE CORE, and the separation is the whole architecture.
# Visualize's core is an event loop, a repl, a harness holding an LLM, and
# facts on disk. What a program does with those -- what it draws, what it
# lets you edit, what it calls a node -- belongs to the program, and this
# file is the demonstration: a graph of a source tree, its config language,
# and the page that shows them. Delete it and the core still runs; write
# another one beside it and the core does not need to know.
#
# It reads the same scan.json every other consumer reads (see state.janet),
# which is what makes "an app that visualizes this project" a thing you can
# write without touching the server.

(import ./select)
(import ./names)
(import ./layout)

# THE ONE SPELLING of the file this program writes into the directory it is
# pointed at. src/visualize/watch.janet reads it from here rather than
# keeping its own copy -- it has to skip this file when fingerprinting the
# tree, and two copies of a filename is one that goes stale.
#
# `.conf` rather than `.janet`: the config stopped being Janet when it became
# a PEG, and a file named for a language it is not misleads anyone who opens
# it expecting to write one.
# WHAT THE LAST DRAWING SAW. Kept per-process rather than on disk: the
# comparison is "since you last looked", and a fresh page has not looked yet.
#
# Recorded on every draw whether or not `animate` asked for it, so turning
# the verb on mid-session compares against the drawing before it rather than
# against nothing.
(var- seen nil)

(defn- moved-since [stamps]
  ``Which nodes are new or have been written since the last drawing.

  Nothing on the FIRST draw -- there is no previous one to differ from, and
  flashing the whole graph on load would say only that the graph exists.``
  (def flashing @{})
  (when seen
    (eachp [name stamp] stamps
      (def before (seen name))
      (when (or (nil? before) (not= before stamp))
        (put flashing name true))))
  flashing)

(defn render-svg
  ``Draw the tree the config asks for. Returns [ok svg-or-error].

  THE TREE IS HANDED IN, not fetched. This module turns a scanned tree and a
  config into a picture, and holding neither means it cannot be wrong about
  when either is stale -- whoever owns the tree knows when it changed, and
  that is the server. It also means this file does not import the scanner.``
  [tree state]
  (if (tree :error)
    [false (tree :error)]
    (do
      # Narrow before hiding: (only ~) then (hide ~.Tests) reads the way
      # it is written, and hiding something already filtered out is a no-op
      # rather than an error.
      (def trimmed (select/drop-nodes (select/keep tree (state :only)) (state :hidden)))
      # COLLAPSE AFTER TRIMMING, before everything else. There is no point
      # folding nodes that `hide` already took off, and doing it here means
      # the alias relabelling and the line counts below see the folded
      # node rather than the members it replaced.
      #
      # The sizes come back changed, since a folded node carries the sum
      # of what it stands for.
      (def [folded sizes]
        (select/fold trimmed (state :folded) (tree :sizes)))
      # AN ALIAS RELABELS THE NODES IT COVERS. `(prefix ~ src.visualize)`
      # makes `src.visualize.color` read `~.color`, so the picture speaks the
      # vocabulary the config is written in -- which is most of the point of
      # naming a prefix at all, since the shared head is the part that is the
      # same on every node and tells you nothing.
      #
      # The NAME is untouched: it is the node's identity, what edges point at
      # and what the config matches. Only the label changes.
      (def aliased
        (if (empty? (state :aliases))
          folded
          (merge folded
                 {:nodes (map (fn [node]
                                (if-let [short (select/alias-label (state :aliases)
                                                                   (node :name))]
                                  # THE EXTENSION KEEPS ITS OWN ROW. This
                                  # rebuilds the label from the aliased
                                  # name, and splitting the whole thing on
                                  # dots would turn `~.color.janet` into
                                  # three equal segments -- putting the
                                  # extension back into the name at full
                                  # size, which is what it was just taken
                                  # out of. Held aside and re-appended with
                                  # its leading dot, the marker
                                  # `label-markup` looks for.
                                  (merge node
                                         {:label
                                          (let [cut (names/stem short)
                                                ext (names/extension short)
                                                rows (string/join
                                                       (string/split "." cut) ".\n")]
                                            (if ext (string rows "\n." ext) rows))})
                                  node))
                              (folded :nodes))})))
      # The label carries the line count when (lines) asked for it. Done
      # on the graph rather than in a renderer, so both layouts get it and
      # the text that goes between them already says what the box reads.
      (def labelled
        (if (state :sized)
          (merge aliased
                 {:nodes (map (fn [node]
                                (if-let [size (get sizes (node :name))]
                                  # In full: an abbreviated 1.3k rounds away
                                  # the difference between files a hundred
                                  # lines apart, which is the comparison the
                                  # number is on the box to support.
                                  (merge node {:label (string (node :label) "\n" size)})
                                  node))
                              (aliased :nodes))})
          aliased))
      # Compared before the record is updated, or every node would look
      # unchanged against a stamp taken moments ago.
      (def flashing (moved-since (tree :stamps)))
      (set seen (tree :stamps))
      # EVERY VERB IS RESOLVED BY HERE. `only` and `hide` took nodes off the
      # tree, `prefix` and `lines` rewrote labels, and this last step writes
      # each node's box, colour and flash onto the node -- so what goes to
      # the renderer is a tree that already answers every question a drawing
      # asks, and the renderer needs no opinion about the config.
      # The palette comes off the STATE, like every other thing the config
      # decided. A colour is a config choice, so which palette this drawing
      # uses arrives with the boxes rather than being fetched separately.
      (def resolved (select/resolve labelled (state :groups)
                                    (if (state :animated) flashing {})
                                    (state :palette)))
      (layout/draw resolved))))
