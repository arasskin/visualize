(import ../names)

(def- inner '(some (if-not (+ (set "()\"'") -1) 1)))

(def- url-ref ~(* "url(" (any (set " \t\n"))
                  (+ (* `"` (<- (any (if-not `"` 1))) `"`)
                     (* "'" (<- (any (if-not "'" 1))) "'")
                     (<- ,inner))
                  (any (set " \t\n")) ")"))

(def- import-ref ~(* "@import" (some (set " \t\n"))
                     (+ (* `"` (<- (any (if-not `"` 1))) `"`)
                        (* "'" (<- (any (if-not "'" 1))) "'"))))

(defn- parse [text path]

  (def code (peg/replace-all ~(* "/*" (any (if-not "*/" 1)) "*/") " " text))

  (def found @[])
  (each hit (or (peg/match ~(any (+ ,import-ref ,url-ref 1)) (string code)) [])
    (array/push found hit))

  (def keep
    (filter (fn [ref]
              (and (not (empty? ref))
                   (not (string/find "://" ref))
                   (not (string/has-prefix? "#" ref))
                   (not (string/has-prefix? "//" ref))
                   (not (string/has-prefix? "data:" ref))))
            found))

  {:imports (map |(names/from-path path $)
                 (distinct
              (map (fn [ref]

                     (def bare (string/trim ref))
                     (def clean (first (string/split "?" (first (string/split "#" bare)))))
                     (cond
                       (empty? clean) clean

                       (string/has-prefix? "/" clean) (string "./" (string/slice clean 1))
                       (string/has-prefix? "." clean) clean
                       (string "./" clean)))
                   keep)))})

(def spec
  {:name "css"
   :ext [".css"]
   :skip-dirs ["node_modules" "dist" "build" "coverage" "_site"]
   :parse parse})
