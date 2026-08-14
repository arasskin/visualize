// The terminal emulator, tested as pure logic.
//
//     node test/term.mjs
//
// No browser and no DOM: the emulator only ever assigns to `innerHTML`, so a
// plain object stands in for the screen. Everything above the paint step is
// pure, which is what makes the interesting behaviour -- redraw in place --
// checkable without a harness, a network, or a rendering engine.
//
// Run from ./test/run alongside the Janet suite.

import { makeTerminal, keyToBytes } from '../web/term.js';

let passed = 0;
const failed = [];

function check(label, got, want) {
  if (JSON.stringify(got) === JSON.stringify(want)) {
    passed++;
  } else {
    failed.push(`${label}\n      got  ${JSON.stringify(got)}\n      want ${JSON.stringify(want)}`);
  }
}

function ok(label, value) {
  if (value) passed++;
  else failed.push(label);
}

const screen = { innerHTML: '' };
const term = makeTerminal(screen, { rows: 6, cols: 20, showCursor: false });

// -- the reason the emulator exists ------------------------------------------
// A harness REDRAWS IN PLACE as tokens stream: carriage return, erase the
// line, write it again. Appending text would leave one copy of every partial
// line on screen, which is why this is a grid with a cursor and not a log.

term.write('hello');
check('plain text lands on the grid', term.text()[0], 'hello');

term.write('\r\x1b[2Kgoodbye');
check('CR + erase-line redraws the line', term.text()[0], 'goodbye');

term.reset();
term.write('one\r\ntwo\r\nthree');
check('newlines advance rows', term.text().slice(0, 3), ['one', 'two', 'three']);

term.write('\x1b[1A\r\x1b[2KTWO');
check('cursor-up rewrites an earlier line',
      term.text().slice(0, 3), ['one', 'TWO', 'three']);

// -- cursor addressing --------------------------------------------------------

term.reset();
term.write('\x1b[3;5Hxy');
check('absolute positioning', term.text()[2], '    xy');

term.reset();
term.write('abcdef\x1b[1G\x1b[3P');
check('delete-characters shifts the rest left', term.text()[0], 'def');

term.reset();
term.write('abc');
term.write('\x1b[2D_');
check('cursor-left then write overwrites', term.text()[0], 'a_c');

// ESC[2K erases the line WITHOUT moving the cursor -- checked against a real
// pty, which leaves the same leading blank. Getting this wrong would shift
// every redrawn line by one column.
term.reset();
term.write('A\x1b[2KB');
check('erase-line leaves the cursor where it was', term.text()[0], ' B');

// -- colour --------------------------------------------------------------------

term.reset();
term.write('\x1b[38;5;196mRED\x1b[39m');
check('a 256-colour code does not corrupt the text', term.text()[0], 'RED');
ok('and does colour the span', /color:rgb\(255,0,0\)/.test(screen.innerHTML));

term.reset();
term.write('\x1b[1mbold\x1b[22m plain');
check('bold does not corrupt the text', term.text()[0], 'bold plain');
ok('and does embolden the span', /font-weight:600/.test(screen.innerHTML));

// -- the parser ----------------------------------------------------------------

// A 64KB read can land anywhere, including the middle of an escape sequence.
term.reset();
term.write('A\x1b[');
term.write('2KB');
check('an escape split across two writes still works', term.text()[0], ' B');

term.reset();
term.write('\x1b]0;a window title\x07visible');
check('OSC title sequences are swallowed', term.text()[0], 'visible');

term.reset();
term.write('\x1b[?25l\x1b[?2004h\x1b[?2026hshown');
check('private modes do not print', term.text()[0], 'shown');

term.reset();
term.write('1\r\n2\r\n3\r\n4\r\n5\r\n6\r\n7');
check('the screen scrolls at the bottom', term.text()[5], '7');

// -- keyboard --------------------------------------------------------------------

check('Ctrl-C becomes an interrupt', keyToBytes({ key: 'c', ctrlKey: true }), '\x03');
check('Ctrl-D becomes EOF', keyToBytes({ key: 'd', ctrlKey: true }), '\x04');
check('Enter is a carriage return', keyToBytes({ key: 'Enter' }), '\r');
check('Backspace is DEL', keyToBytes({ key: 'Backspace' }), '\x7f');
check('arrows are CSI sequences', keyToBytes({ key: 'ArrowUp' }), '\x1b[A');
check('shift-tab is back-tab', keyToBytes({ key: 'Tab', shiftKey: true }), '\x1b[Z');
check('alt prefixes with escape', keyToBytes({ key: 'b', altKey: true }), '\x1bb');
check('a printable key is itself', keyToBytes({ key: 'a' }), 'a');
check('an unmapped named key sends nothing', keyToBytes({ key: 'F13' }), '');
// Claiming Cmd-V would preventDefault the keydown, and with it the paste
// event that keydown triggers -- the pty would see a literal `v` instead.
check('cmd chords stay with the browser', keyToBytes({ key: 'v', metaKey: true }), '');

// -- resize ----------------------------------------------------------------------

term.reset();
term.write('hello');
ok('resize reports a change', term.resize(10, 40));
check('resize keeps the contents', term.text()[0], 'hello');
check('resize updates the size', [term.rows, term.cols], [10, 40]);
ok('resizing to the same size is a no-op', term.resize(10, 40) === false);

