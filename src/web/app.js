// The page: pan and zoom over the graph, and a line editor for the config.
//
// Vanilla, no build step, no framework. Two parts that barely talk to each
// other -- the viewport and the editor -- joined only by the panel furniture
// they share.

// -- the viewport ------------------------------------------------------------
// One transform on the <svg> element does the whole job. Not an iframe: the
// graph has to stay in this document for a redraw to swap it, and a same-origin
// frame would only add a postMessage hop. The graph is SVG, so it stays
// sharp at any scale.

import { makeTerminal, keyToBytes } from './term.js';

const pane = document.getElementById('graph');
const zoomLabel = document.getElementById('zoom');
let zoomFade = null;
const MIN = 0.1, MAX = 10;
// `touched` tracks whether the user has moved the view themselves; an automatic
// refit must never discard a view they chose.
let scale = 1, tx = 0, ty = 0, touched = false;

// ONE WRITE PER FRAME. A trackpad fires wheel and pointermove faster than the
// display refreshes, and every one of those used to write a transform and
// force the work that follows it -- several repaints per frame, all but the
// last thrown away.
//
// The state (tx, ty, scale) is updated eagerly, so a reader still sees the
// latest values; only the DOM write waits for the frame that will show it.
let painting = null;

function paint() {
  if (painting) return;
  painting = requestAnimationFrame(() => {
    painting = null;
    repaint();
  });
}

function repaint() {
  const svg = pane.querySelector('svg');
  if (!svg) return;
  svg.style.transform = `translate(${tx}px, ${ty}px) scale(${scale})`;
  // The arrow is built in screen pixels and un-scaled by the transform this
  // line just wrote. One attribute, so a zoom frame costs nothing.
  placeArrow();
  zoomLabel.textContent = Math.round(scale * 100) + '%';
  // Visible while it is changing, gone a moment later: the number matters
  // during a zoom and is clutter once the view has settled.
  zoomLabel.classList.add('active');
  clearTimeout(zoomFade);
  zoomFade = setTimeout(() => zoomLabel.classList.remove('active'), 900);
}

// Zoom about a fixed point: the graph coordinate under the cursor has to land
// back under the cursor, so the translation absorbs the scale change.
function zoomAt(factor, cx, cy) {
  const next = Math.min(MAX, Math.max(MIN, scale * factor));
  const applied = next / scale;
  tx = cx - (cx - tx) * applied;
  ty = cy - (cy - ty) * applied;
  scale = next;
  touched = true;
  paint();
  // A ZOOM CAN CARRY THE MARK OFF THE SCREEN, since everything not under the
  // cursor swings away from it. Bring it back once the zooming stops.
  keepHitInView();
}

function fit() {
  const svg = pane.querySelector('svg');
  if (!svg) return;
  // Measure the element's own untransformed size, NOT getBBox(). This was
  // written because graphviz sizes the root svg in POINTS (width="2276pt"),
  // so the box it occupies is the pt->px conversion of that, ~4/3 larger than
  // the user units getBBox reports -- centring against the bbox offsets the
  // graph by that ratio. baseVal.value is the size the element OCCUPIES,
  // which is what a fit is against, whatever the units in the attribute.
  const w = svg.width.baseVal.value;
  const h = svg.height.baseVal.value;
  if (!w || !h) return;
  const pad = 24;
  scale = Math.min((pane.clientWidth - pad * 2) / w,
                   (pane.clientHeight - pad * 2) / h);
  scale = Math.min(MAX, Math.max(MIN, scale));
  tx = (pane.clientWidth - w * scale) / 2;
  ty = (pane.clientHeight - h * scale) / 2;
  // Back to a view the page chose, so a resize may reframe again.
  touched = false;
  // Immediate, like the redraw path: a fit follows a fresh SVG or a resize,
  // where a deferred frame is a visible jump rather than a smoother one.
  repaint();
}

pane.addEventListener('wheel', (e) => {
  e.preventDefault();
  const r = pane.getBoundingClientRect();
  // ctrl+wheel is what a trackpad pinch arrives as; it wants a finer step than
  // a mouse wheel notch.
  const k = Math.exp(-e.deltaY * (e.ctrlKey ? 0.01 : 0.002));
  zoomAt(k, e.clientX - r.left, e.clientY - r.top);
}, { passive: false });

let dragging = null;
pane.addEventListener('pointerdown', (e) => {
  if (e.button !== 0) return;
  dragging = { x: e.clientX - tx, y: e.clientY - ty };
  pane.setPointerCapture(e.pointerId);
  pane.classList.add('panning');
});
pane.addEventListener('pointermove', (e) => {
  if (!dragging) return;
  tx = e.clientX - dragging.x;
  ty = e.clientY - dragging.y;
  touched = true;
  paint();
});
for (const done of ['pointerup', 'pointercancel']) {
  pane.addEventListener(done, () => {
    dragging = null;
    pane.classList.remove('panning');
  });
}

// Drops the cached scan, so the next draw re-reads the sources. The one action
// that is about the SOURCE changing rather than the config.

// The view keys take a modifier now that a bare keystroke is TEXT. `0` used
// to fit the graph, and it still does with the platform's modifier held --
// but on its own it is the first character of a line, because typing
// anywhere is the way the config is written.
document.addEventListener('keydown', (e) => {
  // The editor owns the keyboard while it has focus -- typing `(box ...)`
  // must not also zoom the graph.
  if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') return;
  if (!(e.metaKey || e.ctrlKey)) return;
  const c = { x: pane.clientWidth / 2, y: pane.clientHeight / 2 };
  if (e.key === '0') { e.preventDefault(); fit(); }
  else if (e.key === '+' || e.key === '=') { e.preventDefault(); zoomAt(1.2, c.x, c.y); }
  else if (e.key === '-') { e.preventDefault(); zoomAt(1 / 1.2, c.x, c.y); }
});

// Two frames: the pane is absolutely positioned, so its height is only real
// after layout -- fitting any earlier measures against a collapsed box and
// bottoms out at the minimum scale.
function fitSoon() { requestAnimationFrame(() => requestAnimationFrame(fit)); }

// -- hovering a dependency ---------------------------------------------------
// Which file does this line come from, and where does it go? The renderer
// answers that in each edge's <title>, but a <title> is only a native tooltip
// on a 1px target. This makes the target fat and the answer visible.

// The MANGLED node name back to a readable one. Not derivable: the name is the
// path with separators replaced by underscores, so OttoClip_Cart could be
// OttoClip/Cart.swift or OttoClip_Cart.swift and nothing in the name says
// which. The node's own label does say, though -- it is wrapped a path segment
// per line, so join the lines and drop a trailing line count.
//
// LINES ARRIVE AS SIBLING <text> ELEMENTS, one per row, which is what
// graphviz emits -- each row placed at its own y rather than as tspans
// sharing a parent. Both shapes are read, because a one-line label has no
// tspan to find and an SVG from anywhere else may use them.
function moduleNames(svg) {
  const byNode = new Map();
  for (const node of svg.querySelectorAll('g.node')) {
    const key = node.querySelector('title');
    if (!key) continue;
    // A label's lines arrive one of two ways: as tspans inside a single
    // <text>, or as sibling <text> elements -- graphviz writes the second,
    // one element per line at its own y. Take every <text> in the group and
    // every tspan within them, so both shapes read the same.
    const texts = [...node.querySelectorAll('text')];
    const spans = texts.flatMap(t => [...t.querySelectorAll('tspan')]);
    const runs = (spans.length ? spans : texts)
      .map(t => t.textContent.trim());
    // The lines view appends a count as its own run. Only a run that is
    // ALL digits goes -- a file could legitimately end in a number.
    if (runs.length > 1 && /^\d+$/.test(runs[runs.length - 1])) runs.pop();
    const label = runs.join('');
    byNode.set(key.textContent.trim(), label || key.textContent.trim());
  }
  return byNode;
}

const edgeLabel = document.getElementById('edgelabel');

function showEdge(group, names) {
  // Read off the dataset, not a <title> child: wireEdges moves the text there
  // and deletes the element, because leaving it in means the browser's own
  // tooltip fades in a second later ON TOP of this label, saying the same
  // thing in mangled node names.
  const pair = group.dataset.edge;
  if (!pair) return;
  const [from, to] = pair.split('->');
  const svg = group.ownerSVGElement;
  group.classList.add('lit');
  if (svg) svg.classList.add('hovering');
  edgeLabel.replaceChildren();
  const a = document.createElement('b');
  a.textContent = names.get((from || '').trim()) || from || '?';
  const arrow = document.createElement('span');
  arrow.className = 'arrow';
  arrow.textContent = '→';
  const b = document.createElement('b');
  b.textContent = names.get((to || '').trim()) || to || '?';
  edgeLabel.append(a, arrow, b);
  edgeLabel.style.display = 'block';
}

function hideEdge() {
  for (const lit of pane.querySelectorAll('.lit')) lit.classList.remove('lit');
  const svg = pane.querySelector('svg');
  if (svg) svg.classList.remove('hovering');
  edgeLabel.style.display = 'none';
}

// Follows the pointer rather than sitting in a fixed corner: a dense graph has
// edges at both ends of the pane, and a label 900px from the line it names is a
// label you have to hunt for. Flipped near the edges so it never leaves.
function moveLabel(event) {
  if (edgeLabel.style.display !== 'block') return;
  const box = pane.getBoundingClientRect();
  let x = event.clientX - box.left + 14;
  let y = event.clientY - box.top + 14;
  if (x + edgeLabel.offsetWidth > box.width) x -= edgeLabel.offsetWidth + 24;
  if (y + edgeLabel.offsetHeight > box.height) y -= edgeLabel.offsetHeight + 24;
  edgeLabel.style.left = Math.max(0, x) + 'px';
  edgeLabel.style.top = Math.max(0, y) + 'px';
}

// Give every edge a fat transparent twin to catch the pointer. Cloning the real
// path rather than widening it: a wider visible stroke would change the
// drawing, and a stroke that grows under the cursor can push itself out from
// under it and flicker.
function wireEdges() {
  const svg = pane.querySelector('svg');
  if (!svg) return;
  const names = moduleNames(svg);
  for (const group of svg.querySelectorAll('g.edge')) {
    const line = group.querySelector('path');
    if (!line || group.querySelector('.hit')) continue;
    // Take the <title> for ourselves and REMOVE it -- see showEdge.
    const title = group.querySelector('title');
    if (title) {
      group.dataset.edge = title.textContent.trim();
      title.remove();
    }
    const hit = line.cloneNode(false);
    hit.setAttribute('class', 'hit');
    hit.removeAttribute('stroke');
    hit.removeAttribute('stroke-width');
    // Under the real path in paint order, so the visible line stays crisp.
    group.insertBefore(hit, line);
    group.addEventListener('mouseenter', () => showEdge(group, names));
    group.addEventListener('mouseleave', hideEdge);
  }
}

pane.addEventListener('mousemove', moveLabel);
// A pan would otherwise drag a stale label around with it.
pane.addEventListener('mousedown', hideEdge);

fitSoon();
wireEdges();
window.addEventListener('load', fitSoon);
// Refit on resize only while untouched, so a resize never throws away a view
// the user panned to deliberately.
window.addEventListener('resize', () => { if (!touched) fit(); });

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
async function send(action, index, keepView) {
  if (busy) return;
  busy = true;
  draw();
  // Inserting only saves; saying 'drawing' would be a lie, and the request
  // comes back too fast for the message to be read anyway.
  // Inserting adds an empty line, which draws the same graph -- so it says
  // "saving" rather than promising a redraw that would change nothing.
  const draws = action !== 'insert-above' && action !== 'insert-below';
  status.textContent = draws ? 'drawing...' : 'saving...';
  const t0 = performance.now();
  try {
    // The token goes in the query, which is where the server looks for it
    // (see the `k` check in core.janet). Without it every write is a 403 --
    // which is exactly what the panel's buttons were getting.
    const r = await fetch(`/config?k=${encodeURIComponent(window.TOKEN)}`, {
      method: 'POST',
      body: JSON.stringify({ action, index, lines }),
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
        // anything tries to show it.
        hideEdge();
        pane.innerHTML = out.svg;
        pane.appendChild(edgeLabel);
        wireEdges();
        // The arrow was drawn into the svg that just went. Re-find against
        // the new one, so a hit survives a redraw rather than leaving the
        // bar claiming a match that is no longer marked.
        unitCache = 0;
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
        if (keepView && touched) repaint(); else fit();
      }
      const count = Object.keys(faults).length;
      const ms = Math.round(performance.now() - t0);
      status.textContent = count
        ? `saved, ${count} line${count > 1 ? 's' : ''} failed`
        : draws ? `saved and drawn in ${ms}ms` : 'saved';
    }
  } catch (e) {
    problems.textContent = e.message;
    status.textContent = 'error';
  } finally {
    busy = false;
    draw();
  }
}

