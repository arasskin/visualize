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
import { replay } from '../tools/replay.mjs';

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
    appendChild(child) { this._kids.push(child); },
    get firstChild() { return this._kids.length ? this._kids[0] : null; },
    removeChild(child) {
      if (child === undefined || child === this._kids[0]) { this._kids.shift(); return; }
      const i = this._kids.indexOf(child);
      if (i >= 0) this._kids.splice(i, 1);
    },
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
  check('the live block holds only the grid, one div per row',
        s.live._kids.map((d) => d._html), ['two', 'three', 'four', 'five']);

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
  // WIDE CHARACTERS own two cells. Emoji and CJK used to get one, shearing
  // every column to their right -- and an emoji, being a surrogate pair, was
  // actually fed to the grid as two broken halves.
  const t = makeTerminal({ innerHTML: '' }, { rows: 4, cols: 10, showCursor: false,
                                 scrollbackVisible: false });
  t.write('\u{1F525}x');           // fire emoji, then x
  ok('an emoji advances the cursor two cells', t.cursor.col === 3);
  check('the glyph and its neighbour survive intact', t.text()[0], '\u{1F525}x');
  t.write('\r\u4E2D\u6587');       // CJK: two ideographs
  ok('CJK ideographs are wide too', t.cursor.col === 4);
  t.write('\ra');                  // overwrite the first half of a pair
  check('overwriting half a wide pair spaces the orphan', t.text()[0], 'a \u6587');

  // A surrogate pair split across two chunks -- a 64KB read can land
  // anywhere -- must wait for its other half, like a split escape does.
  const t2 = makeTerminal({ innerHTML: '' }, { rows: 2, cols: 10, showCursor: false,
                                  scrollbackVisible: false });
  const fire = '\u{1F525}';
  t2.write(fire[0]);
  t2.write(fire[1]);
  check('a surrogate pair split across chunks reassembles', t2.text()[0], fire);

  // A wide char that would straddle the right edge wraps whole.
  const t3 = makeTerminal({ innerHTML: '' }, { rows: 2, cols: 3, showCursor: false,
                                  scrollbackVisible: false });
  t3.write('ab\u{1F525}');
  check('a wide char never straddles the edge', t3.text()[1], fire);

  // Combining marks attach to the character before them, zero cells wide.
  const t4 = makeTerminal({ innerHTML: '' }, { rows: 2, cols: 10, showCursor: false,
                                  scrollbackVisible: false });
  t4.write('e\u0301x');            // e + combining acute + x
  ok('a combining mark takes no cell', t4.cursor.col === 2);
  check('the mark rides its base character', t4.text()[0], 'e\u0301x');
}

{
  // THE CHANGED FLAG: onPaint's second argument says whether the paint moved
  // any ink. The glide in app.js glides only on a changed, non-growing paint
  // -- a transcript scroll -- so a paint that redraws the identical frame
  // (a mouse report echoed back as invisible CSI, a cursor motion with the
  // cursor hidden) must say so, or scrolling claude would lurch on echoes.
  const s = domScreen();
  const flags = [];
  const t = makeTerminal(s, { rows: 4, cols: 20, showCursor: false,
                              onPaint: (_lines, changed) => flags.push(changed) });
  t.write('hello');
  ok('a paint that draws reports changed', flags[flags.length - 1] === true);
  t.write('\x1b[H');
  ok('a paint that moves no ink reports unchanged',
     flags[flags.length - 1] === false);
  t.write('\x1b[2Jwiped');
  ok('the next real change reports changed again',
     flags[flags.length - 1] === true);
}

{
  // DIRTY ROWS: a paint rewrites only the rows whose HTML moved. A write
  // that touches the bottom row must not re-set the top ones -- that is the
  // whole difference between one div of work per frame and a grid teardown,
  // and it is what lets a selection in untouched live rows survive a paint.
  const s = domScreen();
  const t = makeTerminal(s, { rows: 4, cols: 20, showCursor: false });
  t.write('alpha\r\nbeta\r\ngamma');
  const setsBefore = s.live._kids.map((d) => d.sets || 0);
  t.write('!');   // appends to the gamma row only
  const setsAfter = s.live._kids.map((d) => d.sets || 0);
  ok('a bottom-row write leaves the upper rows untouched',
     setsAfter[0] === setsBefore[0] && setsAfter[1] === setsBefore[1]
       && setsAfter[2] === setsBefore[2] + 1);
  check('and the touched row holds the new text',
        s.live._kids[2]._html, 'gamma!');
}

