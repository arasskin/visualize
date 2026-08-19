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

const pane = document.getElementById('graph');
const zoomLabel = document.getElementById('zoom');
let zoomFade = null;
const MIN = 0.1, MAX = 10;
// `touched` tracks whether the user has moved the view themselves; an automatic
// refit must never discard a view they chose.
let scale = 1, tx = 0, ty = 0, touched = false;

function paint() {
  const svg = pane.querySelector('svg');
  if (!svg) return;
  svg.style.transform = `translate(${tx}px, ${ty}px) scale(${scale})`;
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
  paint();
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
  // The editor owns the keyboard while it has focus -- typing `(group ...)`
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
    hold.title = 'drag to reorder';

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
    const up = icon('↑', 'insert a line above', 'up');
    up.onclick = () => send('insert-above', i);
    const down = icon('↓', 'insert a line below', 'down');
    down.onclick = () => send('insert-below', i);
    const hash = icon('#', commented ? 'uncomment this line' : 'comment this line out', 'hash');
    hash.onclick = () => toggleComment(i);
    const del = icon('✕', 'delete this line', 'del');
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
        // A different set of files is a different shape, so start it framed
        // rather than under the previous view's pan -- EXCEPT when the
        // watcher redrew after an edit on disk AND the view is one someone
        // chose. Nobody asked for that redraw, and yanking the view away
        // from what they were looking at is the cost of a feature meant to
        // be invisible. `touched` already means exactly this: it is what
        // stops an automatic refit from discarding a chosen view.
        if (keepView && touched) paint(); else fit();
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

function makePanel(root, options = {}) {
  const bar = root.querySelector('.bar');
  const body = root.querySelector('.panel-body');
  const grip = root.querySelector('.grip');

  // Dragging the bar moves the panel; dragging the grip resizes it. Both are
  // the same gesture with a different thing on the end, so they share one
  // pointer-capture path.
  function grab(handle, onMove) {
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
      };
      handle.addEventListener('pointermove', move);
      handle.addEventListener('pointerup', drop);
      handle.addEventListener('pointercancel', drop);
    });
  }

  // Keep the panel reachable: at least a bar's worth has to stay on screen, or
  // it can be dragged somewhere it can never be grabbed again.
  function place(left, top) {
    const w = root.offsetWidth, edge = 28;
    root.style.left = Math.min(Math.max(left, edge - w), innerWidth - edge) + 'px';
    root.style.top = Math.min(Math.max(top, 0), innerHeight - edge) + 'px';
  }

  grab(bar, (dx, dy, from) => place(from.left + dx, from.top + dy));
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

// Start under the header, top-left. After a frame, so the collapsed bar has a
// real width to clamp against -- measuring before layout puts it elsewhere.
requestAnimationFrame(() => configPanel.place(12, 60));

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


// The field is as wide as its text, so the closing paren sits just after
// what you wrote rather than at the far edge of the box. Width in `ch`
// rather than the `size` attribute, because `size` is a hint the flex
// layout can overrule -- and it did, letting a long line push the closing
// paren out through the border.
function sizeCompose() {
  const n = Math.max(1, composeInput.value.length);
  composeInput.style.width = n + 'ch';
}

function openCompose(seed) {
  compose.classList.remove('shut');
  composeFault.textContent = '';
  composeInput.value = seed || '';
  sizeCompose();
  composeInput.focus();
  // Caret after the seeded character rather than before it.
  const end = composeInput.value.length;
  composeInput.setSelectionRange(end, end);
}

function shutCompose() {
  compose.classList.add('shut');
  composeInput.value = '';
  composeFault.textContent = '';
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

composeInput.addEventListener('input', sizeCompose);

composeInput.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') { e.preventDefault(); commitCompose(); }
  else if (e.key === 'Escape') { e.preventDefault(); shutCompose(); }
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
  if (!down && !up && !del && !comment && !fresh) return false;
  e.preventDefault();
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
    if (altDown) { altUsed = true; altChord(e); }
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
  altOpened = configPanel.shut;
  // Opening on the way DOWN, so a hold shows the config for as long as it is
  // held. A tap over an open panel closes it instead -- see the keyup, which
  // is where a tap is finally told from a hold.
  if (altOpened) configPanel.open();
}, true);

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

  if (held) {
    // A HOLD IS A PEEK: it puts away what it put up, and leaves alone what
    // was already there.
    if (altOpened) configPanel.toggle();
    restore();
    return;
  }
  // A TAP IS A TOGGLE. Pressing down already opened a shut panel, so that
  // half is done; tapping over one that was open is what closes it.
  if (!altOpened) configPanel.toggle();
  restore();
});

window.addEventListener('blur', () => {
  if (altDown && altOpened) configPanel.toggle();
  altDown = false;
});
