(import ../../src.server/term/pty)
(import ../../src.server/term/host)
(import ./harness :as t)

(defn- capture

  [script &opt rows cols]
  (default rows 24)
  (default cols 80)
  (def out-chan (ev/thread-chan 512))
  (ev/thread
    (fn [[chan lines columns text]]
      (def session (pty/open ["/bin/sh" "-c" text] lines columns))
      (pty/pump session (fn [chunk] (ev/give chan chunk)))
      (ev/give chan :eof)
      :done)
    [out-chan rows cols script] :nt (ev/thread-chan 4))
  (def seen @"")
  (var running true)
  (while running
    (def chunk (ev/take out-chan))
    (if (string? chunk)
      (buffer/push-string seen chunk)
      (set running false)))
  (string seen))

(t/test "the child gets a REAL terminal, not a pipe"

  (def out (capture "test -t 0 && echo IS_TTY; tty"))
  (t/ok (string/find "IS_TTY" out) "isatty() must be true inside the child")
  (t/ok (string/find "/dev/tty" out) "the child is attached to a tty device"))

(t/test "a terminal ends lines with CRLF"

  (t/ok (string/find "\r\n" (capture "echo hello"))))

(t/test "the window size reaches the child"
  (def out (capture "stty size" 40 120))
  (t/ok (string/find "40 120" out)
        "forkpty's winsize argument is what the child sees"))

(t/test "typing reaches the program and its output comes back"
  (def out-chan (ev/thread-chan 512))
  (def ready (ev/thread-chan 4))
  (ev/thread
    (fn [[rc oc]]
      (def session (pty/open ["/bin/sh" "-i"] 24 80))
      (ev/give rc session)
      (pty/pump session (fn [chunk] (ev/give oc chunk)))
      (ev/give oc :eof)
      :done)
    [ready out-chan] :nt (ev/thread-chan 4))
  (def session (ev/take ready))
  (def seen @"")
  (ev/sleep 0.4)
  (pty/write-input session "echo TYPED-OK\n")

  (var found false)
  (var reads 0)
  (while (and (not found) (< reads 40))
    (++ reads)
    (def chunk (ev/take out-chan))
    (if (string? chunk)
      (do (buffer/push-string seen chunk)

          (when (string/find "\nTYPED-OK" (string seen)) (set found true)))
      (break)))
  (pty/write-input session "exit\n")
  (t/ok found "what was written to the pty was executed by the shell")
  (pty/close session))

(t/test "resize reaches the kernel and notifies the foreground process"

  (def ready (ev/thread-chan 4))
  (def out-chan (ev/thread-chan 512))
  (ev/thread
    (fn [[rc oc]]
      (def session (pty/open ["/bin/sh" "-c"
        "trap 'printf WINCH:; stty size' WINCH\nprintf 'READY\\n'\nwhile :; do read -r line || :; done"] 24 80))
      (ev/give rc session)
      (pty/pump session (fn [chunk] (ev/give oc chunk)))
      (ev/give oc :eof)
      :done)
    [ready out-chan] :nt (ev/thread-chan 4))
  (def session (ev/take ready))
  (defer (pty/close session)
    (defn heard? [wanted]
      (def seen @"")
      (var tries 0)
      (var found false)
      (while (< tries 100)
        (while (pos? (ev/count out-chan))
          (def chunk (ev/take out-chan))
          (when (string? chunk) (buffer/push-string seen chunk)))
        (when (string/find wanted seen) (set found true) (break))
        (++ tries)
        (ev/sleep 0.02))
      found)
    (t/ok (heard? "READY") "the foreground process has installed its signal handler")
    (each [rows cols] [[40 120] [12 51] [24 80]]
      (t/ok (pty/resize session rows cols) "ioctl reported success")
      (t/ok (heard? (string "WINCH:" rows " " cols)) "SIGWINCH reports the new kernel dimensions"))
    (def env (require "../../src.server/term/host"))
    (def saved @{})
    (each key ['session 'emulator 'pty-rows 'pty-cols]
      (put saved key (get-in env [key :ref 0])))
    (defer (eachp [key value] saved (put (get-in env [key :ref]) 0 value))
      (defn set-state [key value] (put (get-in env [key :ref]) 0 value))
      (set-state 'pty-rows 24)
      (set-state 'pty-cols 80)
      (var attempts 0)
      (set-state 'emulator {:geometry (fn [& _] nil)
                           :resize (fn [& _] (++ attempts) (error "emulator allocation failed"))})
      (set-state 'session {:fd -1})
      (def failure (try (host/handle {"op" "resize" "rows" 40 "cols" 120}) ([e] (string e))))
      (t/ok (string/find "Bad file descriptor" failure) "kernel failure reaches the caller")
      (t/is= 0 attempts "a failed ioctl leaves the emulator untouched")
      (set-state 'session session)
      (def failure (try (host/handle {"op" "resize" "rows" 40 "cols" 120}) ([e] (string e))))
      (t/is= "emulator allocation failed" failure)
      (t/is= 1 attempts)
      (def asked (os/spawn ["stty" "-f" (session :device) "size"] :px {:out :pipe}))
      (def answer (string/trim (or (:read (asked :out) :all) "")))
      (os/proc-wait asked)
      (t/is= "24 80" answer "emulator failure restores the previous kernel dimensions")
      (t/is= 24 (get-in env ['pty-rows :ref 0]))
      (t/is= 80 (get-in env ['pty-cols :ref 0])))))

(t/test "a session reports the device it is attached to"

  (def ready (ev/thread-chan 4))
  (ev/thread
    (fn [rc]
      (def session (pty/open ["/bin/sh" "-c" "sleep 5"] 24 80))
      (ev/give rc session)
      :done)
    ready :nt (ev/thread-chan 4))
  (def session (ev/take ready))
  (t/ok (string/has-prefix? "/dev/" (session :device)))
  (t/ok (> (session :pid) 0))
  (pty/close session))

(t/test "closing a session stops the program"
  (def ready (ev/thread-chan 4))
  (ev/thread
    (fn [rc]
      (ev/give rc (pty/open ["/bin/sh" "-c" "sleep 30"] 24 80))
      :done)
    ready :nt (ev/thread-chan 4))
  (def session (ev/take ready))
  (t/ok (pty/alive? session) "it is running before being closed")
  (pty/close session)
  (ev/sleep 0.4)

  (t/ok (not (pty/alive? session)) "and gone afterwards"))

(t/test "the harness is argv, not a code path"

  (t/ok (string/find "from-any-program" (capture "echo from-any-program"))))
