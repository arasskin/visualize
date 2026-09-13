Visualize parses programs into graphs and displays them on the browser in an embedded window manager for terminals:

*add video*

I grew up fumbling around with window managers: i3, dwm, bspwm, and some other stuff. Now I use a mac. Visualize is an amalgamation of many of the ideas I've been exposed to, strewn together in whatever way I see fit, and joined with my own noticeable idiosyncracies.  

Visualize is here to help organize codebases. You point it somewhere; it tries to figure out how the contents of every file relate to the contents of every other file (a depency graph for a project, an html file wanting a css file, a startup script invoking two different projects...), then you organize everything. I use this to understand macrostructure, and, given that I've delegated understanding microstructure to llms, I use this to do most of my work these days.

Visualize is a cult.
As far as I can tell, you can't actually visualize code.
I really want to visualize code: an image I can stare at, point. Sort of like cogs that spin, data that moves through wires. A literal representation of a system. So, of course, visualize is written in a lisp.
As far as I can tell, you just can't look at programs.

Installation:

```bash
git clone git@github.com:arasskin/visualize.git
cd visualize
./visualize /path/to/your/project/
```

You will need a C compiler on your path to build the bundled Janet interpreter, terminal engine, and Graphviz library. The build uses the vendored sources and requires no downloads.

Usage:

Click a file label and enter `vz` to read it in the pane at the click position. You can also run `vz path/to/file` inside a Visualize terminal to turn that pane into a document reader. Markdown is rendered as formatted text; C and Lisp sources use local syntax highlighting. The read-only view scrolls through the browser and refreshes when the file changes. Existing `vz` coordination commands remain available.

While running, press the question mark to see what you can do. Hovering over things should also be helpful.

Contributing:

Visualize was made with an llm. If something's broken (many things will probably be broken). An llm can fix it pretty easily. Feel free to do whatever you want with the code. This is just what's good enough for me.
