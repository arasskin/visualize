(import ./local)
(import ./protocol)
(import ../src.server/json)

(defn main [& args]
  (def path (or (get args 1) (os/getenv "VISUALIZE_SOCKET")))
  (unless path (error "usage: visualize-mcp <control-socket> (printed by visualize)"))
  (def handle (protocol/make (fn [name arguments] (local/call path name arguments))))
  (def incoming (ev/thread-chan 32))
  (ev/thread (fn [channel]
    (try
      (forever
        (def line @"")
        (forever
          (def byte (file/read stdin 1))
          (unless byte (ev/give channel nil) (break :eof))
          (buffer/push-string line byte)
          (when (> (length line) local/limit) (error "MCP input too large"))
          (when (= (get byte 0) 10) (break)))
        (when (empty? line) (break))
        (ev/give channel (string line)))
      ([e] (eprintf "%s" (string e)) (ev/give channel nil)))) incoming :n)
  (var active 0)
  (forever
    (def line (ev/take incoming))
    (unless line (break))
    (when (>= active 32)
      (while (>= active 32) (ev/sleep 0.01)))
    (++ active)
    (ev/go (fn []
      (defer (-- active)
        (when-let [reply (handle line)]
          (file/write stdout (json/encode reply) "\n")
          (file/flush stdout))))))
  (while (pos? active) (ev/sleep 0.01)))
