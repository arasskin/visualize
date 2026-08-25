// The config editor: the list of lines, the compose bar, completions, the
// help panel and the keyboard that drives them.
//
// WHAT IS LEFT AFTER THE SPLIT, and it is one thing rather than the remainder
// of several. The alt chords and the completion list read and write the same
// list of lines the rows do -- pulling either out would mean handing it the
// editor's insides back, which is a way of saying it was never separate.
//
// This file is also where the page is put together: the modules below know
// nothing of each other, so their hooks are wired here at the bottom.

import { pane, wire as wireGraph, paint, repaint, fit, fitSoon, isTouched, hatchFolded } from './graph.js';
import {
  find, hits, wire as wireFind, placeArrow, keepHitInView, redrawFind,
  forgetUnit,
} from './find.js';
import { moduleNames, hideEdge, wireEdges, keepEdgeLabel } from './hover.js';
import {
  configPanel, makeConfigPanel, rail, EDGES,
  selectPane, pickedPanel, revealTab, openTerminal, resnap,
  startRail, wire as wirePanes,
} from './panes.js';

// THE TWO THINGS THE VIEWPORT CALLS BACK INTO. It repaints and it fits; the
// find bar wants to know about both -- the arrow is drawn in screen pixels so
// it has to be replaced after a zoom, and a mark can be carried off the edge
// by one. Passed in rather than imported by `graph.js`, which would put the
// two modules in a circle.
wireGraph({ onRepaint: () => placeArrow(), onFit: () => keepHitInView() });


fitSoon();
wireEdges();
hatchFolded();
window.addEventListener('load', fitSoon);
// Refit on resize only while untouched, so a resize never throws away a view
// the user panned to deliberately.
window.addEventListener('resize', () => {
  // THE EDGES MOVED, so anything held against one follows them.
  resnap();
  if (!isTouched()) fit();
});

// -- the config editor -------------------------------------------------------
// Not a text editor -- a list of lines with buttons. Every button is an edit to
// the config file on disk, and the server answers with the graph that file now
// produces.

// -- the watcher ------------------------------------------------------------
// The source changed on disk, so the graph should change with it. This is
// what the Regenerate button used to be, minus the part where a person had
// to remember they had edited something.
//
// A PARKED REQUEST, not a timer: /watch holds until the tree moves or its
// deadline passes, so an idle project costs one open request rather than a
// poll every second, and an edit shows up as fast as the walk notices it.
// The chain re-parks itself; a failure backs off rather than hammering a
// server that may be restarting.
let sourceGeneration = 0;

async function watchSource() {
  for (;;) {
    try {
      const r = await fetch(`/watch?k=${encodeURIComponent(window.TOKEN)}`, {
        method: 'POST',
        body: JSON.stringify({ generation: sourceGeneration }),
        signal: AbortSignal.timeout(35000),
      });
      const out = await r.json();
      const first = sourceGeneration === 0;
      sourceGeneration = out.generation;
      // `first` is the page learning where the counter started, not an edit.
      if (out.changed && !first) {
        status.textContent = 'source changed, redrawing...';
        await send('run', -1, true);
      }
    } catch (e) {
      await new Promise((r) => setTimeout(r, 2000));
    }
  }
}

const status = document.getElementById('status');
const panel = document.getElementById('config');
const bar = document.getElementById('bar');
const body = document.getElementById('body');
const grip = document.getElementById('grip');
const rows = document.getElementById('lines');
const problems = document.getElementById('problems');

let lines = [];
// Per-line complaints, keyed by line index -- drawn under the line itself
// rather than collected into a list that names line numbers.
let faults = {};
let busy = false;
// WHICH LINE IS SELECTED, by index, or -1 for none. It survives the panel
// closing and opening -- the selection is a place in the file, not a piece
// of the panel's furniture, and coming back to a config you were working on
// should come back to where you were.
let picked = -1;

function icon(glyph, title, cls) {
  const b = document.createElement('button');
  b.textContent = glyph;
  b.title = title;
  b.className = cls;
  b.disabled = busy;
  return b;
}

// Strip one leading `#`, and the single space after it that a hand-written
// comment usually has -- but only when what follows is not itself indented,
// since the button writes its hash BEFORE the indent and eating a space
// there would shorten a line every time it was toggled.
//
// Only ONE hash: `##` is a comment someone wrote deliberately, and
// uncommenting it should give back `#`, not the line inside it.
function uncomment(text) {
  const at = text.indexOf('#');
  const head = text.slice(0, at);
  let rest = text.slice(at + 1);
  // A lone space right after the hash is comment spacing; two or more is the
  // line's own indentation showing through.
  if (rest.startsWith(' ') && !rest.startsWith('  ')) rest = rest.slice(1);
  else if (rest.startsWith('\t')) rest = rest.slice(1);
  return head + rest;
}

// Comment a line out, or bring it back. Shared by the row's `#` button and
// by alt+c, so the two cannot drift into meaning different things.
function toggleComment(at) {
  const text = lines[at];
  if (text === undefined) return;
  lines[at] = text.trim().startsWith('#') ? uncomment(text) : '#' + text;
  send('run', at);
}

function draw() {
  // A DELETE CAN LEAVE THE SELECTION PAST THE END. Clamp before drawing, so
  // the picked row is always one that exists and the next j moves from where
  // the selection visibly is.
  if (picked >= lines.length) picked = lines.length - 1;
  if (!lines.length) picked = -1;
  rows.replaceChildren();
  lines.forEach((text, i) => {
    const row = document.createElement('div');
    const commented = text.trim().startsWith('#');
    row.className = 'row' + (commented ? ' comment' : '')
                          + (i === picked ? ' picked' : '');

    // Only the handle starts a drag, not the whole row -- otherwise text
    // selection inside the input would be impossible. Pointer events rather
    // than HTML5 drag-and-drop: native DnD gives a ghost image you cannot
    // style and no way to animate the rows getting out of the way.
    const hold = document.createElement('span');
    hold.className = 'hold';
    hold.textContent = '⋮⋮';
    hold.title = 'drag to reorder  (alt+h and alt+l carry the selected line)';

    const box = document.createElement('input');
    box.value = text;
    box.spellcheck = false;
    box.disabled = busy;
    // Typing edits the array; nothing reaches disk until a button says so, so
    // a half-typed form never gets evaluated.
    box.oninput = () => { lines[i] = box.value; };
    // A DEAD KEY THAT GOT PAST THE CHORD. Capture-phase preventDefault stops
    // macOS arming the tilde on alt+n, but an accent already pending when
    // alt went down would still land here. Nothing typed while alt is held
    // belongs in a config line, so it is refused rather than inserted.
    box.addEventListener('beforeinput', (e) => {
      if (altDown) e.preventDefault();
    });
    // Clicking into a line is choosing it. The class is set directly rather
    // than by redrawing, because a redraw would replace the input the click
    // just put the caret in.
    box.onfocus = () => { pick(i, false); };
    box.onkeydown = (e) => {
      if (e.key === 'Enter') { e.preventDefault(); send('run', i); }
    };

    // No run button: every action re-runs the whole file anyway, so a
    // per-line one promised a granularity that never existed. Enter in the
    // field is what commits a typed edit.
    //
    // Commenting is a TEXT EDIT, not an action of its own: the button writes
    // the line the way you would have typed it and sends the file. That is
    // why the server knows nothing about it -- there is nothing to know.
    // The tooltip names the chord that does the same thing. ON THE SELECTED
    // LINE, which is worth spelling out: a button acts on its own row, and
    // the chord acts on whichever row is picked -- usually but not always
    // the same one.
    const up = icon('↑', `insert a line above  (alt+N on the selected line)`, 'up');
    up.onclick = () => send('insert-above', i);
    const down = icon('↓', `insert a line below  (alt+n on the selected line)`, 'down');
    down.onclick = () => send('insert-below', i);
    const hash = icon('#',
      (commented ? 'uncomment this line' : 'comment this line out')
        + '  (alt+c on the selected line)', 'hash');
    hash.onclick = () => toggleComment(i);
    const del = icon('✕', 'delete this line  (alt+d on the selected line)', 'del');
    del.onclick = () => send('delete', i);

    row.append(box, up, down, hash, del, hold);

    // The line and anything wrong with it travel together, so the message sits
    // directly beneath the input that caused it.
    const slot = document.createElement('div');
    slot.className = 'slot';
    slot.appendChild(row);
    slot.dataset.at = i;
    if (!busy) hold.onpointerdown = (e) => lift(e, i, slot);

    if (faults[i]) {
      row.classList.add('bad');
      const why = document.createElement('div');
      why.className = 'why';
      why.textContent = faults[i];
      slot.appendChild(why);
    }
    rows.appendChild(slot);
  });

  // AN EMPTY FILE STILL NEEDS A WAY IN. With no rows there is no row to
  // insert from, so deleting the last line would leave a panel you could
  // never add to again.
  if (!lines.length) {
    const row = document.createElement('div');
    row.className = 'row';
    const add = icon('+', 'add the first line', 'up');
    add.onclick = () => send('insert-below', -1);
    row.append(add);
    rows.appendChild(row);
  }
}

