# Finding the parser specs, at runtime, from the parsers directory.
#
# Loaded by looking rather than by a hardcoded list, so adding a language is
# adding a file -- no registry to update, nothing here to edit. That is the
# whole "parser is the only language-specific thing" claim made real: this
# file is the last one that knows parsers exist, and it does not know what any
# of them are.

(defn load
  ``Every spec in `dir`, sorted by name.

  A parser file is a Janet module exporting `spec`. Anything else in the
  directory is ignored rather than fatal -- a README or a stray .swp should
  not stop the tool from starting.

  A file that FAILS to load is reported and skipped, for the same reason: one
  broken parser should cost you that language, not the program.``
  [dir]
  (def found @[])
  (each entry (sort (or (try (os/dir dir) ([_] @[])) @[]))
    (when (string/has-suffix? ".janet" entry)
      (def path (string dir "/" entry))
      (try
        (let [env (dofile path)
              entry (get env 'spec)
              # Two shapes, one meaning: a def compiles to {:value v}
              # normally and to a box -- {:ref @[v]} -- in dev mode (the
              # default), where
              # `*redef*` makes every binding an indirection so the repl can
              # swap it. A reader of environments has to accept both.
              spec (when entry (or (entry :value) (first (or (entry :ref) @[]))))]
          (if (and spec (spec :ext) (spec :name))
            (array/push found spec)
            (eprintf "skipping %s: no usable `spec` export" entry)))
        ([err] (eprintf "skipping %s: %s" entry (string err))))))
  (sorted-by |($ :name) found))

(defn claiming
  "The specs that claim at least one extension, for the startup banner."
  [specs]
  (string/join (map |($ :name) specs) ", "))
