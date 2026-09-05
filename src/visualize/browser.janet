(defn command [url &opt applications]
  (default applications
    ["/Applications/Google Chrome.app"
     (string (os/getenv "HOME") "/Applications/Google Chrome.app")])
  (def chrome
    (find (fn [path]
            (= :file (try (os/stat (string path "/Contents/MacOS/Google Chrome") :mode)
                          ([_] nil))))
          applications))
  (if chrome
    ["open" "-na" chrome "--args" (string "--app=" url)]
    ["open" url]))