// Pick a row up and carry it. A clone follows the pointer while the real row
// collapses to a gap, and the gap moves between the other rows as you go -- so
// the list shows you the result before you commit to it.
function lift(down, at, slot) {
  if (busy) return;
  down.preventDefault();

  const box = slot.getBoundingClientRect();
  const grabbedAt = down.clientY - box.top;

  const ghost = slot.cloneNode(true);
  ghost.className = 'slot ghost';
  ghost.style.width = box.width + 'px';
  ghost.style.left = box.left + 'px';
  ghost.style.top = box.top + 'px';
  document.body.appendChild(ghost);

  // The original stays in the flow as an empty space of the same height, so
  // nothing below it jumps at the moment of pickup.
  slot.classList.add('gap');
  slot.style.height = box.height + 'px';

  const others = [...rows.querySelectorAll('.slot')].filter(s => s !== slot);
  others.forEach(s => s.classList.add('sliding'));
  document.body.classList.add('carrying');
  let to = at;

  // Measured once, before anything moves. Reading positions mid-drag would
  // feed back on itself: the rows have already slid out of the way, so the
  // next reading is against geometry this drag caused.
  const anchors = others.map(s => {
    const r = s.getBoundingClientRect();
    return { at: Number(s.dataset.at), middle: r.top + r.height / 2 };
  });
  const height = box.height;

  const follow = (m) => {
    ghost.style.top = (m.clientY - grabbedAt) + 'px';
    // Land above the first row whose (original) middle the pointer is past.
    const over = anchors.find(a => m.clientY < a.middle);
    to = over ? (over.at > at ? over.at - 1 : over.at) : lines.length - 1;
    to = Math.max(0, Math.min(lines.length - 1, to));
    // Slide the others around the hole, by transform rather than by moving
    // anything -- the DOM stays put, so the measurements above stay true.
    for (const s of others) {
      const j = Number(s.dataset.at);
      const shifted = (j > at && j <= to) ? -height
                    : (j < at && j >= to) ? height : 0;
      s.style.transform = shifted ? `translateY(${shifted}px)` : '';
    }
  };

  const drop = () => {
    removeEventListener('pointermove', follow);
    removeEventListener('pointerup', drop);
    removeEventListener('pointercancel', drop);
    document.body.classList.remove('carrying');
    // Settle: fly the ghost to where the row will actually end up. The gap has
    // not moved -- the others slid around it -- so the resting place is the
    // original spot offset by however far the row travelled.
    const rest = slot.getBoundingClientRect();
    ghost.classList.add('landing');
    ghost.style.top = (rest.top + (to - at) * height) + 'px';
    ghost.style.left = rest.left + 'px';
    let settled = false;
    const finish = () => {
      // Both the transition and the fallback timer call this; first wins.
      if (settled) return;
      settled = true;
      ghost.remove();
      slot.classList.remove('gap');
      slot.style.height = '';
      others.forEach(s => { s.classList.remove('sliding'); s.style.transform = ''; });
      if (to !== at) move(at, to);
      else draw();
    };
    ghost.addEventListener('transitionend', finish, { once: true });
    // transitionend never fires if the ghost was already exactly in place.
    setTimeout(finish, 200);
  };

  addEventListener('pointermove', follow);
  addEventListener('pointerup', drop);
  addEventListener('pointercancel', drop);
}

// Reordering is done here rather than server-side: the client already knows
// both indices, and it sends the reordered lines like every other action does.
function move(at, to) {
  const moved = lines.slice();
  moved.splice(to, 0, moved.splice(at, 1)[0]);
  lines = moved;
  // THE SELECTION FOLLOWS THE LINE, not the slot. It is a place in the file,
  // and dragging a row does not change which line you were working on --
  // whether you dragged that row itself or one that slid past it.
  picked = afterMove(picked, at, to);
  // Order changes what the file does -- a group's colour claimed earlier, or a
  // (hide) reaching a file before the (group) that would have boxed it -- so
  // this redraws.
  send('reorder', -1);
}

// Where index `i` ends up when the line at `at` is taken out and put back in
// at `to`. Three cases, and the first is the one worth naming: the dragged
// line lands where it was dropped, and everything between the two positions
// shifts one place to fill the gap it left or make the one it needs.
function afterMove(i, at, to) {
  if (i < 0) return i;
  if (i === at) return to;
  if (at < i && i <= to) return i - 1;
  if (to <= i && i < at) return i + 1;
  return i;
}

