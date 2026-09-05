(def- space '(some (set " \t")))
(import ../names)

(def- line-start '(+ (> -1 "\n") (! (> -1 1))))

(def- path-char '(if-not (+ (set " \t\n\"'();|&<>`") -1) 1))
(def- path ~(some ,path-char))

(def- quoted-path ~(+ (* `"` (<- ,path) `"`) (* "'" (<- ,path) "'") (<- ,path)))

(def- no-slash '(if-not (+ (set " \t\n\"'();|&<>`") "/" -1) 1))
(def- slashed-path
  ~(* (? `"`) (> 0 (* (any ,no-slash) "/")) (<- ,path) (? `"`)))

(def- slashed-bare
  ~(* (? `"`) (> 0 (* (any ,no-slash) "/")) ,path (? `"`)))

(defn- split-var [text]
  (peg/match ~(* (+ (* "${" (<- (some (if-not "}" 1))) "}")
                    (* "$" (<- (some (+ (range "AZ") (range "az")
                                        (range "09") "_")))))
                 "/" (<- (any 1)) -1)
             (string/trim text `"'`)))

(defn- assignments [text]
  (def known @{})

  (def hits (peg/match
              ~(any (+ (* ,line-start (any (set " \t"))
                          (<- (some (+ (range "AZ") (range "az")
                                       (range "09") "_")))
                          "=" (? `"`) "$"
                          (<- (some (+ (range "AZ") (range "az")
                                       (range "09") "_")))
                          "/"
                          (<- (some (if-not (+ (set " \t\n\"'();|&`$") -1) 1)))
                          (? `"`))
                       (* ,line-start (any (set " \t"))
                          (<- (some (+ (range "AZ") (range "az")
                                       (range "09") "_")))
                          "=" (? `"`)
                          (<- (some (if-not (+ (set " \t\n\"'();|&`$") -1) 1)))
                          (? `"`))
                       1))
              text))

  (var i 0)
  (def all (or hits []))
  (while (< i (length all))
    (def name (all i))

    (def two (get all (+ i 1)))
    (def three (get all (+ i 2)))
    (cond
      (and three (known two))
      (do (put known name (string (known two) "/" three)) (+= i 3))
      (and three (= two "here"))
      (do (put known name three) (+= i 3))
      (do (put known name two) (+= i 2))))
  known)

(defn- strip-var [text &opt known]
  (def peeled (string/trim text `"'`))
  (def parts (split-var peeled))
  (def rest
    (if parts
      (let [name (first parts)
            tail (get parts 1)
            base (get (or known {}) name)]

        (if base (string base "/" tail) tail))
      peeled))

  (if (string/find "$" rest) nil rest))

(def- script-exts [".sh" ".bash" ".janet"])

(defn- drop-ext [text]
  (var out text)
  (each ext script-exts
    (when (string/has-suffix? ext out)
      (set out (string/slice out 0 (- (length out) (length ext))))))
  out)

(defn- as-relative [text &opt known]
  (def trimmed (string/trim text `"'`))
  (def rooted (not= trimmed (string/trim (or (strip-var text known) "") `"'`)))
  (when-let [bare (strip-var text known)]
    (def path (string/trim bare `"'`))
    (cond
      (empty? path) nil

      (string/has-prefix? "/" path) nil
      rooted (drop-ext path)
      (string/has-prefix? "." path) path
      (string "./" path))))

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

(defn- parse [raw path]
  (def text (decommented raw))
  (def known (assignments text))

  (def found @[])

  (defn collect [rule]
    (each hit (or (peg/match ~(any (+ ,rule 1)) text) [])
      (when-let [rel (as-relative hit known)]
        (array/push found rel))))

  (collect ~(* (+ ,line-start (set ";&|"))
               (any (set " \t"))
               (+ (* "source" ,space) (* "." ,space))
               ,quoted-path))

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

  (collect ~(* (+ ,line-start (set ";&|("))
               (any (set " \t"))
               (? (* "exec" ,space))

               (! (* (some (+ (range "AZ") (range "az") (range "09") "_")) "="))
               ,slashed-path))

  {:imports (map |(names/from-path path $) (distinct found))})

(def spec
  {:name "bash"
   :ext [".sh" ".bash"]

   :shebang ["sh" "bash" "zsh" "dash" "ksh"]

   :comments ~(+ (* "#" (any (if-not "\n" 1)))
                 (* "<<" (? "-") (? (set `"'`)) (some (+ (range "AZ") (range "az")
                                                         (range "09") "_"))
                    (any (if-not "\n" 1))
                    (any (if-not "\n" 1))))

   :noise ~(+ (* "#" (any (if-not "\n" 1)))
              (* `"` (any (+ (* "\\" 1) (if-not (+ `"` "\n") 1))) `"`)
              (* "'" (any (if-not (+ "'" "\n") 1)) "'"))

   :parse parse})
