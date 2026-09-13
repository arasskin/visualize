(def- library-path
  (string (os/realpath (string (dyn :current-file) "/../.."))
          "/src.graphviz/libvisualize-graphviz.so"))
(var- bindings nil)

(defn- load-bindings []
  (or bindings
    (let [library (ffi/native library-path)
          api @{}]
      (each [name result args]
        [["render" :ptr [:string]]
         ["svg" :string [:ptr]]
         ["error" :string [:ptr]]
         ["free" :void [:ptr]]]
        (put api name [(ffi/lookup library (string "vz_graphviz_" name))
                       result args]))
      (set bindings api))))

(defn render [dot]
  (when (string/find "\0" dot) (error "DOT input contains a NUL byte"))
  (def api (load-bindings))
  (defn call [name & args]
    (def [pointer result parameters] (api name))
    (ffi/call pointer (ffi/signature :default result ;parameters) ;args))
  (def result (call "render" dot))
  (unless result (error "Graphviz allocation failed"))
  (def output (try
    (let [svg (call "svg" result)]
      (if (empty? svg) [false (call "error" result)] [true svg]))
    ([err] [false (string err)])))
  (call "free" result)
  (if (output 0) (output 1) (error (output 1))))
