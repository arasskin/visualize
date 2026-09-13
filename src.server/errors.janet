(import ./json)

(defn logger [dir]
  (unless (os/stat dir) (os/mkdir dir))
  (def path (string dir "/terminal-errors.jsonl"))
  (unless (os/stat path) (spit path ""))
  {:path path
   :write (fn [_ sent]
     (def entry @{"recorded" (os/time)})
     (each [key limit] [["time" 64] ["pane" 64] ["label" 200] ["phase" 80]
                       ["message" 2048] ["stack" 8192] ["rows" 16] ["cols" 16]]
       (when-let [value (get sent key)]
         (def text (string value))
         (put entry key (string/slice text 0 (min limit (length text))))))
     (when (> (or (os/stat path :size) 0) 1048576)
       (def backup (string path ".1"))
       (when (os/stat backup) (os/rm backup))
       (os/rename path backup))
     (with [out (file/open path :a)]
       (file/write out (json/encode entry) "\n"))
     true)})
