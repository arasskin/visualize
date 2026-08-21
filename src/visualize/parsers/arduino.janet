# Arduino: includes are real, and the sketch's own tabs are not included at all.
#
# TWO HALVES, because Arduino has two kinds of file and they behave
# differently.
#
# `#include <Servo.h>` and `#include "pins.h"` are ordinary C preprocessor
# includes: authoritative, one per line, and the angle/quote distinction is
# about the search path rather than about what depends on what. Both are
# captured whole, with the extension left on -- `safe-name` drops it, so an
# include lands on the same node a file of that name would make. Today both
# forms draw externals, since this spec claims sketches only and no C spec
# owns the headers yet; the day one does, the internal edges appear with no
# change here.
#
# THE .ino FILES SEE EACH OTHER WITH NOTHING WRITTEN DOWN. The IDE
# concatenates every tab in a sketch folder into one translation unit before
# compiling, so a second tab's function is callable from the first with no
# include anywhere -- which is exactly Swift's problem, and it gets Swift's
# answer: a file DECLARES some names, and a file that MENTIONS another's name
# depends on it. Scraping includes alone would draw the libraries and miss
# every edge between the sketch's own tabs, which is the structure worth
# looking at.
#
# WHAT COUNTS AS A DECLARATION is narrow on purpose. A C++ scan that claims
# every identifier invents edges, and this tool would rather lose one than
# invent one -- see the note on `extension` in the Swift spec, which is the
# same trade made for the same reason.

(def- line-start '(+ (> -1 "\n") (! (> -1 1))))
(def- space '(any (set " \t")))

(def- ident-start '(+ (range "AZ") (range "az") "_"))
(def- ident-rest '(any (+ (range "AZ") (range "az") (range "09") "_")))
(def- ident ~(* ,ident-start ,ident-rest))

# A keyword is only a keyword when a word boundary follows, so `classes` is
# not read as `class` and `structure` is not read as `struct`.
(def- word-end '(not (+ (range "AZ") (range "az") (range "09") "_")))

# The types another file can name. Same list as Swift's, minus what C++ has
# no word for, plus `namespace` -- which is a name other tabs qualify with.
(def- kinds '(+ "class" "struct" "enum" "union" "namespace"))

# THE RETURN TYPE OF A FREE FUNCTION, which is what a sketch is mostly made
# of: `void blinkLed()` in a second tab is called from the first by name, and
# refusing to see it would leave the sketch's own edges undrawn -- the very
# thing the declares/refs model exists for.
#
# Kept to a fixed list of type words rather than "any identifier followed by
# any identifier", because the loose form matches two ordinary statements in
# a row and hands the file a declaration it never made.
#
# `unsigned` AND `signed` TAKE A SECOND WORD, and both halves have to be
# eaten here: matching `unsigned` alone leaves `long lastAt()` looking like
# the type `long` and the name... `lastAt`, which happens to work, and like
# `unsigned int count()` looking like the name `int` followed by `count`,
# which does not. So the width word is consumed with them when present.
(def- width '(+ "long long" "long" "int" "short" "char"))
(def- return-type
  ~(* (opt (* (+ "static" "inline" "virtual" "extern") (some (set " \t"))))
      (opt (* "const" (some (set " \t"))))
      (+ (* (+ "unsigned" "signed")
            (opt (* (some (set " \t")) ,width)))
         "void" "long long" "long" "int" "char" "bool" "boolean" "byte"
         "word" "float" "double" "short" "size_t" "uint8_t" "uint16_t"
         "uint32_t" "int8_t" "int16_t" "int32_t" "String")
      (any (set " \t*&"))))

# The functions every sketch has. They are called by the runtime rather than
# by another tab, so owning them would make every sketch's tabs depend on
# whichever one happened to define them.
(def- runtime-names '(+ "setup" "loop"))

(def spec
  {:name "arduino"
   # SKETCHES ONLY. `.pde` is the pre-1.0 sketch extension and still turns up
   # in older projects; `.ino` replaced it.
   #
   # `.h` AND `.cpp` ARE DELIBERATELY ABSENT, and they are the ones a reader
   # expects to find here, because a sketch's own library does live beside it
   # in exactly those. But those extensions are not Arduino's -- they are C
   # and C++'s, and every project in the world has them. Claiming them would
   # mean this repo's own external-src/janet/janet.c stopped being an external
   # and started being scanned as an Arduino sketch, and any C project opened
   # in this tool would be labelled a language it is not.
   #
   # The cost is that a sketch's headers show as externals rather than as
   # files. That is the honest reading until there is a C spec to own them:
   # the includes still resolve by name, so adding one later turns those
   # nodes into files without touching this line.
   :ext [".ino" ".pde"]

   # `build` and `.pio` are where the toolchains put their intermediates;
   # `libraries` is the IDE's own copy of everything installed, which is
   # somebody else's source rather than this project's.
   :skip-dirs ["build" ".pio" "libraries" ".vscode"]

   :noise ~(+ (* "R\"" (any (if-not "\"" 1)) (opt "\""))
              (* `"` (any (+ (* "\\" 1) (if-not (+ `"` "\n") 1))) `"`)
              (* "'" (any (+ (* "\\" 1) (if-not (+ "'" "\n") 1))) "'")
              (* "//" (any (if-not "\n" 1)))
              (* "/*" (any (if-not "*/" 1)) (opt "*/")))

   # Comments only. A quoted include path IS a string literal, so the :noise
   # pass above would blank `#include "pins.h"` before it could be read --
   # the same trap Go and JavaScript fall into. See src/visualize/parser.janet.
   :comments ~(+ (* "//" (any (if-not "\n" 1)))
                 (* "/*" (any (if-not "*/" 1)) (opt "*/")))

   # `#include <Servo.h>` or `#include "pins.h"`, with any spacing the
   # preprocessor allows -- `#  include` is legal and does turn up.
   #
   # Anchored to the line start so an include written inside a macro body or
   # a string cannot be read as one of its own.
   :imports ~(* ,line-start ,space "#" ,space "include" ,space
                (+ (* "<" (<- (some (if-not (+ ">" "\n") 1))) ">")
                   (* `"` (<- (some (if-not (+ `"` "\n") 1))) `"`)))

   # A type at the start of a line, or a free function's name.
   #
   # ANCHORED, and that matters more than it looks: without it the sweep can
   # start mid-line, and `typedef struct Foo` would be read from `struct`
   # onward -- handing this file a declaration of Foo that a typedef in
   # another file also claims.
   :declares ~(* ,line-start ,space
                 (+ (* (opt (* "typedef" (some (set " \t"))))
                       ,kinds ,word-end ,space (<- ,ident))
                    (* ,return-type (! ,runtime-names) (<- ,ident) ,space "(")))

   # Every identifier the file mentions. The declarations above are what these
   # are matched against, so an ordinary word like `digitalWrite` costs
   # nothing: it matches no declaration and draws no edge.
   :refs ~(<- ,ident)})
