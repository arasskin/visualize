Each project directory has a `visualize_config` file. Commands start a line and take space-separated arguments. The available forms are `box prefix color?`, `fold prefix`, `hide prefix`, `only prefix`, `visualize prefix`, `lines`, and `animate`. Here, `prefix` is the start of a node path, such as `src.server`; it is not a command or alias binding:

```text
box b
box b.a
fold b
lines
```

Open the file with `vz visualize_config`. The editor draws a dependency graph: prefixes depend on their descendants and commands, so `fold src.server.parsers` draws `src → src.server → src.server.parsers → fold`. Intermediate prefixes appear even when they have no command of their own. The embedded Graphviz `dot` engine arranges the graph in layers, with arrows pointing down and leaf nodes aligned at the bottom. Both the config editor and the main project graph use `dot`.

Duplicate commands are removed on reading and saving, keeping the first occurrence, its formatting, inline comment, and position. Comparison uses the parsed verb and arguments, so `fold src` and `fold   "src"` are duplicates even with different inline comments. Different arguments remain distinct, including colors, case, and spaces inside quoted names. Active and commented commands remain distinct. Repeated blank lines collapse to one, and leading and trailing blank lines are removed. Entering an already active command leaves the file unchanged, and commenting or renaming a subtree also removes any duplicates that operation creates.

Saved pane state uses one line per terminal, outside the command graph:

```text
@visualize terminal harness socket /tmp/harness.sock placement bottom 0 640 480 label "Project work"
@visualize terminal 2 socket /tmp/2.sock placement floating 120 240 800 600 document "/project/notes.md"
```

The terminal ID is followed by optional `socket`, `placement`, `label`, and `document` fields. Rail placement is `top|bottom index width height`; floating placement is `floating x y width height`. Values containing spaces or special characters use JSON string quoting. Each field can change independently. Older separate placement, label, and Markdown records are merged by terminal ID when the file is read or saved. Saving metadata adds no blank separators.

The input at the top applies one command on Enter: an active match stays unchanged, a commented match is uncommented in place, and a missing command is appended. Autocomplete offers verbs, project prefixes and colors. Use the arrow keys or Ctrl+N/P to select a suggestion and Tab or Enter to accept it; Enter without a selected suggestion submits the command. Quote arguments containing spaces. Parentheses are not part of the syntax.

Prefix any command name with `un` to comment out its matching active lines: `unfold src`, `unbox src blue`, `unhide src`, `unonly src`, `unvisualize lib`, `unlines`, or `unanimate`. Use the joined form, not `un fold`. Matching compares the verb and arguments, ignoring spacing, quoting, and inline comments. If no active match exists, nothing changes. The `un` command itself is not stored. Typing the original command again uncomments it in place, preserving its position and inline comments. Only commands with no existing match are appended. This works in both the main command input and the config editor input.

The search field beside it searches the graph. The first term matches a node label; subsequent terms narrow the results by labels in its prefix ancestry. For example, `fold a` finds a `fold` command under `a`, including through a descendant prefix. Search and autocomplete match contiguous text, ignoring case and treating underscores as displayed spaces, just like the main graph. They do not search the underlying file text. Autocomplete suggests node labels, then ancestor prefixes of the nodes matched so far. Use the arrow keys or Ctrl+N/P to select a suggestion, Tab to accept the first or selected suggestion, or click one. Enter accepts a selected suggestion; otherwise it cycles results, with Shift+Enter going backward. Escape dismisses suggestions, then clears the search. With suggestions closed, the arrow keys also cycle results. Ctrl/Cmd+F within the editor focuses search.

The selected node gets a red outline and arrow. Search centers it in the pane and anchors its screen position through graph updates. The arrow stays attached during pan and zoom and retains its size on screen.

Click a prefix label to edit the part it controls. For `src.server`, the input contains `server`; changing it to `backend.api` moves the branch to `src.backend.api` and updates `src.server.parsers` to `src.backend.api.parsers`. Dots introduce intermediate prefixes beneath the existing parent. Empty segments and slashes are not allowed. Enter saves; Escape or clicking away cancels. Only the open config file changes: source files and directories are never renamed. Comments, colors, and unrelated paths are preserved. Renaming to an existing branch joins the branches and removes identical lines. Other editors synchronize from the saved file; a rename is rejected if the file changed while the label was being edited.

Every node has two actions:

- `#` comments all commands in that node's subtree. A fully commented subtree is faded; press `#` again to uncomment it.
- `×` deletes all commands in that subtree.

A prefix includes commands for itself and its descendant prefixes. A command node affects only its own line. Acting on `b` includes `b.a`, but does not include `bee`. Comments are stored by adding `#` to each affected command line; prefixes themselves do not add extra lines to the file.

Multiple editors of the same file synchronize from disk. New commands append to the current file, and subtree actions reject a stale graph instead of modifying the wrong lines. Saved pane metadata is preserved. The command input keeps its focus and unfinished text during refreshes.

Drag the graph to pan. Scroll or pinch to zoom around the pointer, using the same sensitivity and limits as the main graph. With the graph focused, Ctrl/Cmd `+` and `-` zoom, and Ctrl/Cmd `0` fits the graph. Navigation stays in place during file refreshes and pane resizing, and never moves the command input.

Run `./src/test/run` for the parser, subtree, and worker tests. Run `node tools/config-editor-checks.mjs` for browser coverage of autocomplete, focus retention, append, subtree actions, and synchronization between editors. The browser test uses a temporary project and headless Chrome.
