(import ../src/visualize/scan)
(import ../src/visualize/config)
(import ../src/visualize/names)

(def args (dyn :args))
(def write? (truthy? (index-of "--write" args)))
(def root (or (find |(not (string/has-prefix? "--" $)) (slice args 1)) "."))

(def g (scan/scan root))
(def known @{})
(each n (get g :nodes) (put known (get n :name) true))

(defn matches-any? [prefix]
  (var hit false)
  (eachk k known
    (when (and (not hit) (string/has-prefix? prefix k)) (set hit true)))
  hit)

(defn configs [dir &opt acc]
  (default acc @[])
  (def path (string dir "/" config/config-name))
  (when (os/stat path :mode) (array/push acc path))
  (each entry (or (try (os/dir dir) ([_] nil)) [])
    (def full (string dir "/" entry))
    (when (and (= :directory (os/stat full :mode))
               (not (string/has-prefix? "." entry))
               (not= entry "node_modules"))
      (configs full acc)))
  acc)

(var total 0)
(each path (configs root)
  (def text (string (slurp path)))
  (def lines (string/split "\n" text))
  (def out @[])
  (var changed 0)
  (var n 0)
  (each line lines
    (++ n)
    (var result line)
    (def trimmed (string/trim line))
    (when (and (not (empty? trimmed)) (not (string/has-prefix? "#" trimmed)))
      (when-let [forms (peg/match config/grammar trimmed)]
        (var i 0)
        (while (< i (length forms))
          (def verb (get forms i))
          (++ i)
          (def slot @[])
          (while (and (< i (length forms)) (string? (get forms i)))
            (array/push slot (get forms i))
            (++ i))
          (def spec (find |(= ($ :name) (string verb)) config/verb-specs))
          (def kinds (if spec (spec :args) []))
          (each [at arg] (pairs slot)
            (when (and (= (get kinds at) :name)
                       (not (names/external? arg))
                       (not (empty? arg))
                       (not (matches-any? arg))
                       (matches-any? (names/external arg)))
              (printf "%s:%d  (%s %s) -> (%s %s)"
                      path n verb arg verb (names/external arg))
              (++ total)
              (++ changed)

              (set result
                   (string
                     (peg/replace-all
                       ~(* (<- (+ "(" (set " \t")))
                           ,arg
                           (> 0 (+ (set " \t)") -1)))
                       (fn [whole pre]
                         (string pre (names/external arg)))
                       result))))))))
    (array/push out result))
  (when (and write? (> changed 0))
    (spit path (string/join out "\n"))
    (printf "  wrote %s (%d)" path changed)))

(printf "\n%d name%s need the mark%s"
        total (if (= 1 total) "" "s")
        (if write? " -- written" " (re-run with --write to apply)"))