// One shape for every button: what to do, and which line to do it to. The
// server edits the file, re-runs it, and returns both the new lines and the new
// graph -- so the page never has to guess what the file now says.
// `keepView` marks the WATCHER'S redraw: it means "the source moved, draw it
// again, and do not yank the view someone chose". It is also the one call
// that needs a picture back -- an edit made from this page saves and stops,
// and the watcher notices the write and asks for the drawing. One redraw
// path instead of two, so a config edit and a source edit arrive the same
// way.
async function send(action, index, keepView) {
  if (busy) return;
  busy = true;
  draw();
  // AN EDIT SAVES; ONLY THE WATCHER'S REDRAW DRAWS. Saying "drawing" for an
  // edit would promise a picture this request is not going to bring back --
  // the watcher notices the write and asks for it a moment later.
  status.textContent = keepView ? 'drawing...' : 'saving...';
  const t0 = performance.now();
  try {
    // The token goes in the query, which is where the server looks for it
    // (see the `k` check in core.janet). Without it every write is a 403 --
    // which is exactly what the panel's buttons were getting.
    const r = await fetch(`/config?k=${encodeURIComponent(window.TOKEN)}`, {
      method: 'POST',
      // `draw` is what asks for an SVG. Only the watcher's own redraw sets
      // it; an edit saves and waits to be told, like every other change to
      // a file in the tree.
      body: JSON.stringify({ action, index, lines, draw: !!keepView }),
    });
    const out = await r.json();
    // No `lines` back means the request never got as far as editing the file --
    // a bad action or a crash. Nothing per-line to show.
    if (!out.lines) {
      problems.textContent = out.error || 'request failed';
      status.textContent = 'error';
    } else {
      lines = out.lines;
      // Keys arrive as strings through JSON; the rows are indexed by number.
      faults = {};
      for (const [at, why] of Object.entries(out.problems || {})) {
        faults[Number(at)] = why;
      }
      problems.textContent = out.error || '';
      if (out.svg) {
        // innerHTML replaces the label element too, so put it back before
        // anything tries to show it. hover.js owns that element and hands it
        // back -- reaching for it by name from here is what threw
        // "edgelabel is not defined" on every redraw that carried an SVG,
        // which meant one config action broke the page.
        hideEdge();
        pane.innerHTML = out.svg;
        keepEdgeLabel();
        wireEdges();
        // The stripes on a folded node, which the SVG cannot carry itself.
        hatchFolded();
        // The arrow was drawn into the svg that just went. Re-find against
        // the new one, so a hit survives a redraw rather than leaving the
        // bar claiming a match that is no longer marked.
        forgetUnit();
        redrawFind();
        // A different set of files is a different shape, so start it framed
        // rather than under the previous view's pan -- EXCEPT when the
        // watcher redrew after an edit on disk AND the view is one someone
        // chose. Nobody asked for that redraw, and yanking the view away
        // from what they were looking at is the cost of a feature meant to
        // be invisible. `touched` already means exactly this: it is what
        // stops an automatic refit from discarding a chosen view.
        // `repaint`, not `paint`: this runs on a freshly swapped-in SVG that
        // has no transform yet, and deferring it a frame would show the
        // graph unpositioned for that frame.
        if (keepView && isTouched()) repaint(); else fit();
      }
      const count = Object.keys(faults).length;
      const ms = Math.round(performance.now() - t0);
      // SAY WHAT HAPPENED, which for an edit is a save and nothing else --
      // the drawing comes back on the watcher's own tick a moment later, and
      // claiming to have drawn here would be claiming the picture on screen
      // is already the new one.
      status.textContent = count
        ? `saved, ${count} line${count > 1 ? 's' : ''} failed`
        : out.svg ? `drawn in ${ms}ms` : 'saved';
    }
  } catch (e) {
    problems.textContent = e.message;
    status.textContent = 'error';
  } finally {
    busy = false;
    draw();
  }
}

// -- help ------------------------------------------------------------------
//
// The verb list is NOT written here. It arrives as window.CONFIG_DOCS, built
// by config/docs from the same table the PEG's alternatives are generated
// from, so a verb cannot exist without appearing here and cannot appear here
// without existing. Adding one to that table is the whole job.

const help = document.getElementById('help');
const helpOpen = document.getElementById('help-open');

function renderHelp() {
  const verbs = window.CONFIG_DOCS || [];
  const into = document.getElementById('help-verbs');
  for (const verb of verbs) {
    const row = document.createElement('div');
    row.className = 'help-verb';

    const usage = document.createElement('code');
    usage.className = 'help-usage';
    usage.textContent = verb.usage;
    row.appendChild(usage);

    const blurb = document.createElement('p');
    blurb.textContent = verb.blurb;
    row.appendChild(blurb);

    into.appendChild(row);
  }
}

// What had focus before the dialog opened, so closing puts it back.
let helpCloseTarget = null;

function openHelp() {
  // The bar is not left open behind the dim: opening the help is a move away
  // from writing a line, the same as clicking off it.
  if (composing()) shutCompose();
  help.classList.remove('shut');
  helpCloseTarget = document.activeElement;
  help.focus();
}

function shutHelp() {
  help.classList.add('shut');
  if (helpCloseTarget && helpCloseTarget.focus) helpCloseTarget.focus();
  helpCloseTarget = null;
}

helpOpen.addEventListener('click', openHelp);
// The dim IS the dismiss target, but a click inside the card is not a click
// on the backdrop -- so only the backdrop itself closes.
help.addEventListener('click', (e) => { if (e.target === help) shutHelp(); });
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && !help.classList.contains('shut')) {
    shutHelp();
    return;
  }
  // `?` OPENS THE HELP, and F1 with it. A question mark is a printable
  // character, so it is also a keystroke that could start a config line --
  // but no verb begins with one, and the mark in the corner is a `?`, so
  // pressing it is the obvious thing to try. Once the bar IS open it is
  // text like any other character: the compose handler below runs only
  // while composing, this one only while not.
  if (composing()) return;
  if (e.key === '?' || e.key === 'F1') {
    e.preventDefault();
    // The same key closes it. Reading about the verbs and then pressing the
    // key that got you there should not leave you where you already are.
    if (help.classList.contains('shut')) openHelp(); else shutHelp();
  }
});

renderHelp();

// -- compose ---------------------------------------------------------------
//
// TYPE ANYWHERE. There is no field to click into first: a printable keystroke
// on the page opens a bar at the bottom and goes into it, and Enter appends
// what you wrote to the config as a new line. The parentheses are added on
// the way to the file, because every line of the config is a call and typing
// them is a keystroke that could only ever be one thing.

const compose = document.getElementById('compose');
const composeInput = document.getElementById('compose-input');
const composeFault = document.getElementById('compose-fault');

function composing() { return !compose.classList.contains('shut'); }

const composeList = document.getElementById('compose-list');

// -- completions -----------------------------------------------------------
//
// WHAT THERE IS TO COMPLETE is two things, and which one depends on where the
// caret is: the first word of a line is a verb, and everything after it is a
// prefix. Both are already on the page -- the verbs as window.CONFIG_DOCS,
// the prefixes as the titles of the nodes currently drawn -- so none of this
// asks the server anything.

// Every dotted prefix of a name, so a node called `src.visualize.color`
// offers `src` and `src.visualize` as well as itself. THE DERIVED ONES ARE
// THE POINT: a leaf file is rarely what you box or hide, and typing `src`
// should suggest the directory above the file rather than only the file.
function prefixesOf(name) {
  const parts = name.split('.');
  const out = [];
  for (let i = 1; i <= parts.length; i++) out.push(parts.slice(0, i).join('.'));
  return out;
}

// What `(prefix ~ src.visualize)` lines bind, read off the config the page
// is already showing: [name, what it stands for].
function bindings() {
  const out = [];
  for (const line of lines) {
    // Every form on the line, since a line may hold several.
    for (const form of (line || '').match(/\([^)]*\)/g) || []) {
      const m = /^\(\s*prefix\s+(\S+)\s+(\S+?)\s*\)$/.exec(form);
      if (m) out.push([m[1], m[2]]);
    }
  }
  return out;
}

function prefixCandidates() {
  const svg = pane.querySelector('svg');
  const names = [];
  if (svg) {
    for (const node of svg.querySelectorAll('g.node')) {
      const title = node.querySelector('title');
      if (title) names.push(title.textContent.trim());
    }
  }
  const seen = new Set();
  for (const name of names) for (const p of prefixesOf(name)) seen.add(p);

  // A BOUND NAME IS A PREFIX TOO, and so is anything under it: `~` bound to
  // src.visualize offers `~` and `~.color`, because those are the spellings
  // the config is written in once the binding exists.
  for (const [alias, stands] of bindings()) {
    seen.add(alias);
    for (const p of seen.size ? [...seen] : []) {
      if (p === stands) continue;
      if (p.startsWith(stands + '.')) seen.add(alias + p.slice(stands.length));
    }
  }
  return [...seen];
}

