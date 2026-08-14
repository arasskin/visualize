// The page: pan and zoom over the graph, a line editor for the config, and a
// terminal running an agent harness.
//
// Vanilla, no build step, no framework. Three parts that barely talk to each
// other -- the viewport, the editor, and the terminal -- joined only by the
// panel furniture they share.

import { makeTerminal, keyToBytes } from './term.js';

// -- the viewport ------------------------------------------------------------
// One transform on the <svg> element does the whole job. Not an iframe: the
// graph has to stay in this document for a redraw to swap it, and a same-origin
// frame would only add a postMessage hop. graphviz output is vector, so it
// stays sharp at any scale.

const pane = document.getElementById('graph');
const zoomLabel = document.getElementById('zoom');
const MIN = 0.1, MAX = 10;
// `touched` tracks whether the user has moved the view themselves; an automatic
// refit must never discard a view they chose.
let scale = 1, tx = 0, ty = 0, touched = false;

function paint() {
  const svg = pane.querySelector('svg');
  if (!svg) return;
  svg.style.transform = `translate(${tx}px, ${ty}px) scale(${scale})`;
  zoomLabel.textContent = Math.round(scale * 100) + '%';
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
  // Measure the element's own untransformed size, NOT getBBox(): graphviz
  // sizes the root svg in POINTS (width="2276pt"), so the box it actually
  // occupies is the pt->px conversion of that, ~4/3 larger than the user units
  // getBBox reports. Centring against the bbox would offset the graph by that
  // ratio. baseVal.value is already in px.
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

document.getElementById('fit').onclick = fit;
// Drops the cached scan, so the next draw re-reads the sources. The one action
// that is about the SOURCE changing rather than the config.
document.getElementById('regen').onclick = () => send('regenerate', -1);

document.addEventListener('keydown', (e) => {
  // The editor owns the keyboard while it has focus -- typing `(group ...)`
  // must not also zoom the graph.
  if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') return;
  const c = { x: pane.clientWidth / 2, y: pane.clientHeight / 2 };
  if (e.key === '0') fit();
  else if (e.key === '+' || e.key === '=') zoomAt(1.2, c.x, c.y);
  else if (e.key === '-') zoomAt(1 / 1.2, c.x, c.y);
});

// Two frames: the pane is absolutely positioned, so its height is only real
// after layout -- fitting any earlier measures against a collapsed box and
// bottoms out at the minimum scale.
function fitSoon() { requestAnimationFrame(() => requestAnimationFrame(fit)); }

// -- hovering a dependency ---------------------------------------------------
// Which file does this line come from, and where does it go? graphviz answers
// that in each edge's <title>, but only as a native tooltip on a 1px target.
// This makes the target fat and the answer visible.

// The MANGLED node name back to a readable one. Not derivable: the name is the
// path with separators replaced by underscores, so OttoClip_Cart could be
// OttoClip/Cart.swift or OttoClip_Cart.swift and nothing in the name says
// which. The node's own label does say, though -- graphviz wraps it across
// <text> runs, so join the runs and drop a trailing line count.
function moduleNames(svg) {
  const byNode = new Map();
  for (const node of svg.querySelectorAll('g.node')) {
    const key = node.querySelector('title');
    if (!key) continue;
    const runs = [...node.querySelectorAll('text')].map(t => t.textContent.trim());
    // The show-lines view appends a count as its own run. Only a run that is
    // ALL digits (or 1.3k) goes -- a file could legitimately end in a number.
    if (runs.length > 1 && /^[\d.]+k?$/.test(runs[runs.length - 1])) runs.pop();
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
    // Take graphviz's <title> for ourselves and REMOVE it -- see showEdge.
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

function icon(glyph, title, cls) {
  const b = document.createElement('button');
  b.textContent = glyph;
  b.title = title;
  b.className = cls;
  b.disabled = busy;
  return b;
}

function draw() {
  rows.replaceChildren();
  lines.forEach((text, i) => {
    const row = document.createElement('div');
    const commented = text.trim().startsWith(';') || text.trim().startsWith('#');
    row.className = 'row' + (commented ? ' comment' : '');

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
    box.onkeydown = (e) => {
      if (e.key === 'Enter') { e.preventDefault(); send('run', i); }
    };

    const up = icon('↑', 'insert a line above', 'up');
    up.onclick = () => send('insert-above', i);
    const down = icon('↓', 'insert a line below', 'down');
    down.onclick = () => send('insert-below', i);
    const del = icon('✕', 'delete this line', 'del');
    del.onclick = () => send('delete', i);

    // No run button: every action re-runs the whole file anyway, so a per-line
    // one promised a granularity that never existed. Enter in the field is
    // what commits a typed edit.
    row.append(box, up, down, del, hold);

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
  // Order changes what the file does -- a group's colour claimed earlier, or a
  // (hide) reaching a file before the (group) that would have boxed it -- so
  // this redraws.
  send('reorder', -1);
}

// One shape for every button: what to do, and which line to do it to. The
// server edits the file, re-runs it, and returns both the new lines and the new
// graph -- so the page never has to guess what the file now says.
async function send(action, index) {
  if (busy) return;
  busy = true;
  draw();
  // Inserting only saves; saying 'drawing' would be a lie, and the request
  // comes back too fast for the message to be read anyway.
  const draws = action !== 'insert-above' && action !== 'insert-below';
  status.textContent = draws ? 'drawing...' : 'saving...';
  const t0 = performance.now();
  try {
    const r = await fetch('/config', {
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
        // rather than under the previous view's pan.
        fit();
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
                     left: box.left, top: box.top };
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
  onOpen: () => body.querySelector('input')?.focus(),
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

// -- the harness terminal ----------------------------------------------------
// A pty on the server, an emulator here, and a poll loop between them. Polled
// rather than streamed: the page has to POST keystrokes regardless, so one
// endpoint returning "everything since chunk N" is both the live path and the
// catch-up path for a reload. An SSE stream would need a second mechanism for
// input and a way to resume when it drops.

const harnessRoot = document.getElementById('harness');
const harnessState = document.getElementById('harness-state');
const screen = document.getElementById('screen');

const term = makeTerminal(screen);
let at = 0;              // how much of the harness output we have consumed
let polling = false;     // is the loop running? (see scheduleNextPoll)
let generation = 0;      // bumped server-side per start, so a restart resets us

// Every terminal request carries the token; without it the server answers 403.
// See `permitted?` in visualize.janet for why localhost alone is not enough.
async function harnessPost(path, body = {}) {
  const response = await fetch(`/harness/${path}?k=${encodeURIComponent(window.TOKEN)}`, {
    method: 'POST',
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error(await response.text());
  return response.json();
}

// How many rows and columns fit the panel right now. Measured from a real
// character rather than assumed: the monospace face and its size come from
// CSS, so hardcoding a cell size here would break the moment either changed.
function measure() {
  const probe = document.createElement('span');
  probe.textContent = 'M';
  probe.style.cssText = 'position:absolute;visibility:hidden;white-space:pre';
  screen.appendChild(probe);
  const box = probe.getBoundingClientRect();
  probe.remove();
  const body = harnessRoot.querySelector('.panel-body');
  const cw = box.width || 7, ch = box.height || 16;
  return {
    rows: Math.max(4, Math.floor((body.clientHeight - 24) / ch)),
    cols: Math.max(20, Math.floor((body.clientWidth - 12) / cw)),
  };
}

function setState(text) { harnessState.textContent = text; }

async function poll() {
  try {
    // The generation says which session `at` counts chunks in. Without it a
    // restarted agent leaves the page asking about chunks that no longer
    // exist, and the reply is empty forever.
    const out = await harnessPost('poll', { at, generation });
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
    if (out.text) {
      term.write(out.text);
      at = out.at;
      // Output just arrived, so the next poll should be immediate: an agent
      // mid-response has more coming, and this is what keeps streaming smooth
      // rather than stepping along at the idle delay.
      lastOutput = performance.now();
      // Follow the output, the way a terminal does.
      const body = harnessRoot.querySelector('.panel-body');
      body.scrollTop = body.scrollHeight;
    }
    setState(out.running ? '' : 'exited');
    if (!out.running) stopPolling();
  } catch (e) {
    setState('disconnected');
    stopPolling();
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
// How long output keeps the loop in its fast mode after the last byte, so a
// pause between two chunks of the same response does not drop it back to idle.
const BUSY_WINDOW = 900;

let lastOutput = 0;
let pollTimer = null;
let pollInFlight = false;

function scheduleNextPoll() {
  if (!polling) return;
  clearTimeout(pollTimer);
  const busy = performance.now() - lastOutput < BUSY_WINDOW;
  pollTimer = setTimeout(runPoll, busy ? BUSY_DELAY : IDLE_DELAY);
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

async function startHarness() {
  const size = measure();
  term.resize(size.rows, size.cols);
  setState('starting...');
  try {
    const out = await harnessPost('start', size);
    generation = out.generation;
    at = 0;
    term.reset();
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
  harnessPost('input', { text: bytes }).catch(() => setState('disconnected'));
  // Do not wait for the next scheduled poll to see the echo. A keystroke is
  // the one moment a person is actively watching for a response, and sitting
  // behind an idle delay is most of what "laggy" means here.
  pollSoon();
});

// Paste, which a harness is used with constantly.
screen.addEventListener('paste', (event) => {
  event.preventDefault();
  const text = event.clipboardData.getData('text');
  if (text) harnessPost('input', { text }).catch(() => {});
  pollSoon();
});

const harnessPanel = makePanel(harnessRoot, {
  minWidth: 360, minHeight: 200,
  width: 'min(52rem, 94vw)', height: '24rem',
  onOpen: async () => {
    screen.focus();
    syncSize();
    // ATTACH TO A SESSION THAT IS ALREADY RUNNING, and only start one when
    // there is none.
    //
    // The old test was `generation === 0`, which is a fact about THIS PAGE,
    // not about the server. After a reload the page's generation is 0 again
    // while the supervisor is still running the agent -- so opening the panel
    // killed the live session and replaced it. That is what "the first
    // keystroke lags" turned out to be: the keystroke went to a shell that
    // had just been shot, and nothing said so.
    startPolling();
    try {
      const now = await harnessPost('poll', { at, generation });
      if (now.running) {
        // Somebody else's session -- ours from before the reload. Take it.
        generation = now.generation;
        setState('');
      } else {
        startHarness();
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
  clearTimeout(sizing);
  sizing = setTimeout(() => {
    const size = measure();
    if (term.resize(size.rows, size.cols)) {
      harnessPost('resize', size).catch(() => {});
    }
  }, 150);
}

window.addEventListener('resize', () => { if (!harnessPanel.shut) syncSize(); });

// Under the config panel to start with, so both are visible at once.
requestAnimationFrame(() => harnessPanel.place(12, 104));