// A harness answers a resize by clearing the whole screen (2J, often with 3J)
// and repainting only the frame that fits the new size. The screenful under
// that clear used to vanish -- resizing the panel visibly ate history -- so
// clearing banks the screen in scrollback instead of discarding it.
term.reset();
term.write('old 1\r\nold 2\x1b[2J\x1b[Hfresh');
check('clear-screen banks the screen in scrollback',
      screen.innerHTML.split('\n').slice(0, 3), ['old 1', 'old 2', 'fresh']);
check('clear-screen still clears the grid', term.text()[0], 'fresh');

// But a clear is more often the FIRST HALF OF A REDRAW: on resize the harness
// clears and repaints the same conversation at the new width. Banking every
// such clear left one near-duplicate of the screen per clear, and a resize
// drag fires a dozen of them -- the symptom was scrollback holding the final
// frame over and over, each copy wrapped slightly differently. A bank is
// therefore provisional: when the live screen again contains the banked rows'
// ink, the bank was a redraw echo and dissolves.
term.reset();
term.write('alpha\r\nbeta');
term.write('\x1b[2J\x1b[Halpha\r\nbeta');
check('a repaint of the same screen dissolves the bank',
      screen.innerHTML.split('\n'), ['alpha', 'beta']);

// The comparison is ink, not lines: the same words rewrapped at a new width
// still match.
term.reset();
term.write('one two\r\nthree');
term.write('\x1b[2J\x1b[Hone two three');
check('a rewrapped repaint still dissolves the bank',
      screen.innerHTML.split('\n'), ['one two three']);

// A width shrink clips the grid before the clear even arrives (resize()
// reflows by truncating), so the banked rows are fragments of the lines the
// repaint redraws in full. Fragments match as substrings.
term.reset();
term.write('a long line of words\r\ntail');
term.resize(10, 12);
term.write('\x1b[2J\x1b[Ha long line\r\nof words\r\ntail');
check('a clipped bank dissolves into the full repaint',
      screen.innerHTML.split('\n'), ['a long line', 'of words', 'tail']);
term.resize(10, 40);

// Each clear in a storm settles against its own repaint.
term.reset();
term.write('frame');
term.write('\x1b[2J\x1b[Hframe');
term.write('\x1b[2J\x1b[Hframe');
term.write('\x1b[2J\x1b[Hframe');
check('a resize storm leaves one copy, not one per clear',
      screen.innerHTML.split('\n'), ['frame']);

// -- painting when there are no frames --------------------------------------
// THE FROZEN-SCREEN BUG. requestAnimationFrame does not fire in a hidden tab,
// and the paint used to be scheduled on it alone -- setting a `painting` guard
// that only the callback cleared. A terminal that received output while hidden
// therefore set the guard, never ran the callback, and never painted again,
// even after the tab came back. The cursor kept blinking throughout, because
// that is a CSS animation.
//
// Simulated by giving the emulator an rAF that never calls back, which is
// exactly what a hidden tab is.
{
  const realRAF = globalThis.requestAnimationFrame;
  globalThis.requestAnimationFrame = () => {};   // schedules nothing, ever

  const hidden = { innerHTML: '' };
  const t2 = makeTerminal(hidden, { rows: 4, cols: 20, showCursor: false });
  t2.write('while-hidden');

  // The timer is what has to save this, so wait past it.
  await new Promise((r) => setTimeout(r, 200));
  ok('a hidden tab still paints, via the timer', hidden.innerHTML.includes('while-hidden'));

  // And it must not be wedged afterwards: the guard has to have been cleared,
  // or the SECOND paint is the one that never happens. Checked against the
  // grid rather than the markup, since 20 columns wraps the combined text and
  // the wrap is not what this is testing.
  t2.write('!');
  await new Promise((r) => setTimeout(r, 200));
  ok('and keeps painting after that', hidden.innerHTML.includes('while-hidden!'));

  globalThis.requestAnimationFrame = realRAF;
}

// -- painting is prompt, and still coalesces --------------------------------
// Two properties in tension, and both matter for how the terminal feels.
//
// PROMPT: the timer backing up rAF used to wait 100ms, which a visible tab
// paid on every keystroke echo -- most of a tenth of a second added to the one
// interaction a person watches closely. It is 0 now.
//
// COALESCED: but a burst of writes must still produce ONE render, or a
// streaming agent repaints the whole grid per chunk. Both callbacks landing in
// the same synchronous burst is what makes that free.
{
  const realRAF = globalThis.requestAnimationFrame;
  let renders = 0;
  const counted = { set innerHTML(v) { renders++; }, get innerHTML() { return ''; } };
  globalThis.requestAnimationFrame = (fn) => setTimeout(fn, 16);

  const t3 = makeTerminal(counted, { rows: 24, cols: 80 });
  for (let i = 0; i < 200; i++) t3.write(`line ${i}\r\n`);
  await new Promise((r) => setTimeout(r, 120));
  check('a burst of 200 writes paints once', renders, 1);

  // And a later write still paints, rather than being swallowed by a guard
  // the burst left set.
  t3.write('after');
  await new Promise((r) => setTimeout(r, 120));
  check('a write after the burst paints again', renders, 2);

  globalThis.requestAnimationFrame = realRAF;
}

if (failed.length === 0) {
  console.log(`  ok  ${passed} assertions (terminal)`);
} else {
  console.log(`  FAIL  ${passed} passed, ${failed.length} failed (terminal)`);
  for (const line of failed) console.log(`    - ${line}`);
  process.exit(1);
}