// Ranked: a match at the START beats one in the middle, and a shorter
// candidate beats a longer one. Shorter is a BROADER selection and usually
// what was meant -- `src.visualize` before `src.visualize.parsers.javascript`.
function rank(candidates, typed) {
  const q = typed.toLowerCase();
  const hits = [];
  for (const c of candidates) {
    const at = c.toLowerCase().indexOf(q);
    if (at < 0) continue;
    hits.push({ text: c, at, len: c.length });
  }
  hits.sort((a, b) => (a.at - b.at) || (a.len - b.len) || a.text.localeCompare(b.text));
  return hits.map(h => h.text);
}

// The word the caret sits in, and which slot of the line it occupies.
function wordAtCaret() {
  const text = composeInput.value;
  const caret = composeInput.selectionStart ?? text.length;
  const before = text.slice(0, caret);
  const start = before.lastIndexOf(' ') + 1;
  // How many words precede this one: 0 is the verb, 1 is its first argument.
  const slot = before.slice(0, start).split(/\s+/).filter(Boolean).length;
  return { word: before.slice(start), start, end: caret, slot };
}

// WHAT GOES IN THIS SLOT, asked of the verb rather than assumed. The config
// module publishes each verb's argument kinds -- `box` is ["name", "color?"]
// -- so a second argument to `box` completes colours while a second argument
// to `hide` completes nothing, because `hide` does not take one.
//
// Nothing here knows which verb has a colour: change the table in
// config.janet and this follows.
function poolFor(slot) {
  const text = composeInput.value;
  const verb = text.trimStart().split(/\s+/)[0] || '';
  if (slot === 0) return (window.CONFIG_DOCS || []).map(d => d.name);

  const spec = (window.CONFIG_DOCS || []).find(d => d.name === verb);
  if (!spec) return [];
  // `?` marks an optional argument and is not part of the kind.
  const kind = (spec.args || [])[slot - 1];
  if (!kind) return [];              // the verb takes no argument here
  switch (kind.replace(/\?$/, '')) {
    case 'color': return window.CONFIG_COLOURS || [];
    // A bound name and a prefix are both prefixes as far as completing goes;
    // `prefix`'s first argument is a name you are inventing, so nothing is
    // offered for it.
    case 'name': return prefixCandidates();
    default: return [];
  }
}

function completions() {
  const { word, slot } = wordAtCaret();
  return rank(poolFor(slot), word);
}


// The field is as wide as its text, so the closing paren sits just after
// what you wrote rather than at the far edge of the box. Width in `ch`
// rather than the `size` attribute, because `size` is a hint the flex
// layout can overrule -- and it did, letting a long line push the closing
// paren out through the border.
// WHICH BAR THIS IS. One box, two jobs: on the config tab it writes a line
// of the config language, on a terminal tab it types at a shell. The
// selected tab decides, so the bar is about whatever you are working in.
function composeTarget() {
  const p = pickedPanel();
  return (p && p !== configPanel && p.root.classList.contains('term')) ? p : null;
}

// HOW SMALL THE TEXT GETS. A shell command can be long, and a bar that only
// ever grows wider walks off the screen; letting the type shrink buys about
// twice the characters before that happens. 12px is the floor -- past that it
// stops being text you can check before sending.
const COMPOSE_MAX_PX = 17;
const COMPOSE_MIN_PX = 12;
const COMPOSE_ROWS = 7;
/* HOW WIDE THE BOX GETS, as a sheet of paper rather than as a count of
   characters.

   A4 IS 210mm AND A TYPESET MARGIN IS ABOUT 25mm A SIDE, which leaves 160mm
   -- a little over six inches -- of text. That is the measure books and
   letters have settled on because it is the width an eye reads a line at
   without losing the start of the next one, and it does not care what the
   line is made of.

   THE COUNT OF CHARACTERS WAS THE WRONG RULE. It was eighty-eight times the
   width of the widest glyph, so a box that never held a W was still sized
   for eighty-eight of them -- far wider than any line anyone types. A sheet
   of paper is the same width whatever is written on it, which is the point.

   96 CSS pixels to the inch, by definition, whatever the screen is doing. */
const COMPOSE_INCHES = 6.3;
const COMPOSE_CAP_PX = Math.round(COMPOSE_INCHES * 96);

// PUT THE BAR IN THE MODE ITS TAB WANTS. Called whenever the selection
// changes, and on opening. Cheap enough to call when nothing has changed:
// the class toggles are no-ops and the sizing is a couple of measurements.
function refitCompose() {
  if (!compose.isConnected || compose.classList.contains('shut')) return;
  compose.classList.toggle('typing', !!composeTarget());
  // THE LIST BELONGS TO THE CONFIG. Switching to a terminal has to take it
  // down rather than leave a stale set of verbs hanging over a shell.
  renderList();
  sizeCompose();
}

function sizeCompose() { sizeFor(composeInput.value); }

// WHAT THE FIELD WOULD BE after this input event, or null when that cannot
// be worked out. Insertions and deletions cover everything the bar sees;
// anything stranger (a drop, a composition) falls through to the `input`
// handler, which is a frame late but always right.
function nextValue(e) {
  const v = composeInput.value;
  const a = composeInput.selectionStart, b = composeInput.selectionEnd;
  if (a === null || b === null) return null;
  switch (e.inputType) {
    case 'insertText':
    case 'insertFromPaste':
    case 'insertReplacementText':
      return v.slice(0, a) + (e.data ?? '') + v.slice(b);
    case 'insertLineBreak':
    case 'insertParagraph':
      return v.slice(0, a) + '\n' + v.slice(b);
    case 'deleteContentBackward':
      return a === b ? v.slice(0, Math.max(0, a - 1)) + v.slice(b) : v.slice(0, a) + v.slice(b);
    case 'deleteContentForward':
      return a === b ? v.slice(0, a) + v.slice(b + 1) : v.slice(0, a) + v.slice(b);
    case 'deleteByCut':
    case 'deleteWordBackward':
    case 'deleteWordForward':
      return null;        // let `input` handle it; the shape is not obvious
    default:
      return null;
  }
}

