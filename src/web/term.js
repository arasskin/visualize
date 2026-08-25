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
  // WHAT THE KEYBOARD PRODUCED, handed straight to whoever owns the pty.
  // See `onData` below: this is wterm's documented way of getting input out,
  // and taking it means taking its whole key model rather than half of one.
  const onData = options.onData || (() => {});

  let term = null;          // the WTerm, once its core has loaded
  let ready = false;        // ...and once its init() has finished
  let pending = [];         // writes that arrived first
  let rows = 24, cols = 80; // what has been asked for meanwhile

  /* THE INLINE HEIGHT WTERM WRITES ONCE, AND WE DO NOT WANT.

     With `autoResize: false` -- which is what we want, because the pane is
     the thing that knows its own chrome -- wterm locks an inline height on
     the element at init and never touches it again. Its `resize` reflows the
     grid and leaves that height behind, so the element keeps whatever size
     the FIRST geometry gave it.

     That is what opened a terminal slightly scrolled. The lock ran at
     wterm's construction defaults against its fallback row height (24 rows x
     17px = 408px); the pane then resized to the 20 rows it actually had
     (324px); and the 84px difference was empty element hanging below the
     grid, which the follow-the-output pin dutifully scrolled to the bottom
     of -- pushing the top rows out of sight.

     The height is cleared rather than corrected. `.term .screen` is a flex
     child that scrolls (see style.css), so the box is the panel's business
     and the grid inside it is wterm's; an inline number here could only
     disagree with one of them. */
  function unlockHeight() {
    if (!ready) return;
    element.style.height = '';
  }

  loadCore().then(async (core) => {
    core.init(cols, rows);
    term = new WTerm(element, {
      core, cols, rows,
      // THE KEYBOARD IS WTERM'S, which is how the package is meant to be
      // used. `onData` is the documented outlet: every keystroke, paste and
      // mouse report the terminal produces arrives here as the bytes a pty
      // expects, and this hands them on.
      //
      // WHAT WE WERE DOING INSTEAD was translating KeyboardEvents ourselves
      // in a table beside this file. It was close, and close is what broke
      // claude: a program can turn on APPLICATION CURSOR KEY MODE, after
      // which an arrow is `\x1bOA` rather than `\x1b[A`, and only the
      // emulator knows the mode is on. Our table could not -- it never
      // looked at the terminal -- so it sent the wrong four bytes for every
      // arrow press and the display came apart. The same table also had no
      // bracketed paste, no IME composition, and no focus reporting.
      onData,
      // NO AUTORESIZE. The pane measures its own body and tells us -- it has
      // to, because it is the thing that knows about the panel's chrome and
      // it must tell the SERVER the same number it tells the emulator, or the
      // program draws to a width nobody is showing.
      autoResize: false,
      cursorBlink: true,
    });
    await term.init();
    // READY ONLY NOW, and the flag is the whole point: `term` is assigned by
    // the line above's constructor, but a WTerm cannot take a write until
    // `init` has awaited its bridge into place. Gating on the variable rather
    // than on this flag left a window -- one await, but a real one, since the
    // pane starts writing the moment its session answers -- where a write saw
    // a truthy `term`, skipped the queue, and went to an engine that was not
    // there yet. The bytes that did that were lost while the queued ones
    // replayed after them, which on screen is a line of typing coming out
    // duplicated and out of order.
    ready = true;
    for (const chunk of pending) term.write(chunk);
    pending = [];
    unlockHeight();
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
      if (!ready) { pending.push(text); return; }
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
      if (ready) { term.resize(cols, rows); unlockHeight(); paint(); }
      return true;
    },

    // A SESSION THAT WENT AWAY leaves a screen that is about to be wrong. The
    // engine has no reset of its own, so the screen is cleared the way a
    // terminal is: the sequence that means it.
    reset() {
      pending = [];
      if (ready) { term.write('\x1bc'); paint(); }
    },

    // TAKE THE KEYBOARD. wterm listens on a hidden textarea rather than on
    // the element, so focusing the element directly is what left its input
    // handler constructed and deaf -- which is how a key table came to live
    // in this page at all. Routed through wterm, which knows where its own
    // listeners are.
    focus() { if (ready) term.focus(); else element.focus(); },

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
//
// THERE IS NO KEY TABLE HERE ANY MORE, and that is the point of this file.
//
// What stood here turned a KeyboardEvent into pty bytes: arrows, Home, the
// function keys, ctrl-letter, alt-as-meta. It was written when the emulator
// was ours and it kept working by inertia after the emulator became
// Ghostty's -- wterm's own InputHandler was constructed all along and simply
// never received a keystroke, because the pane focused the screen element
// rather than the textarea wterm listens on.
//
// It broke claude. A full-screen program sets APPLICATION CURSOR KEY MODE
// and from then on an arrow is `ESC O A`, not `ESC [ A`. Which one is right
// is a fact about the TERMINAL, not about the key, and a table that never
// asks the terminal cannot know it. Every arrow went out wrong and the
// screen came apart. Bracketed paste, IME composition and focus reporting
// were missing for the same reason: they are all modes the emulator tracks.
//
// wterm reads all of them off the bridge and reports the result through
// `onData` (see `makeTerminal`). Using it is what the package documents, and
// it is one fewer thing here that can be subtly wrong.