{
  // DEFERRED WRAP: printing in the last column leaves the wrap OWED, and
  // any cursor motion cancels the debt. The naive version parked the cursor
  // one past the edge, where CSI C clamped it backward and the next
  // printable wrapped spuriously -- one-cell drifts that a delta-painting
  // program (claude patches lines in place and rarely clears) accumulated
  // into smeared frames.
  const t = makeTerminal({ innerHTML: '' }, { rows: 4, cols: 10,
    showCursor: false, scrollbackVisible: false });
  t.write('0123456789');
  ok('a full line leaves the cursor on its last column',
     t.cursor.row === 0 && t.cursor.col === 9);
  t.write('x');
  check('the next printable pays the wrap', t.text().slice(0, 2), ['0123456789', 'x']);
  // Motion cancels the debt: full line, cursor-forward, overwrite in place.
  const t2 = makeTerminal({ innerHTML: '' }, { rows: 4, cols: 10,
    showCursor: false, scrollbackVisible: false });
  t2.write('0123456789\x1b[Cq');
  check('a cursor motion cancels the owed wrap: no phantom row',
        t2.text().slice(0, 2), ['012345678q', '']);
  // SGR between the last column and the wrap must NOT cancel it.
  const t3 = makeTerminal({ innerHTML: '' }, { rows: 4, cols: 10,
    showCursor: false, scrollbackVisible: false });
  t3.write('0123456789\x1b[31mx');
  check('colour changes do not cancel the wrap',
        t3.text().slice(0, 2), ['0123456789', 'x']);
  // CR after a full line rewrites the SAME row.
  const t4 = makeTerminal({ innerHTML: '' }, { rows: 4, cols: 10,
    showCursor: false, scrollbackVisible: false });
  t4.write('0123456789\rZ');
  check('carriage return lands on the same row',
        t4.text()[0], 'Z123456789');
}

{
  // THE ALTERNATE SCREEN: claude runs its whole TUI there. Entering clears
  // (ignoring that clear was the margin garbage in the field -- pre-claude
  // content stayed visible wherever claude never painted), leaving
  // restores, and rows scrolled off while inside are repaint debris, not
  // history.
  const s = domScreen();
  const t = makeTerminal(s, { rows: 3, cols: 20, showCursor: false });
  t.write('shell prompt $');
  t.write('\x1b[?1049h');
  check('entering the alternate screen clears it', t.text(), ['', '', '']);
  t.write('tui frame');
  for (let i = 0; i < 6; i++) t.write(`\r\nspill ${i}`);
  check('rows scrolled off inside it never reach history',
        s.history._kids.length, 0);
  t.write('\x1b[?1049l');
  check('leaving restores what was there', t.text()[0], 'shell prompt $');
}

{
  // THE SHIFT DETECTOR: the one consumption signal the wheel pacing can
  // trust. A frame whose rows MOVED to new indices is a program answering
  // scroll reports; a frame that changed in place -- a ticking status line,
  // a streaming token -- is an agent working, and pacing on those floods
  // the pty (the wheel handler in app.js tells that story).
  const s = domScreen();
  const shifts = [];
  const t = makeTerminal(s, { rows: 16, cols: 30, showCursor: false,
                              onPaint: (_l, _c, shift) => shifts.push(shift) });
  const frame = (start, tick) => '\x1b[H\x1b[2J' + `status tick ${tick}\r\n`
    + Array.from({ length: 12 }, (_, i) => `line-${start + i}`).join('\r\n');
  t.write(frame(0, 1));
  check('the first frame has nothing to have moved from',
        shifts[shifts.length - 1], 0);
  t.write(frame(0, 2));
  check('a status tick repaints in place: no shift',
        shifts[shifts.length - 1], 0);
  t.write(frame(3, 2));
  ok('a scrolled repaint reports its displacement',
     shifts[shifts.length - 1] !== 0);
  t.write(frame(3, 3));
  check('and the next tick is in place again',
        shifts[shifts.length - 1], 0);
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

{
  // THE REPLAY TOOL, which turns a captured byte stream into a deterministic
  // rendering verdict. A clean stream parses with no suspects; the same
  // stream with an ESC torn out -- what a backlog trim does mid-sequence --
  // leaves escape-like text on screen, and the tool names the row.
  const frame = '\x1b[H\x1b[2Jhello\r\n\x1b[31mred line\x1b[0m\r\nworld';
  const clean = replay(frame, 6, 20);
  check('a clean capture parses with no suspects', clean.suspects.length, 0);
  check('and the frame is what was drawn',
        clean.screen.slice(0, 3), ['hello', 'red line', 'world']);
  const torn = replay(frame.replace('\x1b[31m', '[31m'), 6, 20);
  ok('a torn escape is reported as a suspect row',
     torn.suspects.length > 0 && torn.suspects[0].line.includes('[31m'));
}

if (failed.length === 0) {
  console.log(`  ok  ${passed} assertions (terminal)`);
} else {
  console.log(`  FAIL  ${passed} passed, ${failed.length} failed (terminal)`);
  for (const line of failed) console.log(`    - ${line}`);
  process.exit(1);
}
