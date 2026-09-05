(import ../names)

(def- label-char '(+ (range "AZ") (range "az") (range "09") "_" "-" "."))

(def- heading
  ~(* (! (set " \t"))
      (<- (some ,label-char))
      (any (set " \t"))
      (<- (any (if-not "\n" 1)))))

(def- dependency
  ~(* (some (set " \t"))
      (<- (some ,label-char))
      (any (if-not "\n" 1))))

(defn- parse [text path]
  (def nodes @[])
  (def seen @{})
  (def edges @[])
  (var current nil)

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

      (empty? (string/trim line)) nil

      (string/has-prefix? "#" (string/trim line)) nil

      (peg/match ~(* (set " \t")) line)
      (when-let [hit (peg/match dependency line)
                 label (first hit)]
        (when current
          (def to (note label))
          (unless (= to current) (array/push edges [current to]))))

      (when-let [hit (peg/match heading line)
                 label (first hit)]
        (set current (note label)))))

  {:nodes nodes :edges edges :extension (names/extension (or path ""))})

(def spec
  {:name "visualize"
   :ext [".visualize"]
   :parse parse})
