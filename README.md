Visualize is a cult.

It is good to visualize.

```bash
git clone git@github.com:arasskin/visualize.git
cd visualize
./visualize /path/to/your/project/
```

You will also need to have graphviz available on your path.

While running, press the question mark to see what you can do, then start typing. You can hold alt to draw open the config, then press j/k to change the selected line, n/N to add a new line, c to comment a line, d to delete a line, h/l to move a line around. Or, you can do all that with a mouse and the buttons. Every button has a helpful tooltip if you hover.

A quick workflow involves 1. writing your command 2. holding down alt to choose the line in which you want to insert your command 3. releasing alt to close the config and bring focus back to the text box 4. pressing enter to submit what you are writing 5. repeating. Line selection is saved across opening and closing the config pane, so multiple insertions end up on the same line. Having multiple commands on the same line makes it faster to comment them all out at once, which makes it faster to visualize your project.

Become the visualizer.

TODO:
- [ ] remove graphviz dependency.
- [ ] add more *detail* to visualize. 
- [ ] change default config.
- [ ] built in llm support?
