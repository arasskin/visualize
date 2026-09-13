(def default-library (string (os/realpath (string (dyn :current-file) "/../..")) "/src.vterm/libvisualize-vterm.so"))
(def library (or (get (dyn :args) 1) default-library))
(def- native (ffi/native library))
(defn- bind [name result & args]
  (def pointer (ffi/lookup native (string "vz_" name)))
  (assert pointer (string "missing libvterm function: " name))
  (def signature (ffi/signature :default result ;args))
  (fn [& values] (ffi/call pointer signature ;values)))
(def create (bind "new" :ptr :int :int))
(def release (bind "free" :void :ptr))
(def- write (bind "write" :size :ptr :ptr :size))
(def resize (bind "resize" :int :ptr :int :int))
(def- text (bind "text" :size :ptr :ptr :size))
(def replies (bind "replies" :size :ptr :ptr :size))
(def info (bind "info" :int :ptr :int))
(def cell (bind "cell" :int :ptr :int :int :int :ptr))
(def dirty (bind "dirty" :int :ptr :int))
(def clean (bind "clean" :void :ptr))

(defn feed [terminal bytes]
  (assert (= (length bytes) (int/to-number (write terminal bytes (length bytes))))))

(def- utf8
  ~(* (any (+ (range "\x00\x7f")
              (* (range "\xc2\xdf") (range "\x80\xbf"))
              (* "\xe0" (range "\xa0\xbf") (range "\x80\xbf"))
              (* (+ (range "\xe1\xec") (range "\xee\xef")) (repeat 2 (range "\x80\xbf")))
              (* "\xed" (range "\x80\x9f") (range "\x80\xbf"))
              (* "\xf0" (range "\x90\xbf") (repeat 2 (range "\x80\xbf")))
              (* (range "\xf1\xf3") (repeat 3 (range "\x80\xbf")))
              (* "\xf4" (range "\x80\x8f") (repeat 2 (range "\x80\xbf"))))) -1))

(defn capture [terminal &opt read]
  (default read text)
  (def buffer (buffer/new-filled 1048576 0))
  (def size (int/to-number (read terminal buffer (length buffer))))
  (def result (string/slice buffer 0 size))
  (assert (peg/match utf8 result) "invalid UTF-8 in native capture")
  result)

(defn at [terminal row col &opt history]
  (def buffer (buffer/new-filled 44 0))
  (assert (= 1 (cell terminal (or history 0) row col buffer)))
  (seq [i :range [0 11]] (ffi/read :uint32 buffer (* i 4))))

(defn position [terminal] [(info terminal 2) (info terminal 3)])

(defn resized [terminal rows cols]
  (assert (= 1 (resize terminal rows cols)))
  (assert (and (<= 0 (info terminal 2)) (< (info terminal 2) rows)
               (<= 0 (info terminal 3)) (< (info terminal 3) cols))))

(defn decode-base64 [encoded]
  (assert (zero? (% (length encoded) 4)) "invalid base64 length")
  (def alphabet "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
  (def out @"")
  (var offset 0)
  (while (< offset (length encoded))
    (def group (string/slice encoded offset (+ offset 4)))
    (def padding (cond (string/has-suffix? "==" group) 2 (string/has-suffix? "=" group) 1 0))
    (assert (or (zero? padding) (= (+ offset 4) (length encoded))) "invalid base64 padding")
    (var bits 0)
    (for i 0 4
      (def value (if (>= i (- 4 padding)) 0
                   (string/find (string/slice group i (inc i)) alphabet)))
      (assert value "invalid base64 character")
      (set bits (+ (blshift bits 6) value)))
    (buffer/push-byte out (band 255 (brushift bits 16)))
    (when (< padding 2) (buffer/push-byte out (band 255 (brushift bits 8))))
    (when (zero? padding) (buffer/push-byte out (band 255 bits)))
    (+= offset 4))
  (string out))