// -- floating panels ---------------------------------------------------------
// A panel is a title bar you can drag, a body, and a grip in the corner. Click
// the bar and it collapses into just the bar -- so the same element is both
// the window and the button that opens it, and there is no separate toggle to
// keep in sync with it.
//
// Written once and used twice: the config editor and the harness terminal are
// the same furniture with different contents. A second copy of this logic
// would be a second place for the drag-versus-click rule to drift.

// Every panel that can be driven, by its root element -- a selection is a
// DOM node and the thing that opens and shuts is an object, so one has to
// find the other. Declared HERE, above the function that fills it: the
// config's panel is made while this file is still evaluating, so a `const`
// further down would be in its dead zone and throw on the way past.
const panelsByRoot = new Map();

function makePanel(root, options = {}) {
  const bar = root.querySelector('.bar');
  const body = root.querySelector('.panel-body');
  const grip = root.querySelector('.grip');

  // Dragging the bar moves the panel; dragging the grip resizes it. Both are
  // the same gesture with a different thing on the end, so they share one
  // pointer-capture path.
  function grab(handle, onMove, onDrop) {
    handle.addEventListener('pointerdown', (e) => {
      if (e.button !== 0) return;
      e.preventDefault();
      e.stopPropagation();
      // Whichever panel you touched comes to the front. Without this the one
      // that happens to be later in the document always wins, and a panel can
      // hide under another with no way to raise it.
      raise(root);
      const box = root.getBoundingClientRect();
      const from = { x: e.clientX, y: e.clientY, w: box.width, h: box.height,
                     left: box.left, top: box.top, at: performance.now() };
      let moved = false;
      handle.setPointerCapture(e.pointerId);
      const move = (m) => {
        const dx = m.clientX - from.x, dy = m.clientY - from.y;
        // A few pixels of slop, so a click that wobbles still counts as a click.
        if (Math.abs(dx) > 3 || Math.abs(dy) > 3) moved = true;
        if (moved) onMove(dx, dy, from);
      };
      const drop = () => {
        handle.removeEventListener('pointermove', move);
        handle.removeEventListener('pointerup', drop);
        handle.removeEventListener('pointercancel', drop);
        handle.dragged = moved;
        if (onDrop) onDrop(moved);
      };
      handle.addEventListener('pointermove', move);
      handle.addEventListener('pointerup', drop);
      handle.addEventListener('pointercancel', drop);
    });
  }

  // Keep the panel reachable: at least a bar's worth has to stay on screen, or
  // it can be dragged somewhere it can never be grabbed again.
  // `free` skips the clamp. The clamp is there so a DRAGGED panel cannot be
  // put somewhere it can never be grabbed again; a scrolled row is moving
  // tabs off the side on purpose, and they come back by scrolling the other
  // way -- clamped, they would pile up against the edge instead of leaving.
  function place(left, top, free) {
    const w = root.offsetWidth, edge = 28;
    root.style.left = (free ? left
      : Math.min(Math.max(left, edge - w), innerWidth - edge)) + 'px';
    root.style.top = Math.min(Math.max(top, 0), innerHeight - edge) + 'px';
  }

  // EVERY PANEL IS A TAB, so every panel answers to the rail -- there is no
  // option for it and no call site that could forget to pass one.
  grab(bar,
       (dx, dy, from) => {
         place(from.left + dx, from.top + dy);
         railDrag(panel);
       },
       (moved) => { if (moved) railDrop(panel); });
  grab(grip, (dx, dy, from) => {
    const w = Math.max(options.minWidth || 240, from.w + dx);
    const h = Math.max(options.minHeight || 120, from.h + dy);
    root.style.width = w + 'px';
    root.style.height = h + 'px';
    if (options.onResize) options.onResize(w, h);
  });

  const panel = {
    root, bar, body, grip,
    place,
    get shut() { return root.classList.contains('shut'); },
    open() { if (panel.shut) bar.click(); },
    toggle() { bar.click(); },
  };
  panelsByRoot.set(root, panel);

  bar.addEventListener('click', () => {
    // A drag that ended on the bar is not a click asking to collapse it.
    if (bar.dragged) { bar.dragged = false; return; }
    const opening = root.classList.contains('shut');
    root.classList.toggle('shut', !opening);
    if (opening) {
      raise(root);
      // First open gets a default size; after that it keeps whatever the grip
      // was last dragged to.
      if (!root.style.width) root.style.width = options.width || 'min(46rem, 92vw)';
      if (!root.style.height) root.style.height = options.height || '22rem';
      if (options.onOpen) options.onOpen(panel);
    } else if (options.onShut) {
      options.onShut(panel);
    }
    // THE ROW MOVES WITH THE CLICK, not a quarter-second later. Opening a
    // panel changes what it takes up in the row, and waiting for the tick
    // that notices meant the neighbours visibly caught up afterwards --
    // the tick is for widths that change with nobody touching anything (a
    // pane retitling itself), not for the one case we are already in.
    if (onRail(panel)) packRail();
  });

  return panel;
}

// Panels stack in the order they were last touched. Kept as a counter rather
// than by reordering the DOM, because moving a live <div> would tear down the
// terminal's scroll position and any selection inside it.
let topmost = 5;
function raise(root) { root.style.zIndex = ++topmost; }

const configPanel = makePanel(panel, {
  minWidth: 240, minHeight: 120,
  // FOCUS THE SELECTED LINE, not the first one. Focusing an input selects
  // it, so opening on the first row was overwriting the selection every
  // time the panel came back -- the thing that was meant to persist was
  // being destroyed by the act of looking at it.
  onOpen: () => {
    const boxes = body.querySelectorAll('input');
    (boxes[picked >= 0 ? picked : 0])?.focus();
  },
});

// One number for the gap above and the gap to the left, so the row starts in
// a corner rather than at two unrelated distances from it.
const inset = 12;

// ESCAPE PUTS THE PANEL AWAY when you are working in it. "In it" is where the
// focus is, not merely whether it is open: the panel can sit open while you
// pan the graph or type in the compose bar, and an escape meant for either of
// those should not also close the editor behind them.
//
// LAST of the escapes. The help sits over everything and takes it first; the
// compose bar takes it next, closing its list and then itself, since both are
// in front of the panel. Each of those returns before this runs, so this only
// ever sees an escape nothing else wanted.
document.addEventListener('keydown', (e) => {
  if (e.key !== 'Escape') return;
  if (configPanel.shut) return;
  if (!panel.contains(document.activeElement)) return;
  e.preventDefault();
  // Focus goes with it: left on a row inside a shut panel, the keyboard
  // would be pointed at something nobody can see.
  document.activeElement.blur();
  configPanel.toggle();
});

lines = window.CONFIG_LINES || [];
for (const [at, why] of Object.entries(window.CONFIG_PROBLEMS || {})) {
  faults[Number(at)] = why;
}
draw();
// Open the panel unasked when the file has something wrong in it -- an error
// you cannot see is worse than one you did not ask about.
if (Object.keys(faults).length) requestAnimationFrame(() => bar.click());

// And from here on the graph keeps up with the files by itself.
watchSource();


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

  // How wide a character is at a given size, in this face. Monospace, so one
  // number does for all of them -- measured once rather than guessed at, so
  // the 88 is 88 and not "about 88".
  const em = charWidth();
  const capPx = Math.round(88 * COMPOSE_MIN_PX * em);

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
  composeInput.style.font = `${px}px/${line}px ui-monospace, monospace`;
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

