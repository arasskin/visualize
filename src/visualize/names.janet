(defn stem

  [rel]
  (if-let [dot (last (string/find-all "." rel))]
    (if (> dot (or (last (string/find-all "/" rel)) -1))
      (string/slice rel 0 dot)
      rel)
    rel))

(defn resolve-relative

  [from-rel module]
  (def parts (string/split "/" from-rel))

  (def stack (array ;(slice parts 0 (max 0 (- (length parts) 1)))))
  (each piece (string/split "/" module)
    (cond
      (or (= piece ".") (= piece "")) nil
      (= piece "..") (when (> (length stack) 0) (array/pop stack))
      (array/push stack piece)))
  (stem (string/join stack "/")))

(defn safe-name

  [text]
  (def dotted
    (string
      (peg/replace-all ~(if-not (+ (range "AZ") (range "az") (range "09") "_" "-" ".") 1)
                       "." text)))

  (var out dotted)
  (while (string/find ".." out)
    (set out (string/replace-all ".." "." out)))
  (string/trim out "."))

(defn extension

  [rel]
  (def cut (stem rel))
  (when (not= cut rel) (string/slice rel (+ 1 (length cut)))))

(defn node-name

  [rel]
  (safe-name rel))

(defn from-path

  [from path]

  (safe-name (if (string/has-prefix? "." path)
               (resolve-relative from path)
               (stem path))))

(defn from-module

  [module]
  (safe-name (string/replace-all "." "/" module)))

(def external-mark "?.")

(defn external

  [name]
  (string external-mark name))

(defn external?

  [name]
  (string/has-prefix? external-mark name))
