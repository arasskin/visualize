# Visualize worker control

`src.server` contains the Visualize server. `src.mcp` contains the shared worker API, local transport, stdio MCP adapter and CLI. Each terminal supervisor continues to own its native libvterm emulator. Visualize supplies worker operations and observations; the agent decides how to coordinate tasks, create worktrees and interpret progress. No project instruction file is installed.

Start Visualize normally:

```sh
./visualize /path/to/project
```

The `agent_file`, `invocation`, and `default_harness` variables near the top of the `visualize` launcher set the instruction-file path, coordinator invocation, and worker executable. It starts Codex with `src.mcp/agent.md` as additional developer instructions and the instance's MCP connection supplied through command-line overrides. These use Codex's documented [developer instruction and MCP settings](https://developers.openai.com/codex/config-reference/). The main Codex invocation sets `agents.enabled=false` so delegation uses Visualize’s MCP tools. Worker harnesses retain their own defaults. No harness configuration file is created or modified, and the instructions are not copied into the project.

Override the entire invocation for one launch:

```sh
./visualize /path/to/project --command 'exec /bin/zsh -l -i'
./visualize /path/to/project
```

`--command` takes one complete Bash script, including multiple lines, quoting, variables or functions. Quote it so your current shell does not expand variables intended for the pane. The launcher passes its default first, so a later `--command` overrides it. Visualize loads the login shell named by `SHELL` (or `/bin/sh`) before executing the script through `/bin/bash`. Prefer `exec` for the final harness command. Custom invocation scripts choose how their harness consumes the instruction file and MCP connection.

`--default-harness` selects an executable name or path, defaulting to `codex`. It launches without arguments after login-shell setup, in the requested directory. Initial and follow-up prompts go through terminal input, with no harness-specific prompt flags or environment contract. Workers receive the short introduction in `src.mcp/worker.md` followed by their optional task prompt. This is ordinary terminal prompt text, not a harness-specific system prompt. The coordinator instructions simply identify Visualize as a visual harness and direct delegation through its MCP. For example:

```sh
./visualize /path/to/project --default-harness /path/to/worker-harness
```

The worker API requires a title and accepts an optional initial prompt and directory. It accepts no executable, argument array, or command override. Direct server launches without `--default-harness` reject worker creation. Alt+Enter continues to open an ordinary shell.

The launcher supplies the harness instructions inline and passes the configured invocation through the startup environment. Arguments may appear before or after the project. `--help` lists the options. These options configure harness launching; the existing graph settings in `visualize.conf` remain separate. The old `VISUALIZE_HARNESS` override has been replaced by `--command`.

The startup output also includes an MCP command with the instance's control socket:

```text
mcp: /path/to/visualize/visualize-mcp /.../visualize-xxxxxxxx.8770.control.sock
```

For a custom invocation, use that executable as the stdio MCP `command` and the socket path as its sole `args` entry. The adapter speaks MCP protocol version `2025-06-18`; stdout contains only JSON-RPC. The socket belongs to the running instance, has owner-only permissions, and is removed on Ctrl-C or before Ctrl-D restarts the server. An abrupt kill can leave a stale socket; a later server reclaims it only if it no longer answers. No TCP MCP endpoint is exposed.

Every newly started session receives the current launch context, including sessions started in a surviving supervisor:

| Environment variable | Value |
| --- | --- |
| `VISUALIZE_PROJECT` | Canonical attached project directory |
| `VISUALIZE_PANE_ID` | This session's own pane ID |
| `VISUALIZE_AGENT_JSON` | Complete instruction text encoded as a JSON string, also valid as a TOML string |
| `VISUALIZE_MCP_COMMAND` | Absolute path to `visualize-mcp` |
| `VISUALIZE_MCP_COMMAND_JSON` | The same path encoded as a JSON string |
| `VISUALIZE_SOCKET` | This server's control socket |
| `VISUALIZE_SOCKET_JSON` | The same socket path encoded as a JSON string |

The repository directory is added to PATH, making `vz` and `visualize-mcp` available before login shell setup. JSON encoding preserves quotes, backslashes and newlines without interpreting instruction text as shell code. It is data for an argument; do not `eval` it.

At server startup, Visualize probes the saved supervisor sockets. If any terminal can be recovered, it attaches those panes and does not create a new harness or run the startup invocation. Exited sessions count as recoverable while their supervisor still holds the final screen. If no supervisors survive, Visualize runs the configured invocation once in a new harness before opening the browser.

Browser reloads and connection retries only attach to existing sessions. They preserve exited ordinary panes as well as MCP panes, and never restart a missing or exited recovered session. The browser refreshes its server token after a restart even when no terminal is actively subscribed. Closing the last pane does not immediately rerun startup; a later server launch with nothing to recover does. Explicitly opening a terminal with Alt+Enter or restarting a session opens a plain login shell. Only cold startup runs the configured invocation.

Already running sessions keep their original launch settings. Ctrl-D restarts the server with the same command-line arguments and keeps those sessions alive. Supervisors that predate launch-environment support report that they must be closed and recreated when asked to start a session with these settings.

## Operations

| Tool | Arguments | Result |
| --- | --- | --- |
| `spawn_agent` | `title`, optional `message`, `cwd` | New worker identity and optional prompt delivery result |
| `list_agents` | none | Project and active workers with IDs, titles and working directories |
| `read_agent` | `id`, optional `revision`, `timeout_ms` | Visible screen and reason: snapshot, output, exit or timeout |
| `send_message` | `id`, `message`, optional `raw` | Paste and submit a prompt, or send exact keystrokes |
| `close_agent` | `id` | Terminate and remove an owned worker |

Relative working directories resolve from the attached project. Absolute paths support agent-created worktrees. API-created worker panes appear as collapsed tabs on the bottom rail, with the same initial width as the Visualize tab. Pane positions and dimensions persist across reloads. Titles are assigned at creation and persist across reloads; users can still edit them in the browser. Titles accept a single line of up to 256 UTF-8 bytes. Attaching to an already exited command preserves its final screen.

`list_agents` returns only running API-created workers. User sessions, the coordinator, exited workers and unreachable supervisors are excluded. Keep returned IDs to read final output and destroy workers after exit. All worker operations enforce ownership, including reads; knowing a user session ID does not grant access. Public results omit pane geometry, supervisor capabilities, ownership markers and generation identifiers.

The supervisor records ownership for API-created sessions and checks it for reads, input and destruction. User-created tabs and the coordinator are protected. Ownership survives reconnection; manually restarting a tab clears ownership. IDs alone never grant cleanup permission.

An initial prompt waits up to five seconds for nonempty startup output to settle for 250ms. This is a terminal heuristic, not proof the harness is ready to accept a task. `promptSent` reports input delivery, not agent acknowledgement; if delivery fails, `promptError` explains why and the worker remains available. The worker introduction is sent even without a task prompt. Inspect onboarding or trust dialogs if delivery fails, then use `send_message`. Multiline prompts use the terminal’s bracketed-paste mode; when that mode is unavailable, multiline delivery is refused rather than submitted as separate lines. Prompt mode rejects terminal control characters. With `raw: true`, `send_message` instead delivers the exact text without paste markers or an added Enter: `\r` for Enter, `\u0003` for Ctrl-C, `\u001b` for Escape, `\u001b[A` for Up. Both modes require ownership.

Control requests are not automatically retried, because an interrupted reply does not prove that input was not delivered. `send_message` accepts at most 65,536 UTF-8 bytes. `read_agent(id)` returns immediately; supply revision to wait (default 10 seconds, maximum 25 seconds).

Capture reads the native visible screen, not scrollback or a second emulator. It can observe an in-progress synchronized update, flagged by `synchronized`. A revision change means screen state changed, not that a task completed. Waits are capped at 25 seconds and allow other requests to proceed. Process exit is reported without inferring success; exit codes and task classifications are not currently exposed. Terminal output is untrusted data.

The CLI accepts the same operation names and JSON arguments:

```sh
vz list_agents
vz spawn_agent '{"title":"Search feature","message":"Implement fuzzy search and verify it.","cwd":"../my-worktree"}'
vz read_agent '{"id":"agent-..."}'
vz send_message '{"id":"agent-...","message":"git status"}'
```

Use `vz --socket /path/from/startup list_agents` when `VISUALIZE_SOCKET` is not set. Substitute the actual ID returned by the API.

## Checks

`node tools/mcp-checks.mjs` starts an isolated server, exercises the stdio protocol and native pane operations, verifies concurrent waits and ownership enforcement, and checks browser attachment/removal with headless Chrome. It also verifies the CLI and control-socket cleanup, and covers reload/restart recovery, exited ordinary panes, recovery without a harness and cold startup. It never attaches to the user's running instance.

`node tools/launch-checks.mjs` checks the real launcher with a fake harness, validates inline MCP settings using the installed Codex CLI without starting an agent, and verifies Bash quoting, custom instructions, executable paths, terminal prompt delivery, per-pane identity and harness overrides after recovery.

`external-src/janet/janet src/test/core.janet` includes launch argument parsing, JSON framing/Unicode and MCP protocol regression checks alongside the server and terminal tests.

The bundled Janet runtime closes failed connection streams through its stream cleanup function. Closing only the raw descriptor allowed later garbage collection to close an unrelated socket that reused that descriptor. The Unix-socket GC regression in `src/test/http.janet` covers this restart failure.