// ONE CHARACTER WIDE, as a fraction of the font size. Measured from the real
// face rather than assumed to be .6 -- the assumption was close enough for a
// rough cap and not for a promise of 88 characters. Cached: it is a property
// of the font, and the font does not change.
let charEm = 0;
function charWidth() {
  if (charEm) return charEm;
  const probe = document.createElement('span');
  probe.style.cssText =
    'position:absolute;visibility:hidden;white-space:pre;font:100px/1 ui-monospace, monospace';
  probe.textContent = '0'.repeat(100);
  document.body.appendChild(probe);
  charEm = probe.getBoundingClientRect().width / 100 / 100;
  probe.remove();
  return charEm || 0.6;
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
    if (term.type) {
      const keys = typed.replace(/\r\n|\n/g, '\r');
      term.type(keys.endsWith('\r') ? keys : keys + '\r');
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
  if (rail.length < 2) return;
  // Where we are now: the selected tab if it is on the rail, else the start.
  const here = rail.indexOf(pickedPanel());
  const from = here < 0 ? 0 : here;
  const to = ((from + by) % rail.length + rail.length) % rail.length;
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
    // AFTER THE ROW HAS SETTLED. Opening a tab makes it claim its window's
    // width and pushes everything after it along, so where the tab IS is
    // not known until the packing has run -- revealing before that scrolls
    // to where it used to be.
    revealTab(next);
    // A tab opened by walking is not a tab the release should close as
    // though the press had opened it: the walk owns it, and the keyup asks
    // `altPeeked` rather than `altOpened`.
    altOpened = false;
  } else {
    altOpened = false;
    revealTab(next);
  }
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



/* -- find ------------------------------------------------------------------
   THE BROWSER'S OWN FIND CANNOT DO THIS. Cmd-F matches text in the document,
   and a node's name in a graphviz SVG is scattered across sibling <text>
   elements -- so `src.visualize.scan` is not findable as itself, and a match
   that did land would be highlighted somewhere off-screen with the view left
   where it was. There is also no way to read what the user typed into it: no
   event fires, and nothing exposes the query or the hit.

   So the key is taken and this opens instead. It searches the names the
   graph actually has, and marks a hit by DRAWING IN THE GRAPH -- an arrow in
   the svg's own user units, so it pans and zooms with the thing it points
   at rather than sliding off it. */

const find = document.getElementById('find');
const findInput = document.getElementById('find-input');
const findCount = document.getElementById('find-count');

// The current hits, and where in them we are. Held rather than recomputed on
// Enter: the list must not reorder under the cursor while stepping through
// it, the same reason the completion list freezes during ctrl-n.
let hits = [];
let hitAt = 0;

function finding() { return !find.classList.contains('shut'); }

// A node matches on either name it has: the dotted key (`src.visualize.scan`)
// or the label as drawn, which is the key minus whatever prefix an alias
// replaced. Typing what you SEE has to work, and so does typing the full
// path -- they differ whenever a `prefix` is in play.
function searchNodes(query) {
  const svg = pane.querySelector('svg');
  if (!svg || !query) return [];
  const names = moduleNames(svg);
  const needle = query.toLowerCase();
  const found = [];
  for (const node of svg.querySelectorAll('g.node')) {
    const title = node.querySelector('title');
    if (!title) continue;
    const key = title.textContent.trim();
    const label = names.get(key) || key;
    const hay = (key + ' ' + label).toLowerCase();
    const at = hay.indexOf(needle);
    if (at < 0) continue;
    // A NAME THAT STARTS WITH THE QUERY BEATS ONE THAT MERELY CONTAINS IT,
    // and shorter beats longer among those -- `scan` should find `scan`
    // before `src.visualize.scan.helper`.
    const starts = key.toLowerCase().startsWith(needle) ||
                   label.toLowerCase().startsWith(needle);
    found.push({ node, key, label, rank: (starts ? 0 : 1) * 1000 + key.length });
  }
  found.sort((a, b) => a.rank - b.rank);
  return found;
}

// Where to point AT: the middle of the node's shape, in the svg's user units.
// getBBox is in those units already, which is what the arrow is drawn in --
// so nothing here has to know the current pan or zoom.
function centreOf(node) {
  const shape = node.querySelector('ellipse, polygon, path');
  if (!shape) return null;
  const b = shape.getBBox();
  return { x: b.x + b.width / 2, y: b.y + b.height / 2, w: b.width, h: b.height };
}

// THE ARROW COMES FROM WHERE THERE IS ROOM. A fixed approach angle means a
// dense graph gets an arrow laid across three unrelated nodes on its way in,
// which points at everything it crosses. Each candidate direction is scored
// by what its shaft would cover, and the emptiest wins.
function approachFor(svg, target, node) {
  const others = [...svg.querySelectorAll('g.node')]
    .filter(n => n !== node)
    .map(centreOf)
    .filter(Boolean);
  // EDGES COUNT AS THINGS TO AVOID, not just nodes. Scoring against nodes
  // alone sent the arrow straight up the line into its target -- clear of
  // every box and laid along an edge for its whole length, which reads as
  // pointing at the edge. Sampled along each path, since an arbitrary curve
  // has no box to test against.
  const lines = [];
  for (const path of svg.querySelectorAll('g.edge path')) {
    let len = 0;
    try { len = path.getTotalLength(); } catch (err) { continue; }
    if (!len) continue;
    for (let d = 0; d <= len; d += Math.max(12, len / 12)) {
      const pt = path.getPointAtLength(d);
      lines.push({ x: pt.x, y: pt.y, w: 0, h: 0 });
    }
  }
  // Eight compass points, at a distance that scales with the node so the
  // arrow reads the same next to a big box and a small one.
  // THE ARROW MUST FIT WHERE IT IS BEING LOOKED AT. Its length is a screen
  // distance, so it is capped by the pane rather than the drawing: zoomed
  // in, an arrow the length of a whole node is longer than the viewport, and
  // the tail runs off the edge with only the shaft crossing the screen. A
  // quarter of the smaller side leaves it clearly an arrow and clearly
  // inside.
  // How far out the tail sits, in GRAPH units -- this is only used to score
  // which way is clearest, and the arrow that gets drawn is a fixed length in
  // screen pixels. Scaled by the zoom so the sampling covers roughly what the
  // drawn arrow will cover.
  const reach = (96 + Math.max(target.w, target.h) * 0.35) / zoomNow() + edgeOf(target);
  let best = null;
  for (let i = 0; i < 8; i++) {
    const angle = (i / 8) * Math.PI * 2;
    const tail = {
      x: target.x + Math.cos(angle) * reach,
      y: target.y + Math.sin(angle) * reach
    };
    // How close does the shaft pass to anything else? Sampled along its
    // length -- exact segment/box intersection would be more precise than
    // this needs to be, since ANY near miss is reason enough to prefer
    // another direction.
    let worst = Infinity;
    for (let t = 0.15; t <= 1; t += 0.15) {
      const px = tail.x + (target.x - tail.x) * t;
      const py = tail.y + (target.y - tail.y) * t;
      for (const o of others) {
        const dx = Math.abs(px - o.x) - o.w / 2;
        const dy = Math.abs(py - o.y) - o.h / 2;
        worst = Math.min(worst, Math.max(dx, dy));
      }
      // An edge point has no extent, so the distance to it is plain -- but
      // it is capped, because a shaft only has to clear a line, not stay as
      // far from it as it would from a whole box.
      for (const o of lines) {
        const d = Math.hypot(px - o.x, py - o.y);
        worst = Math.min(worst, Math.min(d, 40));
      }
    }
    if (!best || worst > best.clear) best = { tail, angle, clear: worst };
  }
  return best;
}

const ARROW_NS = 'http://www.w3.org/2000/svg';

// Roughly how far the shape reaches from its own centre. Only used to start
// the clearance sampling outside the node it belongs to.
function edgeOf(t) { return Math.max(t.w, t.h) / 2; }

// The live zoom. Read through a function so the arrow geometry and the
// approach search agree even though they run at different moments.
function zoomNow() { return scale || 1; }

function clearArrow() {
  const old = pane.querySelector('#find-arrow');
  if (old) old.remove();
  for (const n of pane.querySelectorAll('g.node.found')) n.classList.remove('found');
}

// Drawn INSIDE the svg, in its coordinate system, so the arrow is part of the
// drawing: pan and zoom move it with its target, and it is in the image if
// the drawing is saved. Appended last so it sits over the nodes it passes.
function drawArrow(hit) {
  clearArrow();
  const svg = pane.querySelector('svg');
  if (!svg || !hit) return;
  const target = centreOf(hit.node);
  if (!target) return;
  // The root <svg> has a transform on its child <g> (graphviz's translate);
  // drawing into that group puts us in the same units as the node boxes.
  const host = svg.querySelector('g') || svg;
  const aim = approachFor(svg, target, hit.node);

  // Stop at the edge of the shape rather than the centre, so the head sits
  // against the node and does not cover the name it just found.
  //
  // THE EDGE IN THE DIRECTION WE COME FROM, not the widest one. A node is a
  // wide flat ellipse -- 201 by 36 here -- and backing off by half its
  // WIDTH when approaching from above left the point a hundred units short,
  // an arrow aimed at empty space near something.
  const rx = target.w / 2, ry = target.h / 2;
  const ca = Math.cos(aim.angle), sa = Math.sin(aim.angle);
  const edge = (rx * ry) / Math.hypot(ry * ca, rx * sa);

  const g = document.createElementNS(ARROW_NS, 'g');
  g.setAttribute('id', 'find-arrow');
  g.setAttribute('pointer-events', 'none');

  // DRAWN ONCE, IN ITS OWN LITTLE SPACE. The shape below is written in plain
  // pixels along a straight line -- tip at the origin, tail out to the right
  // -- and then placed by a transform: moved to the node's edge, turned to
  // the approach angle, and scaled by 1/zoom. Only that last number changes
  // when the view moves, so a zoom re-writes ONE attribute instead of
  // re-deciding the whole arrow, and the browser does the rest.
  const L = 96;                       // shaft length, in screen pixels
  const HEAD = 22, SPREAD = 0.38;
  const meet = HEAD * Math.cos(SPREAD);

  const shaft = document.createElementNS(ARROW_NS, 'line');
  shaft.setAttribute('class', 'find-shaft');
  shaft.setAttribute('x1', L);
  shaft.setAttribute('y1', 0);
  // Stops exactly at the head's base. With a butt cap there is nothing to
  // subtract for: the stroke ends on the coordinate, so the two meet flush.
  shaft.setAttribute('x2', meet);
  shaft.setAttribute('y2', 0);

  const head = document.createElementNS(ARROW_NS, 'polygon');
  head.setAttribute('class', 'find-head');
  head.setAttribute('points', [
    [0, 0],
    [HEAD * Math.cos(SPREAD), HEAD * Math.sin(SPREAD)],
    [HEAD * Math.cos(-SPREAD), HEAD * Math.sin(-SPREAD)]
  ].map(p => p.join(',')).join(' '));

  g.append(shaft, head);
  // Where the point goes and which way it faces -- fixed in graph units, so
  // panning is the browser moving the drawing and this never runs.
  g.dataset.x = target.x + ca * edge;
  g.dataset.y = target.y + sa * edge;
  g.dataset.deg = (aim.angle * 180) / Math.PI;
  host.append(g);
  placeArrow();
  hit.node.classList.add('found');
}

// THE ONLY THING A ZOOM CHANGES. The arrow is built in screen pixels, so it
// needs undoing exactly as much as the view does it: a counter-scale of
// 1/zoom keeps it the size it was drawn, and the stroke holds its width
// through `vector-effect` in the stylesheet rather than arithmetic here.
// One attribute, no geometry, nothing measured.
function placeArrow() {
  const g = pane.querySelector('#find-arrow');
  if (!g) return;
  const k = 1 / ((scale || 1) * unitPx());
  g.setAttribute('transform',
    `translate(${g.dataset.x} ${g.dataset.y}) rotate(${g.dataset.deg}) scale(${k})`);
}

// HOW BIG ONE USER UNIT IS ON SCREEN, over and above our own zoom. Graphviz
// declares the svg in POINTS -- width="1057pt" over a 1057-unit viewBox --
// so the browser adds a 96/72 conversion that `scale` knows nothing about.
// Counter-scaling by 1/scale alone left the arrow 4/3 too big.
//
// Measured once per drawing rather than per frame: it is a property of the
// svg, and reading a CTM forces layout. Cleared whenever the svg is replaced.
let unitCache = 0;
function unitPx() {
  if (unitCache) return unitCache;
  const svg = pane.querySelector('svg');
  if (!svg) return 1;
  const w = parseFloat(svg.getAttribute('width'));
  const box = (svg.getAttribute('viewBox') || '').split(/[\s,]+/);
  const vw = parseFloat(box[2]);
  // pt -> px when the width carries units, 1 when it is already px.
  const factor = /pt\s*$/.test(svg.getAttribute('width') || '') ? 96 / 72 : 1;
  unitCache = (w && vw) ? (w / vw) * factor : factor;
  return unitCache;
}

// BRING IT INTO VIEW, but only when it is not already there: a hit you can
// see should not make the graph jump, and stepping through hits that share a
// corner should not re-centre on each one.
// BRING THE WHOLE MARK INTO VIEW, arrow included. Framing the node alone
// left the arrow hanging off the edge -- it approaches from a distance, so a
// node sitting comfortably inside the pane can still have its tail outside,
// and an arrow you cannot see is one that did not render as far as anyone
// looking can tell.
function revealHit(hit) {
  const svg = pane.querySelector('svg');
  if (!svg || !hit) return;
  const node = hit.node.getBoundingClientRect();
  const arrow = pane.querySelector('#find-arrow');
  // Union of the two, so the pan accounts for whichever reaches furthest.
  let box = node;
  if (arrow) {
    const a = arrow.getBoundingClientRect();
    box = {
      left: Math.min(node.left, a.left), right: Math.max(node.right, a.right),
      top: Math.min(node.top, a.top), bottom: Math.max(node.bottom, a.bottom)
    };
    box.width = box.right - box.left;
    box.height = box.bottom - box.top;
  }
  const view = pane.getBoundingClientRect();
  const margin = 24;
  const inside = box.left > view.left + margin && box.right < view.right - margin &&
                 box.top > view.top + margin && box.bottom < view.bottom - margin;
  if (inside) return;
  // CENTRE ON WHATEVER FITS. The union says whether a pan is wanted, but
  // centring it is only right while it fits: zoomed in, an arrow longer than
  // the pane can never be framed, and centring the union put the node itself
  // out past the edge -- the arrow correct, and pointing at something you
  // could not see. Fall back to the node, which is the part that matters.
  const fits = box.width < view.width - margin * 2 &&
               box.height < view.height - margin * 2;
  const aim = fits ? box : node;
  // Shift by the difference between the mark's centre and the pane's, in
  // screen pixels -- tx/ty are screen-space, so no unit conversion is needed.
  tx += (view.left + view.width / 2) - (aim.left + aim.width / 2);
  ty += (view.top + view.height / 2) - (aim.top + aim.height / 2);
  touched = true;
  // NOW, not next frame: a caller that measures straight after this -- the
  // next hit in a walk, or the reveal for a second arrow -- would read the
  // old transform and pan against a view that is already moving.
  repaint();
}

// Follow the current hit after the view moves under it. Guarded, because
// revealHit pans and painting is what called us in the first place.
let keeping = false;
// AFTER THE GESTURE, NOT DURING IT. Zooming is about a point: the thing
// under the cursor is meant to stay put, and re-centring on every notch
// fought the hand doing the zooming. It also cost a forced layout per wheel
// event, since deciding takes measuring. So the check waits for the scroll
// to stop, and only then, and only if the mark has actually left the pane,
// does it come back.
let keepTimer = 0;
function keepHitInView() {
  clearTimeout(keepTimer);
  keepTimer = setTimeout(() => {
    if (keeping) return;
    const hit = hits[hitAt];
    if (!hit || !hit.node.isConnected) return;
    if (!pane.querySelector('#find-arrow')) return;
    keeping = true;
    try { revealHit(hit); } finally { keeping = false; }
  }, 180);
}

function runFind() {
  const query = findInput.value.trim();
  hits = searchNodes(query);
  hitAt = 0;
  if (!query) {
    findCount.textContent = '';
    find.classList.remove('empty');
    clearArrow();
    return;
  }
  if (!hits.length) {
    findCount.textContent = 'no match';
    find.classList.add('empty');
    clearArrow();
    return;
  }
  find.classList.remove('empty');
  showHit();
}

function showHit() {
  const hit = hits[hitAt];
  if (!hit) return;
  findCount.textContent = hits.length > 1 ? `${hitAt + 1}/${hits.length}` : '';
  drawArrow(hit);
  revealHit(hit);
}

function stepHit(by) {
  if (hits.length < 2) return;
  // WRAPS, like the completion list and the config selection.
  hitAt = (hitAt + by + hits.length) % hits.length;
  showHit();
}

function openFind() {
  if (!help.classList.contains('shut')) shutHelp();
  find.classList.remove('shut');
  findInput.select();
  findInput.focus();
  // Re-run rather than clear: reopening with the last query still in the
  // field should show what it found, not an empty bar you have to retype.
  if (findInput.value.trim()) runFind();
  renderFindList();
}

function shutFind() {
  find.classList.add('shut');
  find.classList.remove('empty');
  clearArrow();
  shutFindList();
  hits = [];
  findInput.blur();
}

/* -- completing in the find bar -------------------------------------------
   THE SAME POOL THE COMPOSE BAR OFFERS: every node name, every dotted prefix
   of one, and every bound alias -- `prefixCandidates` already builds exactly
   that, so what you can search for and what you can write in the config stay
   the same list. Ranked by the same rule, too: a match at the start beats one
   in the middle, and shorter beats longer, since a shorter prefix is the
   broader thing and usually what was meant.

   The bar's own keys come first, though. Enter already means "next hit" here,
   so TAB is what accepts a completion -- and because taking one is choosing
   what to look for, it searches rather than just filling the field. */

const findList = document.getElementById('find-list');
let findItems = [];
let findAt = -1;

function renderFindRows() {
  findList.replaceChildren();
  if (!findItems.length) {
    find.classList.remove('listing');
    findAt = -1;
    return;
  }
  find.classList.add('listing');
  findItems.forEach((text, i) => {
    const li = document.createElement('li');
    li.textContent = text;
    li.setAttribute('role', 'option');
    li.setAttribute('aria-selected', String(i === findAt));
    if (i === findAt) li.className = 'at';
    li.addEventListener('mousedown', (e) => {
      e.preventDefault();          // keep the caret in the field
      takeFind(i);
    });
    findList.appendChild(li);
  });
  if (findAt >= 0) findList.children[findAt]?.scrollIntoView({ block: 'nearest' });
}

function renderFindList() {
  const typed = findInput.value.trim();
  // NOTHING TYPED OFFERS EVERYTHING, so opening the bar shows what there is
  // to look for rather than an empty box you have to guess at.
  findItems = finding() ? rank(prefixCandidates(), typed) : [];
  findAt = -1;
  renderFindRows();
}

// Taking a candidate SEARCHES for it. In the compose bar a completion is
// text you are still writing; here the text is the whole question, so
// filling it in and not answering would leave the arrow pointing at whatever
// the previous query found.
function takeFind(i) {
  const text = findItems[i];
  if (text === undefined) return;
  findInput.value = text;
  findAt = i;
  runFind();
  renderFindRows();
}

function moveFindList(step) {
  if (!findItems.length) return;
  // Wraps, and from nothing selected down takes the first row and up the
  // last -- the same arithmetic as the completion list.
  if (findAt < 0) findAt = step > 0 ? 0 : findItems.length - 1;
  else findAt = ((findAt + step) % findItems.length + findItems.length) % findItems.length;
  takeFind(findAt);
}

function shutFindList() {
  findItems = [];
  findAt = -1;
  findList.replaceChildren();
  find.classList.remove('listing');
}

findInput.addEventListener('input', () => {
  runFind();
  // Typing rebuilds the list; moving only moves in it -- so the rows cannot
  // reorder under the cursor mid-walk.
  renderFindList();
});

// The pointer only highlights while it is actually in use; see the compose
// list for why a hidden cursor must stop lighting rows.
findList.addEventListener('mousemove', () => find.classList.add('mousing'));
findInput.addEventListener('keydown', () => find.classList.remove('mousing'));

findInput.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') {
    e.preventDefault();
    // THE LIST GOES FIRST. Escape means "put away the thing in my way", and
    // with a list open that is the list -- closing the whole bar would throw
    // away the query too, on the one keystroke most likely to be a reflex.
    if (findItems.length) shutFindList(); else shutFind();
    return;
  }
  // TAB ACCEPTS, because Enter is already spoken for here: it steps through
  // the hits, which is the bar's real work.
  if (e.key === 'Tab' && findItems.length) {
    e.preventDefault();
    takeFind(findAt < 0 ? 0 : findAt);
    return;
  }
  if (e.ctrlKey && (e.key === 'n' || e.key === 'p') && findItems.length) {
    e.preventDefault();
    moveFindList(e.key === 'n' ? 1 : -1);
    return;
  }
  if (e.key === 'Enter') {
    e.preventDefault();
    // Shift-Enter goes back, the one convention the native find does have
    // that is worth keeping.
    stepHit(e.shiftKey ? -1 : 1);
    return;
  }
  // ARROWS WALK THE LIST WHILE IT IS OPEN, and step the hits once it is not.
  // The list is the nearer thing when it is up, and stepping hits behind an
  // open list moves an arrow you cannot see past the rows covering it.
  if (e.key === 'ArrowDown') {
    e.preventDefault();
    if (findItems.length) moveFindList(1); else stepHit(1);
  }
  if (e.key === 'ArrowUp') {
    e.preventDefault();
    if (findItems.length) moveFindList(-1); else stepHit(-1);
  }
});

