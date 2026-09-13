(defn argv [shell command path]
  (unless (and (string? command) (<= (length command) 4096)
               (not (empty? (string/trim command))))
    (error "enter a terminal command (up to 4096 characters)"))
  (unless (and (string? path) (not (string/find "\0" path)))
    (error "invalid file path"))
  [shell "-l" "-i" "-c"
   (string (string/trim command) " '" (string/replace-all "'" "'\\''" path) "'")])
