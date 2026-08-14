# A pseudo-terminal, from Janet, with no C extension.
#
# WHY A PTY AND NOT A PIPE. An agent harness is a full-screen terminal
# program: it checks `isatty()` and behaves completely differently when the
# answer is no. Claude Code piped answers once and exits; under a PTY it draws
# a TUI, asks whether the directory is trusted, and redraws in place as tokens
# stream. `os/spawn` with `:pipe` cannot run one, so this asks the kernel for a
# real terminal instead -- the same thing tmux, ssh and every editor terminal
# do. Nothing here defeats the tty check; it satisfies it.
#
# HOW, WITHOUT LEAVING JANET. Janet has no forkpty, but it does have an FFI,
# and forkpty/read/write/kill are all in libc. So this is ~30 lines of binding
# rather than a C extension -- which keeps the "all source in the repository"
# property, since the vendored runtime already compiles FFI in. The one
# exception is `ioctl`, which the FFI cannot call at all; see `resize`.
#
# THE ONE HARD PART IS THE EVENT LOOP. A blocking read() in a tight loop
# starves Janet's scheduler, and the server would stop answering HTTP while
# the terminal was busy -- measured, not guessed. So the pump runs on
# `ev/thread`, a real OS thread, where blocking is allowed and harmless. That
# is the same threading `visualize/scan.janet` uses for the parallel file scan.
#
# NOTHING HERE KNOWS WHAT IT IS RUNNING. The command is argv. Claude Code and
# pi were both driven through this unchanged, which is the point: the harness
# is a config value, not a code path.

# THE BINDINGS ARE BUILT ON EVERY CALL, NOT CACHED, and that is a requirement
# rather than waste.
#
# An ffi-signature CANNOT BE MARSHALLED. `ev/thread` copies the function and
# everything it closes over into the new thread, so a signature reachable from
# module scope -- or from a cache a previous call populated -- makes this whole
# module unusable from a thread. The failure is not local either: calling
# `resize` on the main thread would poison a cache that a LATER `pty/open` on a
# worker thread then tried to copy, and the error arrives far from the cause.
#
# The pump has to run on a thread (see the note above), so the safe rule is
# that no signature ever outlives the call that made it. Each one is a few
# dlsym lookups against an already-loaded libc; the pump makes one per session,
# not per read.
(defn- bound [name return & args]
  (def found (ffi/lookup (ffi/native) name))
  (unless found (errorf "libc is missing %s -- cannot open a terminal" name))
  [found (ffi/signature :default return ;args)])

# int forkpty(int *amaster, char *name, termios *tp, winsize *ws)
#
# `name` is asked for even though forkpty's own docs discourage it: it returns
# the SLAVE DEVICE PATH (/dev/ttysNNN), and that path is how `resize` below
# works at all. See the note there.
(defn- forkpty* [] (bound "forkpty" :int :ptr :ptr :ptr :ptr))
(defn- read* [] (bound "read" :long :int :ptr :size))
(defn- write* [] (bound "write" :long :int :ptr :size))
(defn- close* [] (bound "close" :int :int))
(defn- kill* [] (bound "kill" :int :int :int))
(defn- waitpid* [] (bound "waitpid" :int :int :ptr :int))

# NO ioctl BINDING, AND THAT IS DELIBERATE. `ioctl` is variadic --
# `int ioctl(int, unsigned long, ...)` -- and on arm64 (:aapcs64, which is
# what this machine reports) variadic arguments are passed on the stack rather
# than in registers. libffi cannot express that through a fixed signature, so
# every attempt returned -1 or silently did nothing: the struct never reached
# the kernel. Measured, not assumed.
#
# `resize` therefore shells out to `stty`, which is a real program that does
# the ioctl properly. Slower than a syscall and worth it: a resize happens
# when a human drags a window edge, not in a loop.

(defn- call [[pointer signature] & args]
  (def out (ffi/call pointer signature ;args))
  # `read`/`write` return `long`, which arrives as an s64 box on some
  # platforms and a plain number on others. Normalise once here so no caller
  # has to care.
  (if (number? out) out (int/to-number out)))

# struct winsize { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; }
(defn- winsize [rows cols]
  (def out (buffer/new-filled 8 0))
  (ffi/write :uint16 rows out 0)
  (ffi/write :uint16 cols out 2)
  out)

