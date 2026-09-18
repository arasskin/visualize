Visualize opens your chosen harness on a fresh start. Harnesses manage their own agents using their native tools and settings. Visualize does not inject orchestration instructions or install an MCP server.

The `startup_prompt` variable in `./visualize` describes dependency graphs, the `.visualize` format, and project-relative file references, with an example. It does not prescribe when to use the format. The launcher passes it through Codex's [developer instructions setting](https://learn.chatgpt.com/docs/config-file/config-reference). Set the `invocation` variable to choose the command:

```sh
invocation='exec codex -c "developer_instructions=$VISUALIZE_STARTUP_PROMPT_JSON"'
# Or: invocation='exec claude --append-system-prompt "$VISUALIZE_STARTUP_PROMPT"'
```

For one launch, override it with `./visualize /path/to/project --command 'exec your-harness'`. The command is a Bash script executed after login-shell setup, in the project directory. Arguments may appear before or after the project path. Alt+Enter opens a plain terminal.

`vz` without arguments executes the same configured invocation in the current terminal. `vz path/to/file` opens that file as a document in its current pane. Supported views include Markdown, highlighted source, and the `visualize_config` editor.

The local document connection uses a private Unix socket, exposed through `VISUALIZE_SOCKET`; `VISUALIZE_PANE_ID` identifies the calling pane. `VISUALIZE_PROJECT` gives the project directory and `VISUALIZE_MAIN_HARNESS_COMMAND` carries the invocation. The socket accepts document opening only, with no agent operations. Argument parsing, shell invocation, and both ends of the local document connection live together in `src.server/cli.janet`.

`VISUALIZE_STARTUP_PROMPT` carries the prompt text and `VISUALIZE_STARTUP_PROMPT_JSON` carries its quoted form for Codex. New sessions receive the current prompt even when their supervisor survived a restart. Running sessions keep their existing instructions.

On restart, surviving terminals are recovered without rerunning the invocation. Previously created worker tabs recover as ordinary terminals. Ctrl-D replaces the server process without waiting for an in-progress graph operation, while preserving terminal sessions; Ctrl-C stops the server and its terminals. Running harnesses retain their existing settings until restarted.

Run `node tools/launch-checks.mjs` to check the real launcher with a fake harness, custom Bash commands, document opening, and recovery. Run `./src/test/run` for server and terminal tests.
