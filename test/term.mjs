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

// -- resize ----------------------------------------------------------------------

term.reset();
term.write('hello');
ok('resize reports a change', term.resize(10, 40));
check('resize keeps the contents', term.text()[0], 'hello');
check('resize updates the size', [term.rows, term.cols], [10, 40]);
ok('resizing to the same size is a no-op', term.resize(10, 40) === false);

if (failed.length === 0) {
  console.log(`  ok  ${passed} assertions (terminal)`);
} else {
  console.log(`  FAIL  ${passed} passed, ${failed.length} failed (terminal)`);
  for (const line of failed) console.log(`    - ${line}`);
  process.exit(1);
}