function sizeFor(value) {
  const term = composeTarget();
  if (!term) {
    // THE CONFIG BAR IS ONE LINE, as wide as its text. The field is measured
    // in `ch` so the closing paren sits just after what you wrote.
    composeInput.style.font = '';
    composeInput.style.width = Math.max(1, value.length) + 'ch';
    composeInput.style.height = '';
    composeInput.rows = 1;
    return;
  }

  // A TERMINAL BAR GROWS BOTH WAYS, in that order and only that order.
  //
  // THE BOX IS 88 CHARACTERS OF 12px WIDE, and that is the whole budget. The
  // type shrinks ONLY WHILE THE TEXT IS ON ONE LINE: a first line that keeps
  // growing is a first line that keeps needing more room, so it buys that
  // room by getting smaller until it is as small as it goes. Past that the
  // box is full, and anything more wraps -- so by the time there is a second
  // line the type is ALREADY at 12px and never changes again. Nothing shrinks
  // while you are typing line four; it cannot, it is at the floor.
  const lines = value.split('\n');
  const longest = Math.max(1, ...lines.map(l => l.length));

  // How wide a character is on average, at a given size, in this face. Used
  // to guess how many characters a line holds -- a guess is all it has to be
  // now that the WIDTH is a fixed measure rather than a count.
  const em = charWidth();
  const capPx = Math.min(COMPOSE_CAP_PX, Math.round(innerWidth * 0.94));

  // WHAT SIZE FITS THIS LINE. At the full size a line of `longest` wants
  // `longest * MAX * em` pixels; if that is over budget, the size that fits
  // is the budget divided by the characters -- floored at 12, which is where
  // the box stops giving and the text starts wrapping instead.
  // MORE THAN ONE LINE MEANS 12px, whatever the lines say. Deriving the size
  // from the longest line let three SHORT lines sit at 17px -- true to the
  // arithmetic and not to the rule, which is that the small type is what
  // buys the first line its room, and once a second line exists that room
  // has already been spent.
  const wanted = longest * COMPOSE_MAX_PX * em;
  const px = lines.length > 1 ? COMPOSE_MIN_PX
    : wanted > capPx
      ? Math.max(COMPOSE_MIN_PX,
                 Math.min(COMPOSE_MAX_PX, Math.floor(capPx / (longest * em))))
      : COMPOSE_MAX_PX;

  // HOW MANY LINES THAT MAKES, counted rather than measured. Measuring means
  // writing `height: auto`, reading scrollHeight and writing the height back
  // -- three layouts, the middle one of which the browser can paint, which
  // is the flash. At 12px the box holds a known number of characters, so
  // wrapping is arithmetic.
  const per = Math.max(1, Math.floor(capPx / (px * em)));
  const rows = Math.min(COMPOSE_ROWS,
                        lines.reduce((n, l) => n + Math.max(1, Math.ceil(l.length / per)), 0));

  const line = Math.round(px * 1.45);
  // THE PAGE'S FACE, set here because the SIZE is worked out here -- the
  // family has to come along with it or the shorthand drops back to the
  // stylesheet's and the two disagree about how wide a line is.
  composeInput.style.font =
    `${px}px/${line}px ` + getComputedStyle(document.body).fontFamily;
  // THE WIDTH ONLY EVER GROWS on the way out. Sized to the text at the
  // current size, each step DOWN in font makes the same text narrower in
  // pixels -- so the box sprang back a few tens of pixels at every step and
  // crept out again, three times over, which is a stutter under the hand
  // rather than a resize. Once the type has started shrinking the line is
  // as wide as the box goes, so it stays there.
  const width = px < COMPOSE_MAX_PX || rows > 1
    ? capPx
    : Math.min(capPx, Math.max(longest + 1, 24) * px * em);
  composeInput.style.width = Math.round(width) + 'px';
  composeInput.style.height = (rows * line) + 'px';
}

// HOW WIDE A CHARACTER IS ON AVERAGE, as a fraction of the font size.
//
// A GUESS, AND ONLY A GUESS. It used to carry a promise -- eighty-eight
// characters fit -- which is why it measured the WIDEST glyph, and why a box
// that never held a W was sized as though it might. The width is a fixed
// measure now (see COMPOSE_CAP_PX), so all this has to do is estimate how
// many characters a line holds before it wraps, and being a little out either
// way costs a row of guessing rather than a broken promise.
//
// MEASURED ON ORDINARY TEXT, so the estimate is right for what people type
// rather than for the worst thing they could. Cached: it is a property of the
// font, and the font does not change.
let charEm = 0;
function charWidth() {
  if (charEm) return charEm;
  const probe = document.createElement('span');
  probe.style.cssText =
    'position:absolute;visibility:hidden;white-space:pre;font:100px/1 ' +
    getComputedStyle(document.body).fontFamily;
  // A pangram rather than a repeated letter: it has the letter frequencies of
  // real writing, which is what the average is meant to describe.
  const sample = 'the quick brown fox jumps over the lazy dog 0123456789';
  probe.textContent = sample;
  document.body.appendChild(probe);
  charEm = probe.getBoundingClientRect().width / sample.length / 100;
  probe.remove();
  return charEm || 0.5;
}

// -- the list --------------------------------------------------------------

// Which row is highlighted, or -1 for none. -1 is the state on opening and
// after every keystroke: typing narrows the list rather than moving in it,
// and Tab takes the top match precisely because nothing is selected yet.
let listAt = -1;
let listItems = [];

function renderList() {
  // NO COMPLETIONS ON A TERMINAL TAB. The list offers node names and config
  // verbs, which is the wrong vocabulary entirely for a shell -- and the
  // shell has its own completion, on the key it expects.
  listItems = (composing() && !composeTarget()) ? completions() : [];
  renderRows();
}

// Draw the rows as they stand, without asking what matches again.
function renderRows() {
  composeList.replaceChildren();
  if (!listItems.length) {
    compose.classList.remove('listing');
    listAt = -1;
    return;
  }
  compose.classList.add('listing');
  listItems.forEach((text, i) => {
    const li = document.createElement('li');
    li.textContent = text;
    li.setAttribute('role', 'option');
    li.setAttribute('aria-selected', String(i === listAt));
    if (i === listAt) li.className = 'at';
    // Clicking takes it, which is the same as moving onto it.
    li.addEventListener('mousedown', (e) => {
      e.preventDefault();          // keep the caret in the field
      takeCompletion(i);
    });
    composeList.appendChild(li);
  });
  // Keep the highlighted row in view; the list shows five at a time.
  if (listAt >= 0) composeList.children[listAt]?.scrollIntoView({ block: 'nearest' });
}

// Write a candidate into the field, replacing the word the caret is in.
// MOVING SELECTS: ctrl-n and ctrl-p put the text in as they go, so there is
// nothing left to accept afterwards.
function takeCompletion(i) {
  const text = listItems[i];
  if (text === undefined) return;
  const { start, end } = wordAtCaret();
  const value = composeInput.value;
  composeInput.value = value.slice(0, start) + text + value.slice(end);
  const caret = start + text.length;
  composeInput.setSelectionRange(caret, caret);
  listAt = i;
  sizeCompose();
}

function moveList(step) {
  if (!listItems.length) return;
  // WRAPS, like the line movement: past the end is the top.
  //
  // From NOTHING selected, down goes to the first row and up to the last --
  // `listAt` is -1 there, and letting the arithmetic run would put up on the
  // second-to-last, which is a row nobody asked for.
  if (listAt < 0) listAt = step > 0 ? 0 : listItems.length - 1;
  else listAt = ((listAt + step) % listItems.length + listItems.length) % listItems.length;
  takeCompletion(listAt);
  // THE LIST DOES NOT RE-RANK WHILE YOU WALK IT. Taking a candidate writes it
  // into the field, and re-filtering against that text would reorder the rows
  // under the cursor -- one ctrl-p landing somewhere unrelated to where one
  // ctrl-n came from. Typing rebuilds the list; moving only moves in it.
  renderRows();
}

function shutList() {
  listItems = [];
  listAt = -1;
  composeList.replaceChildren();
  compose.classList.remove('listing');
}

function openCompose(seed) {
  compose.classList.remove('shut');
  compose.classList.toggle('typing', !!composeTarget());
  composeFault.textContent = '';
  composeInput.value = seed || '';
  sizeCompose();
  composeInput.focus();
  listAt = -1;
  renderList();
  // Caret after the seeded character rather than before it.
  const end = composeInput.value.length;
  composeInput.setSelectionRange(end, end);
}

function shutCompose() {
  compose.classList.add('shut');
  composeInput.value = '';
  composeFault.textContent = '';
  shutList();
  composeInput.blur();
}

// Ask the server whether these lines parse, without writing them. Returns
// the complaint about `at`, or nothing.
async function checkLines(candidate, at) {
  try {
    const r = await fetch(`/config?k=${encodeURIComponent(window.TOKEN)}`, {
      method: 'POST',
      body: JSON.stringify({ action: 'check', index: -1, lines: candidate }),
    });
    const out = await r.json();
    return (out.problems || {})[String(at)] || '';
  } catch (_) {
    // Unreachable server is not a parse error. Let the commit go and fail
    // the way any other request would.
    return '';
  }
}