// TAKING CMD-F. On the capture phase and before the compose bar's own
// handler, so the keystroke opens this rather than starting a config line.
document.addEventListener('keydown', (e) => {
  if (!(e.metaKey || e.ctrlKey) || e.key !== 'f') return;
  e.preventDefault();
  if (finding()) { findInput.select(); findInput.focus(); return; }
  openFind();
}, true);

// A redraw replaces the svg, and the arrow was drawn into the old one.
// Called from the redraw itself rather than listening for an event, since
// that is the only place the swap happens.
function redrawFind() {
  if (finding() && findInput.value.trim()) runFind();
}



// -- the terminal panes ------------------------------------------------------
// A pty on the server, an emulator here, and a poll loop between them. Polled
// rather than streamed: the page has to POST keystrokes regardless, so one
// endpoint returning "everything since chunk N" is both the live path and the
// catch-up path for a reload. An SSE stream would need a second mechanism for
// input and a way to resume when it drops.
//
// Written once and instantiated twice: the agent harness and the dev repl are
// the same pane speaking to different endpoint prefixes -- /pane/harness/*
// drives the supervisor's agent pty, /pane/repl/* a pty running ./repl
// against this server's own image. Nothing in here knows which one it is.
//
// THE /pane/ PREFIX EARNS ITS KEYSTROKES. "repl" names three things in this
// project -- the Janet repl the server hosts on a unix socket, the ./repl
// script that attaches a terminal to it, and this browser pane that runs
// that script in a pty -- so a route called /repl/poll read like it polled
// the Janet image rather than a terminal window. /pane/repl/poll cannot be
// misread: whatever else is going on, this is a pane talking.

