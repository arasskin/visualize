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

// Mouse tracking decides where the wheel goes: claude turns it on at startup
// and scrolls its own transcript on wheel reports, never the terminal -- so
// the host forwards the wheel exactly while these modes are on.
ok('the mouse starts with the browser', term.mouseReporting === false);
term.write('\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h');
ok('tracking plus SGR hands the wheel to the program', term.mouseReporting === true);
term.write('\x1b[?1000;1002;1003l');
ok('turning tracking off hands it back', term.mouseReporting === false);
term.reset();
term.write('\x1b[?1000;1006h');
ok('one h can carry several modes', term.mouseReporting === true);
term.reset();
ok('a session reset clears the modes', term.mouseReporting === false);

// Synchronized output: claude brackets every repaint in ?2026h..?2026l so a
// frame lands whole. Holding the paint while a frame is open is what keeps
// typing and scrolling from flickering through half-painted states.
term.reset();
term.write('one');
term.write('\x1b[?2026h two');
ok('an open frame holds the paint', !screen.innerHTML.includes('two'));
term.write(' three\x1b[?2026l');
ok('closing the frame paints it whole', screen.innerHTML.includes('one two three'));

// And an open frame must never become a frozen screen: a program that dies
// mid-repaint -- or an l the backlog trim ate -- is painted by the backstop.
term.reset();
term.write('\x1b[?2026hwedged');
await new Promise((r) => setTimeout(r, 300));
ok('a frame that never closes paints via the backstop', screen.innerHTML.includes('wedged'));

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

// A clear clears, exactly as in a real terminal: nothing is saved. An earlier
// version banked the doomed screen into scrollback and tried to guess
// afterwards whether the clear was a resize-repaint (delete the copy) or a
// real discard (keep it). The guess required every banked row to be repainted,
// and the harness's status line always holds a ticking timer -- one character
// of drift stranded a whole stale frame, input box and all, in scrollback for
// good. History is what the harness scrolls off the top, the one signal in
// the stream that is never ambiguous.
term.reset();
term.write('old 1\r\nold 2\x1b[2J\x1b[Hfresh');
check('clear-screen discards the screen', screen.innerHTML.split('\n'), ['fresh']);
check('clear-screen clears the grid', term.text()[0], 'fresh');

// The case that killed the banking version: a clear whose repaint differs by
// one ticked character must leave no stale copy of the old frame.
term.reset();
term.write('reply text\r\n2m 56s');
term.write('\x1b[2J\x1b[Hreply text\r\n2m 57s');
check('an almost-identical repaint leaves no stale frame',
      screen.innerHTML.split('\n'), ['reply text', '2m 57s']);

// A resize drag is a storm of clear-and-repaints; each clear discards, so the
// storm leaves one frame, not one per clear.
term.reset();
term.write('frame');
term.write('\x1b[2J\x1b[Hframe');
term.write('\x1b[2J\x1b[Hframe');
term.write('\x1b[2J\x1b[Hframe');
check('a resize storm leaves one copy, not one per clear',
      screen.innerHTML.split('\n'), ['frame']);

// What scrolls off the top is the history that IS kept -- now the only way
// anything enters scrollback while the size holds still.
term.reset();
for (let i = 1; i <= 12; i++) term.write(`line ${i}\r\n`);
check('scrolled-off rows stay in scrollback', screen.innerHTML.split('\n')[0], 'line 1');

// -- the split view: history appended once, live repainted -------------------
// The scrolling jank, root-caused: render() rebuilt scrollback + grid as one
// innerHTML string every paint -- 67x the cost of an empty screen at full
// scrollback, a full DOM teardown per frame, scroll anchoring with nothing
// stable to hold, selection dead every write. The fix splits the screen at
// the immutability boundary. These tests run the DOM path against a stub
// document and pin both the behaviour and the cost model.
function domScreen() {
  const el = (className) => ({
    className, _kids: [], _html: '',
    set innerHTML(v) { this._html = v; this._kids = []; this.sets = (this.sets || 0) + 1; },
    get innerHTML() { return this._html; },
    insertAdjacentHTML(_, h) { this._kids.push(h); this.appends = (this.appends || 0) + 1; },
    get firstChild() { return this._kids.length ? this._kids[0] : null; },
    removeChild() { this._kids.shift(); },
  });
  const screen = {
    ownerDocument: { createElement: () => el('') },
    _parts: [],
    append(...parts) { this._parts = parts; },
    get history() { return this._parts[0]; },
    get live() { return this._parts[1]; },
  };
  return screen;
}

{
  const s = domScreen();
  const t = makeTerminal(s, { rows: 4, cols: 20, showCursor: false });
  t.write('one\r\ntwo\r\nthree\r\nfour\r\nfive');
  check('a scrolled-off row lands in history, rendered',
        s.history._kids, ['<div>one</div>']);
  check('the live block holds only the grid',
        s.live.innerHTML.split('\n'), ['two', 'three', 'four', 'five']);

  const appendsBefore = s.history.appends;
  const before = s.history._kids.join('');
  // Ten x's stay inside the row; a wrap would scroll, which APPENDS -- that
  // is history growing, not history being rewritten.
  for (let i = 0; i < 10; i++) t.write('x');
  ok('streaming never rewrites history',
     s.history.appends === appendsBefore && s.history._kids.join('') === before);

  t.resize(2, 20);
  check('a shrink banks the surplus rows into history',
        s.history._kids.length, 3);

  t.reset();
  ok('reset clears history with the screen', s.history._kids.length === 0);
}

{
  // The cap trims the DOM alongside the model.
  const s = domScreen();
  const t = makeTerminal(s, { rows: 2, cols: 10, showCursor: false, scrollback: 3 });
  for (let i = 0; i < 8; i++) t.write(`r${i}\r\n`);
  ok('history keeps at most the cap', s.history._kids.length === 3);
}

{
  // THE COST MODEL, pinned: a write at full scrollback must cost what a write
  // at empty scrollback costs, because a paint no longer touches history.
  // The old render was ~67x here; 3x is generous headroom for noise.
  const s = domScreen();
  const t = makeTerminal(s, { rows: 24, cols: 113, showCursor: false });
  const cost = () => {
    const t0 = performance.now();
    for (let i = 0; i < 60; i++) t.write('x');
    return (performance.now() - t0) / 60;
  };
  const shallow = cost();
  for (let i = 0; i < 2100; i++) t.write(`filler line ${i}\r\n`);
  const deep = cost();
  ok(`a write at depth 2000 costs like a write at depth 0 (${shallow.toFixed(3)}ms vs ${deep.toFixed(3)}ms)`,
     deep < Math.max(shallow, 0.02) * 3);
}

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