async function commitCompose() {
  // TO THE TERMINAL, if that is what is selected: what you typed is typed at
  // the shell, with the newline that runs it. The bar goes away afterwards,
  // the same as it does when a config line is committed -- sending is
  // finishing, and typing anywhere brings it straight back.
  const term = composeTarget();
  if (term) {
    const typed = composeInput.value;
    if (!typed) { shutCompose(); return; }
    // CARRIAGE RETURN, WHICH IS WHAT THE ENTER KEY IS. A shell in cooked
    // mode cannot tell \r from \n -- the line discipline translates one to
    // the other on input -- so sending \n worked and looked correct. A
    // full-screen program reading keys in RAW MODE gets no such translation
    // and the two are different keys: \r is Enter, \n is ctrl-J, which a
    // readline-style box takes as "put a line break in what I am writing".
    // That is why typing into Claude Code here grew the message instead of
    // sending it.
    //
    // Interior newlines get the same treatment, since a multi-line paste is
    // several Enters as far as the program is concerned.
    // THE TEXT, THEN THE RETURN, as two separate writes.
    //
    // A whole line arriving in ONE write is indistinguishable from a paste,
    // and a program that has turned bracketed paste on (mode 2004 -- claude
    // does) treats a run of bytes that way: the return inside it becomes a
    // line break in the message being composed rather than the key that
    // sends it. Which is the bug -- typing into Claude Code here grew the
    // message instead of submitting it.
    //
    // Split, the return arrives on its own, after the text has landed, and
    // reads as a keystroke. \r rather than \n because that is what the Enter
    // key is: a shell in cooked mode cannot tell them apart, but a raw-mode
    // reader takes \n as ctrl-J, which a readline-style box inserts.
    if (term.type) {
      const body = typed.replace(/\r\n|\n/g, '\r');
      if (body) term.type(body);
      term.type('\r');
    }
    shutCompose();
    return;
  }

  const text = composeInput.value.trim();
  if (!text) { shutCompose(); return; }
  if (busy) return;
  // What you typed goes in as a call, ONTO THE SELECTED LINE -- a line holds
  // as many forms as you like and the parser runs each in turn, so appending
  // is how you build a line up a piece at a time. The selection does not
  // move: you are still working on the same line, now longer.
  //
  // With no selection it goes at the end as a line of its own.
  const call = `(${text})`;
  const at = picked >= 0 && picked < lines.length ? picked : lines.length;
  const base = (lines[at] ?? '').trim();
  const merged = base ? `${base} ${call}` : call;
  const candidate = lines.slice(0, at).concat([merged], lines.slice(at + 1));

  // A REFUSED LINE NEVER REACHES THE FILE. The bar asks first and only sends
  // what parses, so a typo stays in the bar rather than being written and
  // then complained about -- the config on disk holds only lines that ran.
  //
  // Which also means there is no half-written form to mend on a retry: the
  // line under the caret is the whole attempt, every time.
  composeFault.textContent = '';
  const why = await checkLines(candidate, at);
  if (why) {
    composeFault.textContent = why;
    composeInput.focus();
    composeInput.setSelectionRange(text.length, text.length);
    return;
  }

  lines = candidate;
  picked = at;
  await send('run', -1);
  shutCompose();
}

// WHETHER THE MOUSE IS IN PLAY. A pointer that has not moved since you
// started typing is one the OS has probably hidden, and a row lit under it
// says something false about what is selected. Hover styling is granted on a
// real move and withdrawn on the next key.
compose.addEventListener('mousemove', () => compose.classList.add('mousing'));
composeInput.addEventListener('keydown', () => compose.classList.remove('mousing'));

// SIZED BEFORE THE CHARACTER LANDS. `input` fires after the value has
// changed AND after the browser has laid the field out at its old size, so
// resizing there is always one frame behind what you typed -- most visible
// on a newline, where the line arrives in a box that has not grown yet.
// `beforeinput` knows what the value is about to be, so the box is already
// the right size when the text appears in it.
composeInput.addEventListener('beforeinput', (e) => {
  if (!composeTarget()) return;
  const next = nextValue(e);
  if (next === null) return;
  sizeFor(next);
});

composeInput.addEventListener('input', () => {
  sizeCompose();
  // Typing NARROWS rather than moves: the highlight goes back to nothing, so
  // Tab means "the best match for what I have now" however far down the list
  // ctrl-n had wandered.
  listAt = -1;
  renderList();
});

// The caret moving changes which word is being completed, so the list
// follows it -- `(box src` and `(box src.web ` want different things.
for (const ev of ['click', 'keyup']) {
  composeInput.addEventListener(ev, (e) => {
    // Only the horizontal ones: up and down walk the LIST now, and resetting
    // the highlight on their keyup would undo the move as it was made.
    if (e.type === 'keyup' && !['ArrowLeft','ArrowRight','Home','End'].includes(e.key)) return;
    listAt = -1;
    renderList();
  });
}

composeInput.addEventListener('keydown', (e) => {
  // CTRL-N AND CTRL-P WALK THE LIST, and only while there is one -- the
  // browser keeps them for new-window and print when the bar has nothing to
  // offer, rather than losing them to a feature that is not doing anything.
  if (e.ctrlKey && (e.key === 'n' || e.key === 'p') && listItems.length) {
    e.preventDefault();
    moveList(e.key === 'n' ? 1 : -1);
    return;
  }
  // THE ARROWS AGREE WITH WHAT YOU SEE. The list reads top-down now, so down
  // is down: the same direction as the index, the eye, and ctrl-n.
  if ((e.key === 'ArrowDown' || e.key === 'ArrowUp') && listItems.length) {
    e.preventDefault();
    moveList(e.key === 'ArrowDown' ? 1 : -1);
    return;
  }
  if (e.key === 'Tab' && listItems.length) {
    // The top match, since nothing is selected until ctrl-n moves. Moving
    // already wrote its choice into the field, so Tab has nothing to do
    // there and simply leaves it.
    e.preventDefault();
    if (listAt < 0) takeCompletion(0);
    renderList();
    return;
  }
  if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); commitCompose(); }
  // SHIFT-ENTER IS A NEWLINE, which is only meaningful on a terminal tab --
  // the config bar is one line and the browser's own default is prevented
  // above. Left to the textarea rather than inserted here, so undo and the
  // caret behave the way they do in any other multi-line field.
  //
  // The box is grown for it in `beforeinput`, which runs before the newline
  // lands -- a timer here cost a whole frame, and the line appeared in a box
  // that was still one line tall.
  else if (e.key === 'Enter' && e.shiftKey) {
    if (!composeTarget()) e.preventDefault();
  }
  else if (e.key === 'Escape') {
    e.preventDefault();
    // The list first, then the bar: an escape closes the thing that is in
    // the way before the thing you are working in.
    if (listItems.length) shutList(); else shutCompose();
  }
  // Backspacing past the start closes the bar, so an accidental keystroke is
  // undone by the same key that would undo a character.
  else if (e.key === 'Backspace' && composeInput.value === '') shutCompose();
});

// The page-level catch. A bare printable key with no modifier is text; keys
// with Meta or Ctrl are shortcuts and stay the browser's.
document.addEventListener('keydown', (e) => {
  if (composing()) return;
  if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') return;
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  if (!compose.isConnected) return;
  // A single printable character. Everything longer is a named key -- Tab,
  // ArrowLeft, F5 -- and none of those should start a line.
  if (e.key.length !== 1) return;
  if (e.key === ' ') return;
  // Already claimed. The help handler runs FIRST and calls preventDefault on
  // `?`, so without this the mark would open the help and then start a line
  // behind it. Checking the flag rather than repeating the key here keeps
  // one list of what is a shortcut.
  if (e.defaultPrevented) return;
  e.preventDefault();
  // TYPING LEAVES THE HELP. The panel is something you consulted, not a mode
  // you have to dismiss: reaching for a verb you just read about should put
  // you straight in the bar with the first letter already in it.
  if (!help.classList.contains('shut')) shutHelp();
  openCompose(e.key);
});

