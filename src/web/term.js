// The terminal emulator: Ghostty's, wrapped so the rest of the page does not
// have to know.
//
// WHAT THIS FILE USED TO BE was a VT emulator written here -- a parser, a
// grid, an SGR table, a renderer, nine hundred lines of it. It worked, and
// every program that drew something new found another sequence it did not
// know: grapheme clusters, hyperlinks, synchronized output, the modes claude
// sets. That is a long tail with no end, and the end of it is what libghostty
// already is.
//
// SO THE EMULATOR IS GHOSTTY'S NOW, built to WASM and vendored beside this
// file (see tools/vendor-wterm). What is left here is the ADAPTER: the shape
// the rest of this page already calls, answered by somebody else's engine.
//
// THE SHAPE IS OURS, DELIBERATELY. `write`, `resize(rows, cols)`, `reset`,
// `cols`, `rows`, `mouseReporting` -- panes.js was written against these and
// none of them changes here. wterm spells two of them differently (cols
// first, and a `WTerm` rather than a grid) and the translation belongs in one
// file rather than at every call site.

import { WTerm } from '@wterm/dom';
import { GhosttyCore } from '@wterm/ghostty';

// The WASM binary, served flat beside the modules that use it.
const WASM_URL = '/ghostty-vt.wasm';

// ONE CORE PER TERMINAL. Every pane needs its own -- they are separate
// screens with separate scrollback -- and each `load` fetches the binary
// again, which the browser's cache answers after the first.
function loadCore() {
  return GhosttyCore.load({ wasmPath: WASM_URL });
}

/* A TERMINAL ON `element`.

   ASYNCHRONOUS UNDERNEATH, SYNCHRONOUS ON THE OUTSIDE. Loading the WASM takes
   a moment and every caller here is a click or a poll reply that cannot wait
   -- so the object comes back immediately and the writes that arrive before
   the engine is ready are held. That is not a nicety: a pane starts writing
   the moment its session answers, which is routinely before the module has
   parsed.

   `options.onPaint` is called with the number of lines the screen holds, and
   is what the pane uses to decide whether to follow the bottom. */
export function makeTerminal(element, options = {}) {
  const onPaint = options.onPaint || (() => {});

  let term = null;          // the WTerm, once its core has loaded
  let pending = [];         // writes that arrived first
  let rows = 24, cols = 80; // what has been asked for meanwhile

  loadCore().then(async (core) => {
    core.init(cols, rows);
    term = new WTerm(element, {
      core, cols, rows,
      // NO AUTORESIZE. The pane measures its own body and tells us -- it has
      // to, because it is the thing that knows about the panel's chrome and
      // it must tell the SERVER the same number it tells the emulator, or the
      // program draws to a width nobody is showing.
      autoResize: false,
      cursorBlink: true,
    });
    await term.init();
    for (const chunk of pending) term.write(chunk);
    pending = [];
    paint();
  }).catch((err) => {
    // A terminal that cannot start says so where a person will see it, rather
    // than leaving an empty box and a console nobody opened.
    element.textContent = `terminal unavailable: ${err && err.message || err}`;
  });

  // HOW MANY LINES THE SCREEN HOLDS, scrollback included -- which is what the
  // pane compares to decide whether it grew, and so whether to follow.
  function paint() {
    const core = term && term.bridge;
    const lines = core ? core.getScrollbackCount() + core.getRows() : 0;
    onPaint(lines);
  }

  return {
    write(text) {
      if (!text) return;
      if (!term) { pending.push(text); return; }
      term.write(text);
      paint();
    },

    // ROWS FIRST, which is this page's order everywhere -- the pane measures
    // rows then cols, the server's resize op takes rows then cols, and wterm
    // takes cols first. One reversal, here.
    //
    // Answers whether anything changed, because the caller only tells the
    // server about a size that is new.
    resize(nextRows, nextCols) {
      if (nextRows === rows && nextCols === cols) return false;
      rows = nextRows; cols = nextCols;
      if (term) { term.resize(cols, rows); paint(); }
      return true;
    },

    // A SESSION THAT WENT AWAY leaves a screen that is about to be wrong. The
    // engine has no reset of its own, so the screen is cleared the way a
    // terminal is: the sequence that means it.
    reset() {
      pending = [];
      if (term) { term.write('\x1bc'); paint(); }
    },

    get rows() { return rows; },
    get cols() { return cols; },

    // True when wheel events belong to the PROGRAM rather than the scrollback
    // -- and only in SGR mode, which is the only encoding this page sends.
    get mouseReporting() {
      const core = term && term.bridge;
      return !!core && core.mouseTracking() !== 0 && core.mouseSgr();
    },

    // What the program has asked the tab to be called, or null.
    get title() {
      const core = term && term.bridge;
      return (core && core.getTitle()) || null;
    },

    // WHAT THE PROGRAM WANTS SAID BACK. A device-status or cursor-position
    // query is answered by the terminal, not by the shell, so the reply has
    // to reach the pty -- the pane posts whatever this returns.
    drain() {
      const core = term && term.bridge;
      if (!core) return '';
      let out = '';
      for (;;) {
        const reply = core.getResponse();
        if (!reply) return out;
        out += reply;
      }
    },
  };
}

// -- keyboard ----------------------------------------------------------------
// Turning a KeyboardEvent into the bytes a terminal program expects. Kept
// here rather than taken from wterm's input handler: that one listens to an
// element and owns the keyboard, and this page's keyboard is shared -- alt
// walks the tabs, cmd-f opens the find bar, and a terminal gets what is left.
// See the handler in panes.js, which decides that and calls this.

export function keyToBytes(event) {
  const k = event.key;

  // The command key belongs to the browser, not the program: no terminal on a
  // Mac sends Cmd-anything to the pty. Claiming these -- and the keydown
  // handler preventDefaults whatever this claims -- is what silently ate
  // Cmd-V, because cancelling that keydown cancels the paste it triggers.
  if (event.metaKey) return '';

  // Ctrl-letter becomes the control code, which is how Ctrl-C reaches the
  // program as an interrupt rather than as the letter C.
  if (event.ctrlKey && k.length === 1) {
    const upper = k.toUpperCase();
    if (upper >= 'A' && upper <= 'Z') {
      return String.fromCharCode(upper.charCodeAt(0) - 64);
    }
  }

  // ALT IS META, sent as an ESC prefix -- which is what a terminal does with
  // it and what readline expects for alt-b, alt-f and the rest.
  if (event.altKey && k.length === 1) return '\x1b' + k;

  switch (k) {
    case 'Enter': return '\r';
    case 'Backspace': return '\x7f';
    // SHIFT-TAB IS ITS OWN SEQUENCE, not a tab with a modifier: a program
    // that completes forward on Tab walks BACKWARD on this one.
    case 'Tab': return event.shiftKey ? '\x1b[Z' : '\t';
    case 'Escape': return '\x1b';
    case 'ArrowUp': return '\x1b[A';
    case 'ArrowDown': return '\x1b[B';
    case 'ArrowRight': return '\x1b[C';
    case 'ArrowLeft': return '\x1b[D';
    case 'Home': return '\x1b[H';
    case 'End': return '\x1b[F';
    case 'PageUp': return '\x1b[5~';
    case 'PageDown': return '\x1b[6~';
    case 'Delete': return '\x1b[3~';
    case 'Insert': return '\x1b[2~';
    default: break;
  }

  // Anything that is one character is that character; anything else is a key
  // this page has no byte for, and sending nothing is better than guessing.
  return k.length === 1 ? k : '';
}