(defn open
  ``Start `argv` on a new pseudo-terminal.

  Returns {:pid :fd :argv}. The fd is the MASTER side: read it to see what the
  program drew, write to it to type at the program.

  `env` is passed through explicitly because a forked child inherits nothing
  useful otherwise -- the first version of this died with
  `env: node: No such file or directory`, since the agent harnesses are node
  scripts and could not find node without a PATH.``
  [argv &opt rows cols env]
  (default rows 30)
  (default cols 100)
  (def environment (or env (os/environ)))
  # A terminal program asks $TERM what it may draw with. Without one it either
  # refuses colour entirely or guesses badly.
  (put environment "TERM" (or (environment "TERM") "xterm-256color"))
  (put environment "COLUMNS" (string cols))
  (put environment "LINES" (string rows))

  (def master (buffer/new-filled 4 0))
  # 128 bytes for the slave device name. forkpty writes a NUL-terminated path
  # here, and `resize` needs it -- see the note above the bindings.
  (def name (buffer/new-filled 128 0))
  (def pid (call (forkpty*) master name nil (winsize rows cols)))
  (when (neg? pid) (error "forkpty failed -- no terminal available"))

  (when (zero? pid)
    # THE CHILD. `os/posix-exec` replaces this process, so nothing below runs
    # unless it fails -- and if it does, exiting immediately is the only safe
    # move: a forked copy of the server that kept running would answer HTTP
    # requests from a half-initialised process.
    (try (os/posix-exec argv :pe environment) ([_] nil))
    (os/exit 127))

  {:pid pid
   :fd (ffi/read :int master 0)
   :device (let [text (string name)]
             (string/slice text 0 (or (string/find "\0" text) (length text))))
   :argv argv})

(defn write-input
  "Send keystrokes to the program. Returns how many bytes went."
  [session text]
  (def payload (buffer text))
  (if (empty? payload)
    0
    (call (write*) (session :fd) payload (length payload))))

(defn resize
  ``Tell the program its window changed size.

  Without this the TUI keeps drawing to the width it started with, so a
  resized pane wraps in the wrong places. Setting the size also raises
  SIGWINCH in the program, which is how a full-screen one knows to redraw.

  VIA `stty`, NOT ioctl. The syscall is variadic and libffi cannot call it
  correctly on arm64 -- see the note above the bindings. `stty -f <device>`
  does exactly the same thing from a process that can, and a resize is a
  human-speed event, so the cost of a fork is irrelevant.

  Returns true when the size was applied.``
  [session rows cols]
  (if (empty? (or (session :device) ""))
    false
    (zero? (try
             (os/execute ["stty" "-f" (session :device)
                          "rows" (string rows) "columns" (string cols)]
                         :p)
             ([_] 1)))))

(defn alive?
  ``Is the program still running?

  WNOHANG (1) so this never blocks. waitpid also REAPS the child, which is why
  it is called rather than merely signalling: without it an exited harness
  stays a zombie for as long as the server runs.``
  [session]
  (def status (buffer/new-filled 4 0))
  (def out (call (waitpid*) (session :pid) status 1))
  # 0 means "still running"; the pid means it exited and has now been reaped.
  (zero? out))

(defn close
  ``Stop the program and release the terminal.

  SIGHUP first, which is what a terminal program expects when its window goes
  away and gives it a chance to save. SIGKILL after, because a harness that
  ignores the hangup would otherwise outlive the server that started it.``
  [session]
  (call (kill*) (session :pid) 1)   # SIGHUP
  (call (kill*) (session :pid) 9)   # SIGKILL
  (call (close*) (session :fd))
  nil)

(defn pump
  ``Read from the terminal forever, handing each chunk to `on-output`.

  MEANT TO RUN ON ITS OWN THREAD -- see the note at the top of this file. The
  read is blocking and that is deliberate: a blocking read on a thread costs
  nothing, while polling a non-blocking fd burns a core to discover that
  nothing has happened.

  Returns when the program exits and the terminal reports end of file.``
  [session on-output]
  (def buf (buffer/new-filled 65536 0))
  # Bound ONCE for the life of the pump rather than per read. It stays inside
  # this function -- and therefore inside this thread -- which is what the note
  # above `bound` requires.
  (def reader (read*))
  (var running true)
  (while running
    (def got (call reader (session :fd) buf 65536))
    (cond
      (> got 0) (on-output (string (buffer/slice buf 0 got)))
      # 0 is EOF: the child closed the terminal. Negative is an error, and on
      # a master pty that means the same thing in practice -- the child is
      # gone and the fd will never produce anything again.
      (set running false)))
  nil)