// -- alt -------------------------------------------------------------------
//
// TAP OPENS, HOLD PEEKS. Press and release Alt on its own and the config
// stays up; hold it and the config shows for as long as you hold, then goes
// when you let go. One key, and which one you meant is decided by what you
// did while it was down -- a tap is a hold you ended without doing anything.
//
// The hold is the interesting half: it is a peek that is about to become a
// chord, since the keys pressed WHILE Alt is down are where subsequent
// commands will attach. Nothing uses that yet; this is the shape it needs.

// Whether this Alt press has been used for anything -- another key arriving
// while Alt is down, which is what a chord is.
let altUsed = false;
// Whether the current press opened the panel, so a hold only puts away what
// it itself put up -- letting go over a config you had already opened should
// leave it alone.
let altOpened = false;
let altDown = false;
// When the press started. A HOLD IS A PRESS THAT LASTED, which is the only
// thing separating it from a tap when no chord was struck. A chord counts as
// a hold however brief it was.
let altAt = 0;
// Where the caret was when alt went down, so releasing puts it back. Moving
// the selection focuses a row, which pulls the caret out of whatever you
// were typing in -- and a modifier you held for a moment should not cost you
// your place in a half-written line.
let altCaret = null;
// The panel this press is driving -- read once on the way down, so a keyup
// puts away exactly what the keydown put up even if the selection moved.
let altPanel = null;
// The tab the WALK opened, which the walk is therefore responsible for
// shutting -- distinct from `altOpened`, which is about the press itself.
let altPeeked = null;
// Generous, because the cost is asymmetric: a slow tap misread as a hold
// puts away a panel you asked to keep, while a quick hold misread as a tap
// just leaves it up. Only the no-chord case depends on this at all.
const ALT_HOLD_MS = 400;

// Select a line, and optionally put the caret in it. `focus` is false when
// the selection came FROM a focus, so choosing a row does not fight the
// click that chose it.
function pick(at, focus = true) {
  if (!lines.length) { picked = -1; return; }
  // WRAPS. Past the end is the top and before the start is the bottom, which
  // is what makes j/k a way to cycle a short list rather than a way to get
  // stuck at one end.
  picked = ((at % lines.length) + lines.length) % lines.length;
  const slots = [...rows.children];
  slots.forEach((slot, i) => {
    slot.querySelector('.row')?.classList.toggle('picked', i === picked);
  });
  const box = slots[picked]?.querySelector('input');
  if (box) {
    // Into view, because a selection you cannot see is not a selection --
    // `nearest` so a pick that is already on screen does not jump the list.
    box.scrollIntoView({ block: 'nearest' });
    if (focus) box.focus();
  }
}

// j/k and the arrows, while alt is held. Alt is what makes them movement
// rather than text: without it, `j` is the first character of a config line.
function altChord(e) {
  // BY PHYSICAL KEY, not by `e.key`. macOS composes alt with a letter into a
  // character -- alt+j is `∆`, alt+k is `˚` -- so matching on `e.key` never
  // saw the letter at all and the chord silently did nothing. `e.code` is
  // the key that was pressed, whatever the OS decided it should type.
  const down = e.code === 'KeyJ' || e.code === 'ArrowDown';
  const up = e.code === 'KeyK' || e.code === 'ArrowUp';
  const del = e.code === 'KeyD';
  const comment = e.code === 'KeyC';
  // CARRY THE LINE, where j/k walk past it. h and l are vim's left and
  // right, and the arrows agree -- sideways for "take this with you", which
  // is the gesture a drag makes and reads as different from moving the
  // cursor even though both end up moving vertically.
  // h and l WALK THE TABS now, left and right along the row -- see altWalk.
  // They used to carry a config line up and down, which was the same gesture
  // aimed at the smaller of the two things alt can move; a row of tabs has
  // nowhere else to put that, and j/k still carry nothing but the selection.
  const walkLeft = e.code === 'KeyH' || e.code === 'ArrowLeft';
  const walkRight = e.code === 'KeyL' || e.code === 'ArrowRight';
  // SHIFT PICKS THE SIDE. alt+n opens a line under the selected one, alt+N
  // over it -- the same key, and which way is the shift, the way a capital
  // reads as the mirror of its letter.
  //
  // alt+n is macOS's DEAD KEY FOR TILDE: it arms a pending accent that lands
  // on whatever you press next, and with the caret in a row that accent goes
  // into the config. Matching by `e.code` already catches the keystroke --
  // `e.key` here is `Dead` -- and the preventDefault below is what stops the
  // accent being armed at all. See also the compositionstart guard.
  const fresh = e.code === 'KeyN';
  // A NEW TERMINAL. Enter rather than a letter because every letter worth
  // having is a config operation, and because `+` is what this does -- a key
  // that makes a thing rather than editing one.
  const newTab = e.code === 'Enter' || e.code === 'NumpadEnter';
  if (!down && !up && !del && !comment && !fresh && !walkLeft && !walkRight
      && !newTab) {
    return false;
  }
  e.preventDefault();
  // A NEW TAB IS NOT A CONFIG OPERATION either, so it goes before everything
  // below opens the config panel on its way to asking what line is picked.
  if (newTab) {
    openTerminal();
    return true;
  }
  // WALKING IS NOT A CONFIG OPERATION, so it happens before everything below
  // -- which opens the config panel, asks what line is picked, and would
  // otherwise pull the config up on its way to a terminal.
  if (walkLeft || walkRight) {
    altWalk(walkRight ? 1 : -1);
    return true;
  }
  // ACTIONS NEED SOMETHING TO ACT ON, and the check has to happen BEFORE
  // the panel opens: opening focuses a row, and focusing a row selects it,
  // so asking afterwards would find a selection the open had just invented
  // and delete a line nobody chose.
  const nothingPicked = picked < 0 || picked >= lines.length;

  // The panel has to be up to be working in it -- holding alt already put it
  // there, and this is the case where it was open beforehand.
  if (configPanel.shut) configPanel.open();

  if (down || up) {
    pick(picked < 0 ? (down ? 0 : -1) : picked + (down ? 1 : -1));
    return true;
  }

  // One request in flight at a time: `send` refuses while busy, and a held
  // key repeats fast enough to reach that.
  if (busy) return true;


  if (fresh) {
    // With nothing selected a new line goes at the end, which is where the
    // compose bar puts one too -- there is no line to be relative to, and
    // the end is the answer everything else gives.
    const at = nothingPicked ? lines.length : picked + (e.shiftKey ? 0 : 1);
    lines = lines.slice(0, at).concat([''], lines.slice(at));
    picked = at;
    send('run', at);
    return true;
  }

  if (nothingPicked) return true;
  if (del) send('delete', picked);
  else toggleComment(picked);
  return true;
}

