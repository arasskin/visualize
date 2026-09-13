Visualize parses programs into graphs and displays them on the browser in an embedded window manager for terminals:

The point of visualize is mainly to help you wrap your head around very big code projects. Visualize does this in two ways: Firstly, visualize exposes a few tools to help you organize the nodes in your graph.

For example, there is a box tool. If all your server code lives in src.server, you can say box src.server and it will put all your nodes in a nice box, if you don't want to see them anymore, you can say fold src.server and all your src.server nodes will collapse into one node, if this isn't enough, you can say hide src.server which will make those nodes and the arrows going to them disappear. Any of these actions can be undone by typing unbox... or unfold... or unhide... ...

All the organization tools work around the prefixes of the nodes being organized. In other words if a node is called src.server.core a box src command will box it, but so will box s, box sr, and box src.se and so on. This approach is meant to be non intruvise among other things. Meaning, for the most part, looking at code through visualize should not bias the way you write code.

The second helpful feature of visualize is its general window manager nature. Pressing alt + enter will spawn a terminal, terminals can be dragged around the screen, but they can also be docked to the top or bottom rails. The window a terminal sits in can be given a subtitle by pressing just to the right of its title. These terminals are meant to run llm harnesses among other things. Visualize comes with a cli tool called vz which gets prepended to the path of every terminal spawned withing vizualize. Typing vz on its own will spawn the default harness configured in visualize's startup shell script. This is a useful way of adding startup instructions to your agents, and it makes more sense to me then having a seperate startup configurations per workspace, although these approaches aren't incompatible.

VZ does more things. typing vz path/to/a/file will try to open that file with an appropriate code/markdown/graph reader. And, it will do so as a native browser element, not as a tui. This is a useful feature when combined with the ability to press on nodes that are linked to files and run commands on them. For example, pressing on a src.server.core node will show a small text input box where you can type vz or vim or any other terminal command. This will run vz ...src/server/core or vim ..., and pop up the output as a floating window on top of the node.

It can feel a little sketchy to put a long running important terminal process in the browser, but, I think these fears are unfounded. Terminals in the browsers correspond to real os processes running real terminal emulators. When a key is pressed in a browsers's terminal, it gets sent via websocket to the visualize server, then, visualize passses it on to the appropriate terminal process via their socket connection. The terminal does its thing and responds to the socket with the newly rendered terminal cells. These get passed along to the browser where they get transformed into pleasing html. If the browser crashes, or some terminal process held in visualize crashes, the remaining terminals are unnaffected. On startup, visualize will recover whatever terminal remains open and responsive from the previous session. To close a terminal, either close it from within visualize, or send ctrl-c to the terminal that spawned the original visualize process. That being said, there can be bugs. If a process must not crash, it's probably best to run it through something more proven.

There is also a search tool which can be invoked with command + f, this will draw a big red arrow around the node you're looking for.

Installation:

```bash
git clone git@github.com:arasskin/visualize.git
cd visualize
./visualize /path/to/your/project/
```

You will need a C compiler on your path to build the bundled Janet interpreter, terminal engine, and Graphviz library the first time you run it. Visualize bundles and builds its external dependencies inside its repo.

Usage/license/contributing:

The only thing I'd like visualize to be is useful.
