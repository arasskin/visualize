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

(defn- strip-var [text &opt known]
  (def peeled (string/trim text `"'`))
  (def parts (split-var peeled))
  (def rest
    (if parts
      (when-let [base (get (or known {}) (first parts))]
        (string base "/" (get parts 1)))
      peeled))
  (when (and rest (not (string/find "$" rest))
             (peg/match ~(* ,path -1) rest))
    rest))

(def- script-directory
  ~(* "$(" (? (* "CDPATH=" ,space)) "cd" ,space (? (* "--" ,space))
      `"$(dirname` ,space (? (* "--" ,space)) `"$0")"`
      ,space "&&" ,space "pwd)" -1))

(defn- assignments [text]
  (def known @{})
  (each line (string/split "\n" text)
    (when-let [parts (peg/match
                      ~(* (any (set " \t"))
                          (<- (some (+ (range "AZ") (range "az")
                                       (range "09") "_")))
                          "=" (<- (any 1)) -1)
                      line)]
      (def value (string/trim (get parts 1)))
      (put known (first parts)
        (if (peg/match script-directory value)
          "."
          (strip-var value known)))))
  known)

(defn- as-relative [text &opt known]
  (when-let [path (strip-var text known)]
    (cond
      (empty? path) nil
      (string/has-prefix? "/" path) nil
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
  (def text (string/replace-all "\\\n" "" (decommented raw)))
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
