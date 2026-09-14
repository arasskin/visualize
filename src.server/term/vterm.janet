(def- library-path (string (os/realpath (string (dyn :current-file) "/../../..")) "/src.vterm/libvisualize-vterm.so"))
(var- bindings nil)

(defn- load-bindings []
  (or bindings
    (let [lib (ffi/native library-path)
          api @{}]
      (each [name result args]
        [["new" :ptr [:int :int]]
         ["free" :void [:ptr]]
         ["write" :size [:ptr :ptr :size]]
         ["resize" :int [:ptr :int :int]]
         ["info" :int [:ptr :int]]
         ["line_revision" :int [:ptr :int :int]]
         ["line" :int [:ptr :int :int :ptr :int]]
         ["text" :size [:ptr :ptr :size]]
         ["replies" :size [:ptr :ptr :size]]
         ["title" :string [:ptr]]
         ["unsync" :void [:ptr]]
         ["color" :void [:ptr :int :int]]
         ["geometry" :void [:ptr :int :int]]]
        (put api name [(ffi/lookup lib (string "vz_" name)) (ffi/signature :default result ;args)]))
      (set bindings api))))

(defn create [rows cols]
  (def api (load-bindings))
  (defn invoke [name & args]
    (def [pointer signature] (api name))
    (ffi/call pointer signature ;args))
  (var terminal (invoke "new" rows cols))
  (unless terminal (error "libvterm allocation failed or invalid dimensions"))
  (def scratch (buffer/new-filled 65536 0))
  (var holding false)
  (def pending-replies @"")
  (var sync-deadline 0)
  (defn info [key] (invoke "info" terminal key))
  (defn synchronized? []
    (def active (= 1 (info 11)))
    (when (and active (not holding))
      (set sync-deadline (+ (os/clock :monotonic) 1)))
    (set holding active)
    (when (and active (>= (os/clock :monotonic) sync-deadline))
      (invoke "unsync" terminal)
      (set holding false))
    holding)
  (defn lines [history at]
    (def out @[])
    (for row 0 (info (if history 6 0))
      (when (or (zero? at) (> (invoke "line_revision" terminal (if history 1 0) row) at))
        (def size (invoke "line" terminal (if history 1 0) row scratch (length scratch)))
        (when (neg? size) (error "libvterm row serialization failed"))
        (array/push out [(if history (+ (info 13) row) row)
                         (string/slice scratch 0 size)])))
    out)
  {:write (fn [_ bytes]
            (var offset 0)
            (while (< offset (length bytes))
              (def part (string/slice bytes offset (min (length bytes) (+ offset 2048))))
              (unless (= (length part) (int/to-number (invoke "write" terminal part (length part))))
                (error "libvterm did not consume terminal output"))
              (def reply-size (int/to-number (invoke "replies" terminal scratch (length scratch))))
              (when (> (+ (length pending-replies) reply-size) 1048576)
                (error "libvterm response buffer full"))
              (buffer/push-string pending-replies (string/slice scratch 0 reply-size))
              (when (pos? (info 9)) (error "libvterm allocation or response failure"))
              (+= offset (length part)))
            (synchronized?)
            nil)
   :theme (fn [_ colors]
            (each [key index] [["foreground" -1] ["background" -2]]
              (when-let [rgb (get colors key)] (invoke "color" terminal index rgb)))
            (eachp [index rgb] (get colors "palette" [])
              (when (< index 16) (invoke "color" terminal index rgb))))
   :geometry (fn [_ width height] (invoke "geometry" terminal width height))
   :replies (fn [_]
              (def bytes (string pending-replies))
              (buffer/clear pending-replies)
              bytes)
   :resize (fn [_ rows cols]
             (unless (= 1 (invoke "resize" terminal rows cols)) (error "libvterm resize failed")))
   :bracketed-paste? (fn [_] (= 1 (info 15)))
   :revision (fn [_] (info 10))
   :synchronized? (fn [_] (synchronized?))
   :release-output (fn [_] (invoke "unsync" terminal))
   :snapshot (fn [_ at]
               {"revision" (info 10)
                "rows" (info 0) "cols" (info 1)
                "cursor" {"row" (info 2) "col" (info 3) "visible" (= 1 (info 4))}
                "alternate" (= 1 (info 5)) "title" (invoke "title" terminal)
                "modes" [(info 14) (info 15) (info 16) (info 17) (info 18)]
                "lines" (lines false at)
                "history" {"start" (info 13) "count" (info 6) "lines" (lines true at)}})
   :capture (fn [_]
              (def buffer (buffer/new-filled (* (info 0) (info 1) 24) 0))
              (def size (int/to-number (invoke "text" terminal buffer (length buffer))))
              (string/slice buffer 0 size))
   :close (fn [_]
            (when terminal (invoke "free" terminal) (set terminal nil)))})
