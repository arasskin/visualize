(defn- bound [name return & args]
  (def found (ffi/lookup (ffi/native) name))
  (unless found (errorf "libc is missing %s -- cannot open a terminal" name))
  [found (ffi/signature :default return ;args)])

(defn- forkpty* [] (bound "forkpty" :int :ptr :ptr :ptr :ptr))
(defn- read* [] (bound "read" :long :int :ptr :size))
(defn- write* [] (bound "write" :long :int :ptr :size))

(defn- poll* [] (bound "poll" :int :ptr :uint :int))
(defn- close* [] (bound "close" :int :int))
(defn- kill* [] (bound "kill" :int :int :int))
(defn- waitpid* [] (bound "waitpid" :int :int :ptr :int))

(defn- call [[pointer signature] & args]
  (def out (ffi/call pointer signature ;args))

  (if (number? out) out (int/to-number out)))

(defn- winsize [rows cols]
  (def out (buffer/new-filled 8 0))
  (ffi/write :uint16 rows out 0)
  (ffi/write :uint16 cols out 2)
  out)

(defn open

  [argv &opt rows cols env directory]
  (default rows 30)
  (default cols 100)
  (def environment (or env (os/environ)))

  (put environment "TERM" (or (environment "TERM") "xterm-256color"))
  (put environment "COLUMNS" (string cols))
  (put environment "LINES" (string rows))

  (def master (buffer/new-filled 4 0))

  (def name (buffer/new-filled 128 0))
  (def pid (call (forkpty*) master name nil (winsize rows cols)))
  (when (neg? pid) (error "forkpty failed -- no terminal available"))

  (when (zero? pid)

    (when directory (try (os/cd directory) ([_] nil)))
    (try (os/posix-exec argv :pe environment) ([_] nil))
    (os/exit 127))

  {:pid pid
   :fd (ffi/read :int master 0)
   :device (let [text (string name)]
             (string/slice text 0 (or (string/find "\0" text) (length text))))
   :argv argv})

(defn writable?

  [session]

  (def fds (buffer/new-filled 8 0))
  (ffi/write :int (session :fd) fds 0)
  (ffi/write :int16 4 fds 4)
  (pos? (call (poll*) fds 1 0)))

(defn write-input

  [session text]
  (def payload (buffer text))
  (cond
    (empty? payload) 0
    (not (writable? session)) 0
    (max 0 (call (write*) (session :fd) payload (length payload)))))

(defn resize

  [session rows cols]
  (if (empty? (or (session :device) ""))
    false
    (zero? (try
             (os/execute ["stty" "-f" (session :device)
                          "rows" (string rows) "columns" (string cols)]
                         :p)
             ([_] 1)))))

(defn alive?

  [session]
  (def status (buffer/new-filled 4 0))
  (def out (call (waitpid*) (session :pid) status 1))

  (zero? out))

(defn close

  [session]
  (call (kill*) (session :pid) 1)
  (call (kill*) (session :pid) 9)
  (call (close*) (session :fd))
  nil)

(defn pump

  [session on-output]
  (def buf (buffer/new-filled 65536 0))

  (def reader (read*))
  (var running true)
  (while running
    (def got (call reader (session :fd) buf 65536))
    (cond
      (> got 0) (on-output (string (buffer/slice buf 0 got)))

      (set running false)))
  nil)