function makeTerminalPane(root, prefix) {
  const stateLine = root.querySelector('.state');
  const nameLabel = root.querySelector('.name');
  const screen = root.querySelector('.screen');


  // Follow the output the way a terminal does -- but only while the view is at
  // the bottom. The flag comes from the user's own scrolling, so scrolling up
  // to read mid-stream is honoured for as long as they stay up, and returning
  // to the bottom re-arms the follow. The pin itself happens in onPaint, after
  // the DOM has its new height: paints are deferred a frame, so pinning at
  // write time scrolls to the PREVIOUS frame's bottom -- and, measured there,
  // "am I at the bottom?" is off by up to a whole chunk, which is what made an
  // earlier version stop following fast streams.
  const paneBody = root.querySelector('.panel-body');
  let following = true;
  paneBody.addEventListener('scroll', () => {
    following = paneBody.scrollTop + paneBody.clientHeight
      >= paneBody.scrollHeight - 4;
  });
  // The pin runs only when the rendered line count moved: scrollHeight is a
  // forced layout, and a scroll-through-history repaint redraws the same 33
  // rows at display rate -- reading the layout back after every one of those
  // renders was half the jank the rAF pacing in term.js fixed the other
  // half of. Same row count, same height, nothing to pin.
  let paintedLines = 0;

  // NO GLIDE between the line-quantized frames a scrolling TUI paints --
  // tried, shipped, removed. The animation translated the live block by the
  // rows just scrolled and eased it to rest, and it read beautifully for a
  // single step. Under a continuous wheel it shook: reports flush every
  // 16ms, the program repaints per batch, and each new frame restarted the
  // 90ms ease from a fresh offset -- plus the translate slid the live block
  // against the history block above it, so the seam flickered. Line-stepped
  // frames are what every native terminal shows; they looked wrong here only
  // while the transport added up to 250ms per step. Streaming brought a step
  // to ~30ms, which is the regime iTerm lives in. The frames can simply be
  // shown.
  const term = makeTerminal(screen, {
    onPaint: (lines) => {
      const grew = lines !== paintedLines;
      paintedLines = lines;
      if (grew && following) paneBody.scrollTop = paneBody.scrollHeight;
    },
  });
  // -- the stall detector ----------------------------------------------------
  // The server side was exonerated at 7,900 reports/s with 16ms worst-case
  // turnaround; the ~10s scroll hangs therefore live somewhere in THIS
  // page or its browser. Instead of theorizing, record: main-thread stalls
  // (longtask entries) and gaps in the poll chain land in a ring, the worst
  // recent one is named in the state line, and window.__diag() dumps the
  // ring for a bug report. Costs nothing until something stalls.
  const diag = [];
  function diagNote(kind, ms) {
    diag.push({ t: Math.round(performance.now()), kind, ms: Math.round(ms) });
    if (diag.length > 60) diag.shift();
    // RECORDED, NOT ANNOUNCED. This used to write into the pane's state
    // line, which is the wrong channel twice over: the line is for things a
    // person acts on -- "exited", "server outdated" -- and a stall that has
    // already ended is not one of those, while a message that stays until
    // something overwrites it turns a moment into a permanent-looking
    // condition. The ring is still here for window.__diag() and it is still
    // what the next investigation reads; it just no longer shouts.
    console.debug(`visualize: ${kind} stall ${(ms / 1000).toFixed(1)}s`);
  }
  if (prefix === 'harness') window.__diag = () => diag.slice();
  if (typeof PerformanceObserver === 'function' && prefix === 'harness') {
    try {
      new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) {
          if (entry.duration > 250) diagNote('main-thread', entry.duration);
        }
      }).observe({ entryTypes: ['longtask'] });
    } catch (e) { /* longtask unsupported: the ring still gets poll gaps */ }
  }
  let lastPollDone = 0;
  // A version mismatch among page, server and supervisor, once seen, is
  // named in the state line until it stops being true. Two debugging
  // rounds were once spent on fixes that sat on disk while every process
  // kept running its birth code; this is what would have said so.
  let stampNote = '';
  // Server-side faults since this pane attached, named in the state line.
  let faultNote = '';

  let at = 0;              // how much of the session output we have consumed
  let polling = false;     // is the loop running? (see scheduleNextPoll)
  let pollFailures = 0;    // consecutive misses; three in a row means gone
  let generation = 0;      // bumped server-side per start, so a restart resets us

  // Every terminal request carries the token; without it the server answers 403.
  // See `permitted?` in src/core.janet for why localhost alone is not enough.
  async function post(path, body = {}, timeoutMs = 15000) {
    // THE TIMEOUT IS WHAT SURVIVES A SUSPEND. A fetch that is in flight when
    // the machine sleeps can come back neither resolved nor rejected, and the
    // poll chain -- guarded by pollInFlight -- then waits on it forever: no
    // polls, no error, a cursor still blinking because the blink is CSS. An
    // aborted request rejects like any failure and lands in the retry path.
    const response = await fetch(`/pane/${prefix}/${path}?k=${encodeURIComponent(window.TOKEN)}`, {
      method: 'POST',
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (!response.ok) throw new Error(await response.text());
    return response.json();
  }

  // How many rows and columns fit the panel right now. Measured from a real
  // character rather than assumed: the monospace face and its size come from
  // CSS, so hardcoding a cell size here would break the moment either changed.
  // Cached: the probe forces a synchronous layout, and the wheel handler asks
  // at trackpad rate -- a reflow per wheel tick, against a render per frame,
  // is layout thrash a person sees as jank. The size only changes with the
  // font, so syncSize (every geometry change passes through it) invalidates.
  let cell = null;
  function cellSize() {
    if (cell) return cell;
    const probe = document.createElement('span');
    probe.textContent = 'M';
    probe.style.cssText = 'position:absolute;visibility:hidden;white-space:pre';
    screen.appendChild(probe);
    const box = probe.getBoundingClientRect();
    probe.remove();
    cell = { w: box.width || 7, h: box.height || 16 };
    return cell;
  }

  function measure() {
    const { w: cw, h: ch } = cellSize();
    return {
      rows: Math.max(4, Math.floor((paneBody.clientHeight - 24) / ch)),
      cols: Math.max(20, Math.floor((paneBody.clientWidth - 12) / cw)),
    };
  }

  function setState(text) { stateLine.textContent = text; }

  // THE BAR SAYS WHAT IS RUNNING, from the argv the host reports rather than
  // from anything this page chose -- the two can differ, since the command
  // is read per request and the pane may have been started by a page that is
  // now closed.
  //
  // The LEAF of the path, because /bin/zsh and /opt/homebrew/bin/zsh are the
  // same answer to "what is this?" and a bar is a few characters wide.
  // WHAT THE TERMINAL IS RUNNING NOW, from the foreground process group the
  // host reads off the pty. A pane that has run `vim` says vim; when vim
  // exits and the shell is back, it says zsh again.
  //
  // Empty means the host could not tell -- an older supervisor, or a moment
  // between programs -- and the title is left alone rather than blanked.
  function setProgram(name) {
    if (!name) return;
    if (nameLabel.textContent === name) return;
    nameLabel.textContent = name;
    // The tab just changed width, so the row has to close up around it.
    if (typeof packRail === 'function') packRail();
  }

  function setName(argv) {
    if (!Array.isArray(argv) || !argv.length) return;
    // THE LEAF, and only the leaf. The pane's number used to ride along
    // because several tabs saying `zsh` were otherwise indistinguishable --
    // the cross beside each one tells them apart now, and a number was
    // never what anyone wanted to read.
    nameLabel.textContent = String(argv[0]).split('/').filter(Boolean).pop();
  }

  async function poll() {
    try {
      // The generation says which session `at` counts chunks in. Without it a
      // restarted agent leaves the page asking about chunks that no longer
      // exist, and the reply is empty forever.
      const askedAt = at, askedGen = generation;
      // `wait` invites the supervisor to PARK this request until it has
      // something to say -- the streaming transport. Output leaves the pty
      // and lands here ~10ms later instead of waiting out a poll timer. The
      // fetch timeout leaves 10s of headroom over the park.
      const out = await post('poll', { at: askedAt, generation: askedGen,
                                       wait: LONGPOLL_WAIT }, LONGPOLL_WAIT + 10000);
      // A reply saying "could not reach the supervisor" is a failed request
      // wearing a 200; treating its running=false/generation=0 as session
      // truth is what blanked the screen after a suspend. Absent -- the socket
      // file itself gone -- is different again: that is a supervisor shut down
      // for real, and the honest state is exited, not eternal reconnecting.
      setProgram(out.program);
      if (out.reachable === false) {
        if (out.absent) { setState('exited'); stopPolling(); return; }
        throw new Error('supervisor unreachable');
      }
      // A keystroke's echo won the race and moved the cursor; this reply is
      // answering a question that is no longer being asked. The chain is
      // already scheduling the next poll, which asks the right one.
      if (stale(askedAt, askedGen)) { pollFailures = 0; return; }
      // A restart on the server means our screen belongs to a dead session, so
      // it is cleared before the new session's output is drawn onto it.
      //
      // THE TEXT IN THIS REPLY IS NOT DISCARDED, and an earlier version's bug
      // was exactly that: it reset, set `at = 0` and returned. But `at` was
      // already 0 when the reply was requested, so the very next poll asked the
      // same question, got the same answer, and threw it away again -- forever.
      // The screen stayed blank while the server held the whole session, and
      // the cursor kept blinking because that is a CSS animation.
      if (out.generation !== generation) {
        generation = out.generation;
        at = 0;
        term.reset();
      }
      // A TORN STREAM IS NOT AN UPDATE. When the backlog cap trims past our
      // position, the reply's text starts BEYOND what we asked for --
      // `from` says so -- and begins mid-frame, possibly mid-escape (a
      // literal "[7C" painted on screen was this bug wearing its cause).
      // Writing it smears garbage over a stale grid. Reset instead, take
      // the new position, and ask the program to repaint whole: SIGWINCH
      // reaches anything full-screen, and a line program's next output
      // starts clean anyway.
      if (out.from > askedAt && askedAt > 0 && out.generation === askedGen) {
        term.reset();
        at = out.at;
        lastOutput = performance.now();
        post('redraw').catch(() => {});
      } else if (out.text) {
        term.write(out.text);
        at = out.at;
        // Output just arrived, so the next poll should be immediate: an agent
        // mid-response has more coming, and this is what keeps streaming smooth
        // rather than stepping along at the idle delay.
        lastOutput = performance.now();
        // Following the output happens in the emulator's onPaint, once the
        // new height exists to scroll to.
      }
      // SERVER FAULTS SURFACE IN THE PANE. They used to go only to stderr,
      // which nobody working in this page can see -- so a tool for making a
      // codebase visible hid its own failures. The count is cheap to carry
      // and the detail is one repl call away, or ./pane faults.
      if (out.faults) faultNote = out.faults > 0
        ? `${out.faults} server fault${out.faults > 1 ? 's' : ''}` : '';
      if (out.serverStamp) {
        stampNote = window.STAMP && out.serverStamp !== window.STAMP
          ? 'page outdated — reload'
          : (out.stamp && out.stamp !== out.serverStamp
              ? 'supervisor outdated — restart the session to update' : '');
      }
      // Order is severity: a version mismatch explains everything else, a
      // fault is the next most useful thing to know, and "exited" is the
      // ordinary end of a session.
      setState(stampNote || faultNote || (out.running ? '' : 'exited'));
      if (!out.running) stopPolling();
      pollFailures = 0;
      // A gap longer than a park can explain is a stall. ONE THRESHOLD, and
      // it is the park's own length plus slack: the previous version used a
      // tighter 5s bound whenever the last reply carried text, reasoning
      // that mid-stream means more is coming -- but output followed by
      // quiet is how every burst ENDS, so the first park after any output
      // tripped it. It reported "stalled 20.0s (poll-gap)" for a pane
      // working exactly as designed, which is worse than reporting nothing:
      // a warning that cries wolf teaches you to ignore the channel real
      // warnings arrive on.
      const done = performance.now();
      if (lastPollDone && done - lastPollDone > LONGPOLL_WAIT + 8000) {
        diagNote('poll-gap', done - lastPollDone);
      }
      lastPollDone = done;
      // A reply that says `waited` came from a supervisor that parks; the
      // next ask should already be on its way when output arrives, so the
      // chain re-polls with no timer at all. Judged per reply, not once:
      // the supervisor under this page can change across a restart, and an
      // old one that ignores `wait` answers instantly without the marker --
      // chaining on THAT would be a busy-spin, so it keeps its timers.
      streaming = !!out.waited;
    } catch (e) {
      // A SINGLE dropped request must not kill the terminal. The server answers
      // hundreds of polls an hour, and one 500 -- a transient race, a supervisor
      // mid-restart -- used to flip the panel to "disconnected" and stop polling
      // for good, leaving a live agent invisible behind a dead pane. Three in a
      // row means it is really gone.
      pollFailures++;
      // NEVER a terminal state. The server is on 127.0.0.1 and will come back
      // -- from a restart, from the machine waking -- so the loop drops to a
      // slow reconnect cadence rather than stopping. Stopping is what left a
      // dead panel behind a live agent after every suspend.
      setState(pollFailures >= 3 ? 'reconnecting...' : 'retrying...');
    }
  }

  // -- pacing ------------------------------------------------------------------
  // The server echoes a keystroke in about 4ms. Everything a person feels as lag
  // is added on this side, so the loop is built to spend as little of it as
  // possible while still going quiet when nothing is happening.
  //
  // A CHAIN, NOT AN INTERVAL. setInterval fires whether or not the previous
  // request came back, so a slow round trip stacks requests that then race --
  // and each carries an `at` from before the last reply, so the same output
  // arrives twice. Each poll now schedules the next one after it finishes.
  //
  // THE DELAY ADAPTS. Idle, there is nothing to see and 250ms costs nothing.
  // Busy, output is arriving and the next poll should already be in flight. The
  // floor is 0 -- an immediate re-poll -- because when the agent is streaming,
  // the round trip itself is the pacing.
  const IDLE_DELAY = 250;
  const BUSY_DELAY = 0;
  // How long one poll may park server-side before answering empty. Under the
  // supervisor's own 25s cap; the page's fetch timeout rides 10s above it.
  const LONGPOLL_WAIT = 20000;
  let streaming = false;
  // How long output keeps the loop in its fast mode after the last byte, so a
  // pause between two chunks of the same response does not drop it back to idle.
  const BUSY_WINDOW = 900;

  let lastOutput = 0;
  let pollTimer = null;
  let pollInFlight = false;

  // A REPLY COUNTS ONLY IF NOTHING MOVED `at` WHILE IT FLEW. Both `poll` and
  // `input` answer with "everything since `at`", and `at` goes into the
  // request body -- so a keystroke sent while a poll is in flight asks the
  // same question twice, and both replies carry the same bytes. The harness
  // hides that: a full-screen program repaints with absolute positions, and
  // drawing a frame twice looks like drawing it once. The repl is a line
  // stream where every byte appends, so the duplicate echo was right there on
  // the screen: typing 2 printed 22.
  //
  // CONCURRENT, NOT SERIALIZED. An earlier fix put every request behind one
  // queue, which cured the doubling but queued each keystroke behind the
  // back-to-back polls of busy mode, and typing turned laggy. So requests fly
  // together and the first reply home wins: each remembers the (at,
  // generation) it asked about, and one that comes back to find them changed
  // is dropped whole. Dropping loses nothing -- the backlog is the record --
  // it only defers those bytes to the next poll, which re-fetches them from
  // the position the winner advanced to.
  function stale(askedAt, askedGen) {
    return at !== askedAt || generation !== askedGen;
  }

  const RECONNECT_DELAY = 2000;

  function scheduleNextPoll() {
    if (!polling) return;
    clearTimeout(pollTimer);
    // Streaming healthy: no timer at all. The next long-poll goes out on the
    // spot and parks server-side until there is something to say -- and a
    // DIRECT call rather than setTimeout(0) matters in a hidden tab, where
    // timers are clamped to a second but a fetch continuation still runs,
    // so output keeps flowing to a tab the user cannot currently see.
    if (streaming && pollFailures === 0) { pollTimer = null; runPoll(); return; }
    const delay = pollFailures >= 3 ? RECONNECT_DELAY
      : (performance.now() - lastOutput < BUSY_WINDOW ? BUSY_DELAY : IDLE_DELAY);
    pollTimer = setTimeout(runPoll, delay);
  }

  async function runPoll() {
    // One at a time. Overlapping polls send stale `at` values and duplicate
    // output onto the screen.
    if (pollInFlight || !polling) return;
    pollInFlight = true;
    try {
      await poll();
    } finally {
      pollInFlight = false;
      scheduleNextPoll();
    }
  }

  // Called the moment a keystroke is sent. The echo is the thing a person is
  // waiting for, so the poll that will carry it should not sit behind an idle
  // delay -- this is most of the difference between "instant" and "laggy".
  function pollSoon() {
    if (!polling) return;
    clearTimeout(pollTimer);
    pollTimer = setTimeout(runPoll, 0);
  }

  function startPolling() {
    if (polling) return;
    polling = true;
    runPoll();
  }

  function stopPolling() {
    if (!polling) return;
    polling = false;
    clearTimeout(pollTimer);
    pollTimer = null;
  }

  async function startSession() {
    const size = measure();
    term.resize(size.rows, size.cols);
    setState('starting...');
    try {
      const out = await post('start', size);
      generation = out.generation;
      at = 0;
      term.reset();
      setName(out.argv);
      setState('');
      startPolling();
      screen.focus();
    } catch (e) {
      setState('failed: ' + e.message);
    }
  }

  // Keystrokes go to the pty as bytes. The screen is focusable (tabindex in the
  // HTML) so this needs no input element -- a real one would fight the emulator
  // over what the cursor means.
  screen.addEventListener('keydown', (event) => {
    // Let copy through: a terminal you cannot copy out of is a terminal you
    // cannot use. Everything else belongs to the program.
    if ((event.metaKey || event.ctrlKey) && event.key === 'c'
        && window.getSelection().toString()) {
      return;
    }
    const bytes = keyToBytes(event);
    if (!bytes) return;
    event.preventDefault();
    event.stopPropagation();
    sendInput(bytes);
  });

  // Type, and draw whatever came back.
  //
  // THE ECHO RIDES HOME ON THE SAME REQUEST. Asking for it separately costs a
  // second round trip no matter how short the poll delay is, because the page
  // cannot start that second request until the first has returned -- and while
  // it waited, the scheduler was just as likely to have armed the idle timer.
  // This is the difference between a character appearing as you press the key
  // and appearing a quarter of a second later.
  // Keystrokes queue behind EACH OTHER and nothing else. Two fetches in
  // flight at once can reach the server swapped, and a pty that receives "eh"
  // types "eh" -- so inputs are ordered. But they do not wait for polls:
  // that wait, multiplied by busy mode's back-to-back polling, is what made
  // typing laggy. The queue is empty at human typing speed anyway; it only
  // fills when keys arrive faster than a localhost round trip.
  let inputTurn = Promise.resolve();
  function sendInput(text, quiet) {
    if (!text) return inputTurn;
    inputTurn = inputTurn.then(() => {
      const askedAt = at, askedGen = generation;
      const sentAt = performance.now();
      return post('input', quiet ? { text, at: askedAt, quiet: true }
                                 : { text, at: askedAt })
        .finally(() => {
          // The sensor the first stall report was missing: a hung input
          // fetch freezes the wheel pipeline (one batch in flight) with no
          // longtask and no poll gap -- invisible to both other sensors.
          const took = performance.now() - sentAt;
          if (took > 1500) diagNote('input-stall', took);
        })
        .then((out) => {
          if (!out || out.text === undefined) return;
          // A poll got home first with these same bytes; the echo is already
          // on the screen and this copy would be the doubled keystroke.
          if (stale(askedAt, askedGen)) { pollSoon(); return; }
          if (out.generation !== generation) {
            generation = out.generation;
            at = 0;
            term.reset();
          }
          // The same torn-stream guard as the poll path: an echo that
          // starts past our position lost bytes to the backlog cap.
          if (out.from > askedAt && askedAt > 0 && out.generation === askedGen) {
            term.reset();
            at = out.at;
            lastOutput = performance.now();
            post('redraw').catch(() => {});
          } else if (out.text) {
            term.write(out.text);
            at = out.at;
            lastOutput = performance.now();
          }
          // Whatever follows the echo -- a command's output, an agent's answer --
          // arrives on the polling loop, which is now in its fast mode.
          pollSoon();
        })
        .catch(() => {
          // The keystroke may have been lost; the poll loop is the arbiter of
          // whether the session is actually gone.
          setState('retrying...');
          pollSoon();
        });
    });
    return inputTurn;
  }

  // Paste, which a harness is used with constantly.
  screen.addEventListener('paste', (event) => {
    event.preventDefault();
    const text = event.clipboardData.getData('text');
    if (text) sendInput(text);
  });

  // THE WHEEL BELONGS TO THE PROGRAM WHEN THE PROGRAM ASKED FOR IT. Claude
  // turns on mouse tracking at startup and never scrolls the terminal -- a
  // 358KB capture of a session held not one newline -- so its history is not
  // in this pane's scrollback and never will be. It lives inside claude,
  // which repaints the transcript in place when a wheel report arrives,
  // exactly as it does in iTerm. Measured live: three SGR wheel-ups at the
  // pty and the transcript scrolled. With tracking off (the repl, a shell)
  // the wheel keeps scrolling the pane's own scrollback, and shift forces
  // that path the way real terminals do under a mouse-hungry program.
  // BATCHED, PACED BY COMPLETION, WITH A RATE FLOOR. A trackpad fires
  // dozens of wheel events a second and momentum keeps firing them after
  // the fingers stop. This corner has burned four designs, and the survivor
  // is the simplest that held up in use: at most one batch in flight, the
  // next leaving when the last one lands and never sooner than 30ms after
  // it -- a ceiling near 260 rows/s, above any rate a person can follow.
  // Deltas accumulate between batches (the carry keeps fractions from
  // rounding to nothing), clamped to a screenful; excess momentum is
  // dropped, never owed. A 2x gain tunes the per-tick feel toward iTerm.
  //
  // The two clever successors are recorded here so they are not rebuilt.
  // Pacing on the answering repaint (any changed, non-growing paint)
  // flooded the pty whenever the agent was WORKING -- its ticking status
  // line and streaming tokens are exactly such paints, and each one
  // released a batch. Pacing on the detected row SHIFT (see term.js, which
  // still reports it) was causally sound and still felt hung: when the
  // detector missed -- an unmatched frame, a program that scrolls more
  // than the probe range -- the fallback cadence crawled. A dumb bounded
  // rate degrades gently everywhere instead of sharply somewhere.
  // Reports go `quiet`: their answer arrives on the parked poll, so the
  // input reply's echo wait bought nothing. Coordinates are read in the
  // flush, off the hot path.
  const WHEEL_GAIN = 2;
  const WHEEL_GAP = 30;
  let wheelCarry = 0, wheelQueued = 0, wheelFlush = null, wheelInFlight = false;
  let wheelLastSend = 0;
  let wheelLast = { x: 0, y: 0 };
  function flushWheel() {
    if (wheelInFlight || wheelQueued === 0) return;
    const wait = wheelLastSend + WHEEL_GAP - performance.now();
    if (wait > 0) {
      if (wheelFlush === null) {
        wheelFlush = setTimeout(() => { wheelFlush = null; flushWheel(); }, wait);
      }
      return;
    }
    const n = Math.max(-8, Math.min(8, wheelQueued));
    wheelQueued -= n;
    const box = cellSize();
    const rect = screen.getBoundingClientRect();
    const col = Math.max(1, Math.min(term.cols, Math.floor((wheelLast.x - rect.left) / box.w) + 1));
    const row = Math.max(1, Math.min(term.rows, Math.floor((wheelLast.y - rect.top) / box.h) + 1));
    wheelInFlight = true;
    wheelLastSend = performance.now();
    sendInput(`\x1b[<${n < 0 ? 64 : 65};${col};${row}M`.repeat(Math.abs(n)), true)
      .finally(() => {
        wheelInFlight = false;
        flushWheel();
      });
  }
  screen.addEventListener('wheel', (event) => {
    if (!term.mouseReporting || event.shiftKey) return;
    event.preventDefault();
    // deltaMode 1 is already lines; 0 is pixels.
    wheelCarry += WHEEL_GAIN
      * (event.deltaMode === 1 ? event.deltaY : event.deltaY / cellSize().h);
    const n = Math.trunc(wheelCarry);
    wheelCarry -= n;
    wheelQueued = Math.max(-term.rows, Math.min(term.rows, wheelQueued + n));
    wheelLast = { x: event.clientX, y: event.clientY };
    if (wheelQueued !== 0) flushWheel();
  }, { passive: false });

  const termPanel = makePanel(root, {
    minWidth: 360, minHeight: 200,
    width: 'min(52rem, 94vw)', height: '24rem',
    onOpen: async () => {
      screen.focus();
      // A beat, so the panel's first-open default size has actually been laid
      // out -- measure() in the same tick as the opening click reads a
      // half-sized body and starts the session ~30 columns wide.
      //
      // A TIMER, NOT requestAnimationFrame. rAF does not fire while the tab is
      // hidden, so an onOpen that awaited a frame in a background tab -- the
      // panel reopening as the machine wakes, say -- suspended here forever:
      // no attach, no start, a state line saying nothing. The same
      // hidden-tab trap as the emulator's paint path, and the same fix.
      await new Promise(r => setTimeout(r, 50));
      // ATTACH TO A SESSION THAT IS ALREADY RUNNING, and only start one when
      // there is none. (The old test was `generation === 0` -- a fact about
      // THIS PAGE, not the server -- so a reload used to shoot the live agent
      // and replace it, and the first keystroke went to a dead shell.)
      try {
        const now = await post('poll', { at: 0, generation: 0 });
        // Unreachable is not "no session" -- starting here would shoot a live
        // agent the moment the supervisor came back. But ABSENT is: no socket
        // file means nothing has ever started, and starting is exactly what
        // opening the panel is for. Confusing the two the other way left a
        // fresh boot spinning at "reconnecting..." with nothing to reconnect
        // to.
        if (now.reachable === false && !now.absent) {
          setState('reconnecting...');
          startPolling();
          return;
        }
        if (now.running) {
          // REPLAY AT THE RECORDED GEOMETRY, NOT THE PANEL'S. The backlog is
          // bytes the program drew for a specific terminal size; absolute
          // cursor positions in it are meaningless in any other. Replaying a
          // Claude session into a fresh differently-sized grid was scattering
          // line fragments all over the reattached screen.
          generation = now.generation;
          term.reset();
          term.resize(now.rows || 24, now.cols || 80);
          // A TRIMMED HISTORY IS NOT REPLAYED. Once the backlog cap has eaten
          // the front, what remains starts mid-frame -- often mid-escape --
          // and painting it fills the scrollback with garbage the redraw
          // nudge cannot reach, because a TUI repaints its live rows and
          // nothing above them. Skipping the replay costs old scrollback and
          // buys a clean screen; the nudge below fills in the current frame.
          if (now.text && !now.trimmed) term.write(now.text);
          at = now.at;
          // NOW adapt to this panel: reflow the grid and tell the pty.
          const size = measure();
          if (term.resize(size.rows, size.cols)) {
            await post('resize', size).catch(() => {});
          }
          // And ask the program for one clean frame. The recording may have
          // been trimmed mid-frame by the backlog cap, and it may span old
          // geometries; a full-screen program repaints itself completely on
          // the resize nudge, painting over whatever the replay left. A
          // line-oriented program ignores it, which is also right.
          await post('redraw', {}).catch(() => {});
          // A SERVER FROM BEFORE TEAR REPORTING answers without `from`, and
          // the page then cannot tell a torn stream from an update -- the
          // exact silent degradation that once cost a whole debugging round
          // while every fix sat unrun on disk. Say so instead.
          setState(now.from === undefined || now.from < 0
            ? 'server outdated — restart ./visualize' : '');
          startPolling();
        } else {
          syncSize();
          startPolling();
          startSession();
        }
      } catch (e) {
        setState('disconnected');
      }
    },
    // Collapsed, the session keeps running -- it is a window, not a switch --
    // but polling a screen nobody can see is wasted traffic.
    onShut: () => stopPolling(),
    onResize: () => syncSize(),
  });

  // Tell the pty when the panel changes size, so the harness redraws to fit.
  // Debounced: a drag fires continuously, and a SIGWINCH per pixel would have
  // the harness redrawing its whole screen hundreds of times.
  let sizing = null;
  function syncSize() {
    cell = null;
    clearTimeout(sizing);
    sizing = setTimeout(() => {
      const size = measure();
      if (term.resize(size.rows, size.cols)) {
        post('resize', size).catch(() => {});
      }
    }, 150);
  }

  window.addEventListener('resize', () => { if (!termPanel.shut) syncSize(); });

  // COMING BACK -- from a suspend, a hidden tab, a dropped network -- restarts
  // the conversation immediately rather than waiting out whatever backoff the
  // gap left armed. Restart-not-just-poll: if the machine slept mid-request the
  // chain may have been wedged in ways the timeout is still unwinding, and
  // startPolling on a live loop is a no-op anyway.
  for (const signal of ['visibilitychange', 'focus', 'online']) {
    window.addEventListener(signal, () => {
      if (document.hidden || termPanel.shut || generation === 0) return;
      pollFailures = 0;
      startPolling();
      pollSoon();
    });
  }

  // A TAB HAS ITS TERMINAL FROM THE MOMENT IT EXISTS, whether or not anyone
  // has opened it. Starting on first open meant a new tab was an empty
  // promise until clicked -- and worse, a row of tabs you had made but not
  // looked at was a row of nothing, so walking them with alt started three
  // shells one after another while you were still looking.
  //
  // AT A DEFAULT GEOMETRY, because a shut panel has no size to measure: the
  // pty is told 24x80 to begin with, and `onOpen` reflows it to whatever the
  // panel turns out to be. A shell does not mind being resized; it is the
  // same thing that happens when a window is dragged.
  //
  // Nothing is polled yet. The backlog is the supervisor's, and it keeps
  // whatever the program writes until a panel opens and asks for it.
  // TYPED AT FROM OUTSIDE. The compose bar sends a whole command this way
  // when a terminal tab is the selected one -- the same path a keystroke
  // takes, so the echo and the polling need no special case.
  termPanel.type = (text) => { if (text) sendInput(text); };

  termPanel.boot = async () => {
    if (generation) return;                 // already has one
    try {
      const now = await post('poll', { at: 0, generation: 0 });
      // A session that is already running is one to leave alone -- this is
      // the reload case, and shooting it is exactly what the open path
      // learned not to do.
      // A session that is already running is one to leave alone, but its tab
      // still has to say what it is: a recovered pane arrives called
      // `terminal 3` and the session behind it has been running zsh for an
      // hour.
      if (now.running) {
        generation = now.generation;
        setProgram(now.program);
        return;
      }
      if (now.reachable === false && !now.absent) return;
      const out = await post('start', { rows: 24, cols: 80 });
      generation = out.generation;
      at = 0;
      setName(out.argv);
    } catch (e) { /* a tab that cannot start says so when it is opened */ }
  };

  // CLOSING THE TAB CLOSES THE SESSION. The route has always been there and
  // the page has never called it: shutting a panel only stopped polling,
  // because the pty was meant to outlive a reload. A tab being destroyed is
  // the other case -- nothing will ever ask about that session again, so the
  // supervisor is told to end it and go.
  termPanel.stop = async () => {
    stopPolling();
    try { await post('stop', {}); } catch (e) { /* it may already be gone */ }
    try { await post('shutdown', {}); } catch (e) { /* likewise */ }
  };

  return termPanel;
}

// ONE PANE, the agent harness. The driver is written against a prefix rather
// than an id because it once ran twice -- the second instance drove a pty
// onto this server's own repl, and went with the debugging rig. What is left
// is the pane the name describes.
const harnessPane = makeTerminalPane(document.getElementById('harness'), 'harness');


// -- more terminals ----------------------------------------------------------
//
// CTRL-T OPENS ANOTHER ONE. Panes are numbered, and the number is the whole
// address: it names the route the driver posts to and the socket the server
// keys a host by, so pane 2 finds pane 2's session again across a reload or a
// server restart -- the property the client/host split exists for.
//
// The panel is CLONED from the one in the page rather than written out again
// here. A second copy of that markup is a second place to change when the bar
// grows a button, and the two would drift.
let paneCount = 1;
const extraPanes = [];

// THE SELECTED TAB: the last one you chose, marked so the row says which
// terminal you are working in. Clicking a tab selects it, and so does making
// one -- a terminal you just asked for is the one you meant.
//
// A CLASS ON THE PANEL rather than a variable the stylesheet cannot see, and
// exactly one at a time: the mark answers "which one", and two of them
// answers nothing.
/* -- the tab bar -------------------------------------------------------------

   A RAIL WITH NO BODY. There is no element for it: it is a y coordinate and
   a height, and what it does is decide where a dropped tab lands. Drawing it
   would put a strip of furniture across the top of a drawing that is the
   point of the page -- so it is invisible until a tab is dragged near it,
   and then two orange lines fade in to say where it is.

   TABS ON IT ARE PACKED, left to right in order, each one against the last.
   A panel that grows -- a title changing from `terminal 3` to `zsh 3`, a new
   tab appearing -- pushes the ones after it along, and one that shrinks pulls
   them back. That is why the row is a list here rather than a set of
   remembered positions: positions go stale the moment a width changes, and
   an order does not.

   PULLED OUT BY DRAGGING AWAY. A tab dropped off the rail leaves the list
   and keeps whatever position the drag gave it; dropped back on, it rejoins
   at the slot it was over. */

// HOW FAR THE ROW IS SLID, in pixels, negative to see later tabs. Zero until
// there is something off-screen to reach.
let railScroll = 0;
// Where the row ends when unscrolled -- set by the packing, read to decide
// whether scrolling means anything.
let railEnd = 0;

// AGAINST THE TOP OF THE WINDOW. The row is furniture fixed to the edge of
// the page rather than something floating on the drawing, and an inset here
// left a band of graph above it that read as a gap it had fallen short of.
const RAIL_TOP = 0;
const RAIL_GRAB = 56;         // how near a drag has to come to count as "on"
// TABS OVERLAP BY THEIR SHARED BORDER. A tab starts on the very pixel the
// one before it drew its right edge in, so the two lines land on top of each
// other and read as the single line between the pair -- and which colour it
// comes out is settled by the stacking, the selected tab being above the
// rest. Advancing by the full width instead left the two edges side by side:
// a 2px rule between neighbours, twice the weight of every other line, and
// visibly two lines wherever one of them was green.
const TAB_GAP = -1;
// WHERE THE ROW STARTS: hard against the left edge, for the same reason. The
// corner marks keep their own inset -- they are single glyphs floating on
// the drawing, where this is a strip anchored to the top of it.
const RAIL_LEFT = 0;

// The tabs on the rail, in the order they sit. Panels not in here are the
// ones that have been pulled off.
const rail = [];

function onRail(panel) { return rail.includes(panel); }

// Lay the row out: every tab against the one before it, starting where the
// config's tab starts. Called whenever the list changes or a width does.
// HOW MUCH ROOM A TAB TAKES IN THE ROW. Shut, that is its bar and nothing
// else. OPEN, it is the whole panel: a window is far wider than the tab that
// opens it, and advancing by the bar alone let an opened pane lie across
// every tab after it -- so the one thing you could not do was open two
// neighbours and see both.
function railSpan(p) {
  // MEASURED IN FRACTIONS, not whole pixels. `offsetWidth` rounds, and a tab
  // is 43.63px wide -- so laying the row out on rounded widths left a third
  // of a pixel of background showing between one tab and the next, wherever
  // the rounding fell badly. getBoundingClientRect keeps the fraction and
  // the tabs meet exactly.
  const bar = p.root.querySelector('.bar').getBoundingClientRect().width;
  if (p.shut) return bar;
  // The body can be narrower than the bar on a short window; the row has to
  // clear whichever reaches further.
  return Math.max(bar, p.root.getBoundingClientRect().width);
}

// What the row measures, as a string, so a tick can tell whether anything
// moved without laying anything out. Spans rather than bar widths: opening a
// panel changes what it occupies without touching its bar.
function railShape() {
  return rail.map(railSpan).join(',');
}

function packRail() {
  // THE SCROLL CANNOT OUTLIVE WHAT IT WAS SCROLLING. Shutting a panel,
  // pulling a tab out, or a window that grew all make the row shorter -- and
  // a scroll left over from when it was longer holds the whole row off the
  // left edge with nothing out to the right to justify it. That is the tab
  // stuck where no scrolling brings it back: the row was already at its
  // stop, so scrolling right did nothing and there was nothing to the left
  // to scroll toward. Clamped here, where the row is measured anyway.
  if (railEnd) {
    const most = railOverflows() ? Math.min(0, (innerWidth - RAIL_LEFT) - railEnd) : 0;
    railScroll = Math.max(most, Math.min(0, railScroll));
  }
  let x = RAIL_LEFT + railScroll;
  railWidths = railShape();
  // WHICH TABS HAVE A NEIGHBOUR to their left, and so share a border with
  // it. Set here because this is what knows the order, and the order
  // changes whenever a tab is dragged.
  rail.forEach((p, i) => {
    // A TAB IN HAND IS NOT IN THE ROW. It is under the pointer, going
    // somewhere, and the row has already closed up behind it -- so it wears
    // neither the corner's rounding nor the pixel of overlap a neighbour
    // costs. Squaring on the first move rather than on the drop is what
    // makes picking it up feel like picking it up.
    const held = p.root === railDragging;

    // THE TAB IN THE CORNER, which is the leftmost one and only while the
    // row is scrolled home: scrolled along, the first tab is off the left
    // edge and whatever is under the corner is passing through rather than
    // sitting in it. See the rounding in style.css.
    p.root.classList.toggle('tab-corner', i === 0 && railScroll === 0 && !held);
  });
  for (const p of rail) {
    // Skip the one being dragged: it is under the pointer, not in the row,
    // and moving it would fight the hand.
    if (p.root === railDragging) {
      x += railSpan(p) + TAB_GAP;
      continue;
    }
    p.place(x, RAIL_TOP, true);
    x += railSpan(p) + TAB_GAP;
  }
  railEnd = x - TAB_GAP - railScroll;   // where the row ends, unscrolled
}

// SCROLLING THE ROW, and only when there is a reason to.
//
// THE LIMITS ARE THE ENDS, not a guess at how much is hidden: the row stops
// with its first tab at the left inset, and stops again with its last tab
// against the right edge. Between those it moves freely.
//
// NOTHING HAPPENS WHEN IT ALL FITS. A row shorter than the window has no
// off-screen part to bring into view, and sliding it then would just be a
// way to lose your tabs off the side.
function railOverflows() { return railEnd > innerWidth - RAIL_LEFT; }

function scrollRail(by) {
  if (!railOverflows()) {
    if (railScroll === 0) return false;
    railScroll = 0;                 // a window that grew: put the row back
    packRail();
    return true;
  }
  // How far left the row may slide: enough to bring its end to the right
  // edge, and no further.
  const most = Math.min(0, (innerWidth - RAIL_LEFT) - railEnd);
  const next = Math.max(most, Math.min(0, railScroll + by));
  if (next === railScroll) return false;
  railScroll = next;
  packRail();
  return true;
}

// BRING A TAB INTO VIEW, scrolling the row as little as it takes. Called
// when the keyboard moves the selection: walking to a tab that is off the
// side should show it, or the mark moves somewhere you cannot see and the
// row looks unchanged.
//
// SCROLLED TO ITS NEAR EDGE, not to the middle: a tab just past the right
// edge should come in from the right and stop, rather than the whole row
// jumping to centre it. The stops are `scrollRail`'s, so this cannot slide
// past either end.
function revealTab(panel) {
  if (!panel || !railOverflows()) return;
  const bar = panel.root.querySelector('.bar').getBoundingClientRect();
  // NO MARGIN ON THE LEFT. The row's own left stop is the window edge, so
  // asking to sit a few pixels inside it is asking for something the scroll
  // cannot give -- it goes as far as it can and leaves the tab that far
  // short, which is exactly the case this is meant to fix. A margin on the
  // right is fine: there is room to spare on that side.
  const right = innerWidth - 8;
  if (bar.left < RAIL_LEFT) scrollRail(RAIL_LEFT - bar.left);
  else if (bar.right > right) scrollRail(right - bar.right);
}

// A WHEEL OVER THE ROW, either axis. A trackpad swipe sideways arrives as
// deltaX and a mouse wheel as deltaY, and both mean the same thing here --
// there is one direction the row can go.
window.addEventListener('wheel', (e) => {
  // Only over the row itself: the graph owns the wheel everywhere else, and
  // taking it here would break zooming for the top of the page.
  if (e.clientY > RAIL_TOP + railHeight()) return;
  if (!railOverflows()) return;
  const by = Math.abs(e.deltaX) > Math.abs(e.deltaY) ? -e.deltaX : -e.deltaY;
  if (scrollRail(by)) e.preventDefault();
}, { passive: false });

// A window that changed size changes whether the row fits at all.
window.addEventListener('resize', () => { scrollRail(0); });

// WIDTHS CHANGE WITHOUT ANYONE DRAGGING ANYTHING -- a pane retitles itself
// when its session reports what it is running, and the tab grows or shrinks
// by however much that word differs.
//
// CHECKED ON A TICK rather than watched. A ResizeObserver on each bar is the
// obvious answer and was the first one; it does not fire for a bar whose own
// box never changes (the packing moves panels by `left`, which the observer
// has nothing to say about), and it is another thing that goes quiet in a
// hidden tab. Comparing the widths we last laid out against the widths that
// are there costs one offsetWidth per tab and cannot miss.
let railWidths = '';
function railChanged() {
  const now = railShape();
  if (now === railWidths) return false;
  railWidths = now;
  return true;
}
setInterval(() => { if (!railDragging && railChanged()) packRail(); }, 250);

function addToRail(panel, at) {
  if (onRail(panel)) return;
  rail.splice(at === undefined ? rail.length : at, 0, panel);
  packRail();
}

function removeFromRail(panel) {
  const at = rail.indexOf(panel);
  if (at < 0) return;
  rail.splice(at, 1);
  packRail();
  // THE MARKS OF BEING IN A ROW COME OFF WITH IT, and AFTER the packing:
  // `packRail` sets them on the tabs it lays out, and clearing them before
  // it runs leaves whatever it decides. A tab pulled onto the graph kept
  // the rounded corner it had while it was in the corner, and the pixel of
  // overlap it had while it had a neighbour.
  panel.root.classList.remove('tab-corner');
}

/* -- the bin ---------------------------------------------------------------

   WHERE A PANE GOES TO DIE. It appears in the bottom-left corner only while
   a tab is being dragged -- there is nothing to throw away the rest of the
   time, and a bin sitting on the drawing would be furniture. Held over, the
   lid comes off; let go, it eats what you were holding.

   The old-computer gesture, which is worth the pixels: dropping a thing into
   a bin says what will happen before it happens, where a button says it
   afterwards. */

const bin = document.createElement('div');
bin.id = 'bin';
bin.innerHTML =
  '<svg viewBox="0 0 48 52" aria-hidden="true">' +
  // The lid, hinged so it lifts off rather than fading.
  '<g class="lid"><rect x="6" y="8" width="36" height="6" rx="2"/>' +
  '<rect x="19" y="3" width="10" height="5" rx="2"/></g>' +
  // The can, with three ribs.
  '<path class="can" d="M9 17 h30 l-3 31 a3 3 0 0 1 -3 3 h-18 a3 3 0 0 1 -3 -3 z"/>' +
  '<g class="ribs"><line x1="18" y1="24" x2="17" y2="44"/>' +
  '<line x1="24" y1="24" x2="24" y2="44"/>' +
  '<line x1="30" y1="24" x2="31" y2="44"/></g>' +
  '</svg>';
document.body.appendChild(bin);

// Is the dragged panel's tab over the bin? THE BAR, not the panel: the bar
// is what the hand is holding, and a panel opened to half the screen would
// otherwise overlap the bin while being dragged nowhere near it.
function overBin(panel) {
  if (!bin.classList.contains('up')) return false;
  const b = panel.root.querySelector('.bar').getBoundingClientRect();
  const t = bin.getBoundingClientRect();
  return b.left < t.right && b.right > t.left && b.top < t.bottom && b.bottom > t.top;
}

// EATEN. The pane is destroyed the way the cross used to do it -- off the
// rail, out of the row, its session shut down -- with the lid clapping shut
// over it.
function binEat(panel) {
  // THE LID CLAPS SHUT ON WHAT IT ATE, which needs the bin to still be
  // there -- the drop takes it down, so this puts it back for as long as
  // the swallow lasts.
  bin.classList.add('up', 'fed');
  setTimeout(() => bin.classList.remove('up', 'fed'), 420);
  removeFromRail(panel);
  const at = extraPanes.indexOf(panel);
  if (at >= 0) extraPanes.splice(at, 1);
  // SELECTION CANNOT POINT AT SOMETHING IN THE BIN: alt would have nothing
  // to open and the row would show nothing marked.
  if (panel.root.classList.contains('picked')) selectPane(configPanel.root);
  packRail();
  if (panel.stop) panel.stop();
  panel.root.remove();
}

// Which panel is under the hand right now, or null. Held so the packing can
// leave it alone and the rails know to show themselves.
let railDragging = null;

// THE RAILS, drawn only while a tab is near them. Two lines rather than a
// box: the row has a top and a bottom and no ends, since it runs as far as
// there are tabs.
const railMarks = document.createElement('div');
railMarks.id = 'rail-marks';
railMarks.innerHTML = '<i></i><i></i>';
document.body.appendChild(railMarks);

function railHeight() {
  const anyBar = document.querySelector('.panel .bar');
  return anyBar ? anyBar.offsetHeight : 28;
}

function showRails(near) {
  railMarks.style.top = RAIL_TOP + 'px';
  railMarks.style.height = railHeight() + 'px';
  railMarks.classList.toggle('near', !!near);
}

// Is this panel's tab close enough to the rail to land on it?
function overRail(panel) {
  const bar = panel.root.querySelector('.bar').getBoundingClientRect();
  return Math.abs(bar.top - RAIL_TOP) <= RAIL_GRAB;
}

// WHERE IN THE ROW a dragged tab would land: before the first tab whose
// middle the pointer is past, which is the same rule the config rows use for
// dragging a line.
function slotFor(panel) {
  const bar = panel.root.querySelector('.bar').getBoundingClientRect();
  const mid = bar.left + bar.width / 2;
  const others = rail.filter(p => p !== panel);
  let at = others.length;
  for (let i = 0; i < others.length; i++) {
    const b = others[i].root.querySelector('.bar').getBoundingClientRect();
    if (mid < b.left + b.width / 2) { at = i; break; }
  }
  return at;
}

function railDrag(panel) {
  railDragging = panel.root;
  // OFF THE MOMENT IT IS PICKED UP. `packRail` clears these for the held tab
  // too, but it only runs when the drag is near the rail and changes slot --
  // a tab pulled straight down would keep its rounded corner all the way to
  // the drop. Cleared here, where every move passes.
  panel.root.classList.remove('tab-corner');
  // THE BIN COMES UP FOR ANYTHING THAT CAN GO IN IT. visualize cannot: it is
  // the page rather than a thing on it, and offering to throw the page away
  // is not an offer worth making. A pane knows it can be destroyed by having
  // a session to stop.
  bin.classList.toggle('up', !!panel.stop);
  bin.classList.toggle('open', overBin(panel));
  const near = overRail(panel);
  showRails(near);
  if (!near) return;
  // REORDER AS YOU GO, so the row shows where the tab will land rather than
  // making you drop it to find out. The dragged tab is skipped by the
  // packing, so this moves the others around it.
  const at = slotFor(panel);
  const was = rail.indexOf(panel);
  if (was >= 0 && was !== at) {
    rail.splice(was, 1);
    rail.splice(at, 0, panel);
    packRail();
  } else if (was < 0) {
    rail.splice(at, 0, panel);
    packRail();
  }
}

function railDrop(panel) {
  railDragging = null;
  railMarks.classList.remove('near');

  // DROPPED ON THE BIN is the way a pane is destroyed -- see overBin. Asked
  // BEFORE the bin is put away, since being over it is the thing being
  // asked about.
  const eaten = overBin(panel);
  bin.classList.remove('up', 'open');
  if (eaten) { binEat(panel); return; }

  if (overRail(panel)) {
    if (!onRail(panel)) addToRail(panel, slotFor(panel));
    packRail();
  } else {
    // PULLED OUT. It keeps where the drag left it -- that is what pulling a
    // tab out is for.
    removeFromRail(panel);
    // BUT IT HAS TO BE REACHABLE. On the rail a tab may sit far off the left
    // edge, because the row is scrolled and scrolling back is how it
    // returns; off the rail there is nothing to scroll, so a tab dropped out
    // there is lost -- no bar to grab and no way to bring it in. The drag
    // itself is placed freely, so this is the moment to put it back in
    // reach, and only in the direction it is actually stranded.
    const box = panel.root.getBoundingClientRect();
    const edge = 28;
    if (box.right < edge) panel.place(edge - box.width, box.top);
    else if (box.left > innerWidth - edge) panel.place(innerWidth - edge, box.top);
  }
}

// EVERY PANEL IS A TAB, the config among them. It is one of the things in
// the row, it is one of the things alt can open, and leaving it out made it
// a special case in both places for no reason a person looking at the row
// would guess.
function selectPane(root) {
  for (const p of document.querySelectorAll('.panel.picked')) {
    p.classList.remove('picked');
  }
  if (root) {
    root.classList.add('picked');
    // ON TOP, THE SAME WAY EVERYTHING ELSE GETS THERE. The tabs overlap by a
    // pixel so their shared border collapses into one line, and whichever
    // panel is higher paints it -- the selected one has to be. Through
    // `raise` rather than a number in the stylesheet: `raise` hands out
    // ever-larger values as panels are opened and dragged, so any fixed
    // number is one a neighbour eventually passes.
    raise(root);
  }
  // THE BAR FOLLOWS THE SELECTION, mid-sentence if need be. Its mode was
  // settled when it opened, so walking from the config to a terminal with
  // half a line typed left you writing shell into a box still wrapped in
  // parens and still offering config verbs -- and the other way round left a
  // config line in a box that would have sent it to a shell.
  //
  // Every path that changes the selection comes through here: a click, an
  // alt-walk, a tab closing.
  refitCompose();
}

// The panel that is selected right now, or the config when somehow none is.
// The panel object that is selected right now, or the config's when somehow
// none is.
function pickedPanel() {
  const root = document.querySelector('.panel.picked');
  return (root && panelsByRoot.get(root)) || configPanel;
}

// Clicking anywhere in a panel -- its tab, its screen, a config row -- is
// choosing it. On the panel rather than on the bar, so clicking into the
// thing to work in it counts as picking the thing you are working in.
document.addEventListener('pointerdown', (e) => {
  const inPanel = e.target.closest && e.target.closest('.panel');
  if (inPanel) selectPane(inPanel);
}, true);

// THE SHAPE OF A TERMINAL PANE, taken from the page once and kept. It used
// to be cloned from the live harness element every time, which was fine
// while that one could never be closed -- now that it can, a page with no
// terminals left would have nothing to copy.
const paneTemplate = (() => {
  const copy = document.getElementById('harness').cloneNode(true);
  // WITHOUT WHATEVER THE LIVE ONE HAS GROWN: this is taken after the first
  // pane was wired and has been painting, and a template is the markup
  // rather than the state.
  copy.querySelector('.screen').textContent = '';
  copy.querySelector('.state').textContent = '';
  copy.classList.remove('picked');
  return copy;
})();

// A PANE FOR AN ID THAT ALREADY HAS A SESSION. Everything openTerminal does
// except choosing the number and booting: the session is already running, so
// starting one would shoot it.
function reopenTerminal(id) {
  const pane = buildTerminal(id);
  addToRail(pane);
  // Not to start one -- there is one -- but to attach to it and read off
  // what it is running, which is what the tab says.
  pane.boot();
  return pane;
}

// THE PANEL AND ITS DRIVER, for an id. What happens to it afterwards is the
// caller's: a new pane starts a session, a recovered one already has one.
function buildTerminal(id) {
  const root = paneTemplate.cloneNode(true);
  root.id = 'pane-' + id;
  root.classList.add('shut');
  root.querySelector('.screen').textContent = '';
  root.querySelector('.state').textContent = '';
  root.querySelector('.name').textContent = 'terminal ' + id;
  // Cleared, so the panel starts at its own default size rather than
  // inheriting whatever the template was captured with.
  root.style.cssText = '';
  document.body.appendChild(root);

  const pane = makeTerminalPane(root, id);
  extraPanes.push(pane);
  return pane;
}

function openTerminal() {
  const id = String(++paneCount);
  const pane = buildTerminal(id);
  selectPane(pane.root);
  // SHUT, like every other panel starts. A new terminal is a tab you can
  // open, not a window that takes the screen the moment you ask for one.
  //
  // ON THE RAIL, at the end of the row -- the packing puts it against the
  // last tab and keeps it there however the ones before it change width.
  addToRail(pane);
  // Its terminal starts now, not when someone gets round to looking at it.
  pane.boot();
  return pane;
}

// CTRL-T EVERYWHERE BUT INSIDE A TERMINAL, where it is the shell's
// (transpose-chars) and the program should get the keys it expects.
//
// CMD-T ALWAYS, INCLUDING INSIDE ONE. Without a second way in, opening a
// pane focused its screen and every ctrl-t after the first went to the
// shell -- one terminal, and no way to ask for another without clicking
// away first. Cmd is the modifier to spend on it because the emulator
// already refuses it outright (see keyToBytes), so nothing is taken from
// the program that it ever had.
document.getElementById('term-new')
  .addEventListener('click', () => { openTerminal(); });

document.addEventListener('keydown', (e) => {
  if (e.key !== 't' && e.key !== 'T') return;
  if (e.altKey) return;
  const el = document.activeElement;
  const inTerm = !!(el && el.closest && el.closest('.term'));
  if (e.metaKey || (e.ctrlKey && !inTerm)) {
    e.preventDefault();
    openTerminal();
  }
}, true);

// BESIDE THE CONFIG'S TAB, not on top of it. Both panels are absolutely
// positioned, and a panel that was never placed sits at 0,0 -- which is
// exactly where the config bar already is. Measured rather than guessed at a
// constant: the config tab is as wide as the file it names, so a number
// written here would be wrong for every project but this one.
//
// After a frame, and after the config's own placement, for the same reason
// that one waits: a collapsed bar has no width to measure until layout runs.
// THE ROW, in the order it reads. Everything else about where these sit is
// the rail's business from here.
addToRail(configPanel);
addToRail(harnessPane);
harnessPane.boot();

// TABS FOR THE SESSIONS THAT SURVIVED. A pane's id is the whole address --
// the route the page posts to and the socket the server keys a host by -- so
// putting the tab back is enough to be talking to the same terminal again.
// The server has already checked that each one answers; see the recovery in
// core.janet.
//
// Shut, like any other tab: a page reloading is not a request to open four
// windows. The numbering carries on past the highest one restored, so a new
// pane cannot collide with a recovered one.
for (const id of (window.OPEN_TERMINALS || [])) {
  const n = Number(id);
  if (Number.isFinite(n) && n > paneCount) paneCount = n;
  reopenTerminal(String(id));
}

// SOMETHING IS ALWAYS SELECTED, because an unmarked row raises "which one is
// it then?" -- the question the mark exists to answer. The CONFIG to start
// with: it is the leftmost tab, it is what the page is for, and alt over a
// fresh page should open the thing you came to edit.
//
// OUTSIDE THE FRAME ABOVE. Placement genuinely needs a laid-out bar to
// measure, but this needs nothing -- and rAF does not fire in a hidden tab,
// so a page opened in the background came up with the wrong tab selected and
// stayed that way until something else moved it.
selectPane(panel);