// ON CAPTURE, so a chord is claimed before the focused row input sees it.
// This is what keeps alt+n out of the field: it is macOS's dead key for
// tilde, and by the time a keydown reaches an input on the bubble phase the
// accent is already armed and about to land in the line.
document.addEventListener('keydown', (e) => {
  if (e.key !== 'Alt') {
    // Any other key during the hold makes it a chord, not a tap.
    if (altDown) {
      altUsed = true;
      // A CLAIMED CHORD GOES NO FURTHER. preventDefault stops the browser
      // acting on the key; it does not stop the key REACHING anyone else,
      // and the terminal's own handler sends alt+letter to the pty as an
      // ESC-prefixed byte -- so walking the tabs from a focused terminal
      // typed an escape code into the shell on every step.
      if (altChord(e)) e.stopPropagation();
    }
    return;
  }
  // Auto-repeat while held: the press has already been handled.
  if (altDown) return;
  altDown = true;
  altUsed = false;
  altAt = performance.now();
  // The COMPOSE BAR only. A config row is not somewhere to return to: its
  // focus handler selects that row, so restoring into one would undo the
  // move you just made with j/k. The bar is outside the list and has no
  // such opinion.
  const el = document.activeElement;
  altCaret = (el === composeInput && typeof el.selectionStart === 'number')
    ? { el, start: el.selectionStart, end: el.selectionEnd }
    : null;
  // WHICHEVER TAB IS SELECTED. Alt is one gesture with one target, and the
  // target is the thing the row already says you are working in -- so there
  // is no second modifier to remember and no rule about which key opens
  // which panel. Held for the whole press, since the selection could move
  // under a chord and the keyup must put away exactly what the keydown put
  // up.
  altPanel = pickedPanel();
  altOpened = altPanel.shut;
  // Opening on the way DOWN, so a hold shows the panel for as long as it is
  // held. A tap over an open one closes it instead -- see the keyup, which
  // is where a tap is finally told from a hold.
  if (altOpened) altPanel.open();
}, true);

// WALKING THE ROW WHILE ALT IS HELD. Each step moves the selection one tab
// along and shows what it lands on, so holding alt and tapping l is a way to
// look through the tabs rather than to guess which is which from its name.
//
// WHAT IT OPENS, IT CLOSES. A tab that was already open stays open when you
// leave it -- you did not open it and it is not yours to put away. One that
// this opened is shut again the moment the walk moves on, and the last one
// is shut when alt comes up, unless the release is a tap on it. That is the
// same rule the plain hold already follows, applied per step.
function altWalk(by) {
  // SOMEWHERE TO GO. Two tabs in the row is the ordinary case, but ONE is
  // enough when the pane you are standing in is not in the row -- a window
  // pulled off to be snapped against an edge leaves a single tab behind, and
  // that tab is still somewhere the walk can take you. Counting the row
  // alone, the walk went dead exactly when a snapped window was selected.
  const off = rail.indexOf(pickedPanel()) < 0;
  if (rail.length < (off ? 1 : 2)) return;
  // Where we are now: the selected tab if it is on the rail.
  const here = rail.indexOf(pickedPanel());
  // THE ENDS ARE ENDS. Walking off the last tab used to land on the first,
  // which is a jump the length of the row for a keypress that asked for one
  // step -- and on a row too wide to see at once, a jump to somewhere you
  // were not looking. Held at the end instead: keep pressing and nothing
  // moves, which is what the end of a row should feel like.
  //
  // NOTHING ON THE RAIL IS SELECTED when the pane you are in has been pulled
  // off the row -- a window snapped to an edge, most often, since pulling it
  // off is how you snap one. There is no place in the row to be held at the
  // end of, so the walk ENTERS the row rather than moving within it: from
  // the left going right, from the right going left. Held at zero instead,
  // this did nothing at all, which is a walk that stops working the moment
  // you are standing in a snapped window.
  const to = here < 0
    ? (by > 0 ? 0 : rail.length - 1)
    : Math.max(0, Math.min(rail.length - 1, here + by));
  if (to === here) return;
  const next = rail[to];

  // PUT AWAY WHAT THIS PRESS PUT UP, before moving off it. That is either a
  // tab an earlier step of this walk opened, or the one the alt-down itself
  // opened -- both are this press's doing and neither should be left behind.
  const leaving = altPeeked || (altOpened ? altPanel : null);
  if (leaving && leaving !== next) {
    leaving.toggle();
    altPeeked = null;
    altOpened = false;
  }
  selectPane(next.root);
  // The panel the keyup will act on is the one we are on NOW.
  altPanel = next;
  if (next.shut) {
    next.open();
    altPeeked = next;
    // A tab opened by walking is not a tab the release should close as
    // though the press had opened it: the walk owns it, and the keyup asks
    // `altPeeked` rather than `altOpened`.
    altOpened = false;
  } else {
    altOpened = false;
  }
  // OPENING MOVED THE ROW, so the reveal `selectPane` already did was aimed
  // at where this tab used to be. Asked again now the packing has run.
  revealTab(next);
}

document.addEventListener('keyup', (e) => {
  if (e.key !== 'Alt') return;
  altDown = false;
  const held = altUsed || performance.now() - altAt >= ALT_HOLD_MS;
  // BACK TO WHERE YOU WERE TYPING -- AFTER the panel has settled. Putting a
  // peek away blurs whatever inside it held focus, so restoring first only
  // to have the close undo it was the bug this replaced. Only if the field
  // is still on the page: a redraw replaces the inputs.
  const caret = altCaret;
  altCaret = null;
  const restore = () => {
    if (!caret || !caret.el.isConnected) return;
    caret.el.focus();
    if (typeof caret.el.setSelectionRange === 'function') {
      caret.el.setSelectionRange(caret.start, caret.end);
    }
  };

  const target = altPanel || configPanel;
  altPanel = null;
  // A TAB THE WALK OPENED goes away with the release, whatever else this
  // press was. Walking is looking; stopping on something is not the same as
  // asking for it to stay.
  const peeked = altPeeked;
  altPeeked = null;
  if (peeked) {
    peeked.toggle();
    restore();
    return;
  }
  if (held) {
    // A HOLD IS A PEEK: it puts away what it put up, and leaves alone what
    // was already there.
    if (altOpened) target.toggle();
    restore();
    return;
  }
  // A TAP IS A TOGGLE. Pressing down already opened a shut panel, so that
  // half is done; tapping over one that was open is what closes it.
  if (!altOpened) target.toggle();
  restore();
});

window.addEventListener('blur', () => {
  if (altDown && altOpened && altPanel) altPanel.toggle();
  altPanel = null;
  altDown = false;
});

// THE CONFIG PANEL, built here because what goes in it is the editor's and
// where it sits is the rail's. Made before the lines are drawn so the row has
// its first tab from the start.
makeConfigPanel(panel, () => {
  // FOCUS THE SELECTED LINE, not the first one. Focusing an input selects it,
  // so opening on the first row was overwriting the selection every time the
  // panel came back -- the thing that was meant to persist was being
  // destroyed by the act of looking at it.
  const boxes = body.querySelectorAll('input');
  (boxes[picked >= 0 ? picked : 0])?.focus();
});

// What the windows need from the editor. Handed over rather than imported:
// the config panel is a panel, so importing both ways would be a circle.
wirePanes({
  refitCompose: () => refitCompose(),
});

lines = window.CONFIG_LINES || [];
for (const [at, why] of Object.entries(window.CONFIG_PROBLEMS || {})) {
  faults[Number(at)] = why;
}
draw();
// Open the panel unasked when the file has something wrong in it -- an error
// you cannot see is worse than one you did not ask about.
if (Object.keys(faults).length) requestAnimationFrame(() => bar.click());

// THE ROW, once the config panel exists and the editor has drawn. The first
// tab is that panel, so the rail cannot start itself.
startRail();

// And from here on the graph keeps up with the files by itself.
watchSource();

// THE FIND BAR'S DEPENDENCIES, wired last because everything named here has
// to exist first. It needs the editor's completion machinery and the help
// panel; the viewport calls back into it. Given rather than imported, so no
// two modules import each other.
wireFind({
  moduleNames,
  help,
  shutHelp,
  rank,
  prefixCandidates,
});
