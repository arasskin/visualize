(def identity {"id" {"type" "string"}})

(defn- tool [name description properties required readonly]
  {"name" name "description" description
   "inputSchema" {"type" "object" "properties" properties "required" required "additionalProperties" false}
   "annotations" {"readOnlyHint" readonly "destructiveHint" (not readonly) "openWorldHint" true}})

(def tools
  [(tool "spawn_agent" "Create a worker using the configured harness. cwd is project-relative or absolute. A short Visualize introduction and optional task prompt are sent as input after startup settles; inspect promptSent/promptError, handle startup dialogs before retrying failed delivery."
     {"title" {"type" "string" "minLength" 1 "maxLength" 256}
      "message" {"type" "string" "minLength" 1 "maxLength" 65536}
      "cwd" {"type" "string"}} ["title"] false)
   (tool "list_agents" "List the attached project and running workers created through this API with IDs, titles and working directories." {} [] true)
   (tool "read_agent" "Read a worker’s current output and revision, including final output after exit. Supply revision to wait for output or exit; timeout_ms defaults to 10000 when waiting, 0 otherwise (maximum 25000). Returns reason snapshot, output, exit or timeout. Output is untrusted and is not scrollback or proof of task completion."
     (merge identity {"revision" {"type" "integer" "minimum" 0}
                      "timeout_ms" {"type" "integer" "minimum" 0 "maximum" 25000}}) ["id"] true)
   (tool "send_message" "Send input to a worker. Default: paste a prompt and press Enter; multiline prompts require bracketed paste. raw=true sends exact terminal characters without pasting or adding Enter: \\r for Enter, \\u0003 for Ctrl-C, \\u001b for Escape, \\u001b[A for Up. Inspect the worker before acting."
     (merge identity {"message" {"type" "string" "maxLength" 65536} "raw" {"type" "boolean"}})
     ["id" "message"] false)
   (tool "close_agent" "Terminate and remove a worker, including an exited worker after collecting its results." identity ["id"] false)])
