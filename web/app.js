// The page: pan and zoom over the graph, a line editor for the config, and
// terminal panes -- one running an agent harness, one the dev repl.
//
// Vanilla, no build step, no framework. Three parts that barely talk to each
// other -- the viewport, the editor, and the terminals -- joined only by the
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

// -- the terminal panes ------------------------------------------------------
// A pty on the server, an emulator here, and a poll loop between them. Polled
// rather than streamed: the page has to POST keystrokes regardless, so one
// endpoint returning "everything since chunk N" is both the live path and the
// catch-up path for a reload. An SSE stream would need a second mechanism for
// input and a way to resume when it drops.
//
// Written once and instantiated twice: the agent harness and the dev repl are
// the same pane speaking to different endpoint prefixes -- /harness/* drives
// the supervisor's agent pty, /repl/* a pty running ./repl against this
// server's own image. Nothing in here knows which one it is.

function makeTerminalPane(root, prefix) {
  const stateLine = root.querySelector('.state');
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
    onPaint: (lines, changed, shift) => {
      const grew = lines !== paintedLines;
      paintedLines = lines;
      if (grew && following) paneBody.scrollTop = paneBody.scrollHeight;
      // A paint whose rows MOVED is a program answering scroll reports;
      // one that merely changed is an agent working. Only the first
      // releases the next batch -- see the wheel pacing below, and the
      // shift detector in term.js for how the two are told apart.
      if (shift !== 0) wheelBatchDone();
    },
  });
  let at = 0;              // how much of the session output we have consumed
  let polling = false;     // is the loop running? (see scheduleNextPoll)
  let pollFailures = 0;    // consecutive misses; three in a row means gone
  let generation = 0;      // bumped server-side per start, so a restart resets us

  // Every terminal request carries the token; without it the server answers 403.
  // See `permitted?` in visualize.janet for why localhost alone is not enough.
  async function post(path, body = {}, timeoutMs = 15000) {
    // THE TIMEOUT IS WHAT SURVIVES A SUSPEND. A fetch that is in flight when
    // the machine sleeps can come back neither resolved nor rejected, and the
    // poll chain -- guarded by pollInFlight -- then waits on it forever: no
    // polls, no error, a cursor still blinking because the blink is CSS. An
    // aborted request rejects like any failure and lands in the retry path.
    const response = await fetch(`/${prefix}/${path}?k=${encodeURIComponent(window.TOKEN)}`, {
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
      if (out.text) {
        term.write(out.text);
        at = out.at;
        // Output just arrived, so the next poll should be immediate: an agent
        // mid-response has more coming, and this is what keeps streaming smooth
        // rather than stepping along at the idle delay.
        lastOutput = performance.now();
        // Following the output happens in the emulator's onPaint, once the
        // new height exists to scroll to.
      }
      setState(out.running ? '' : 'exited');
      if (!out.running) stopPolling();
      pollFailures = 0;
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
      return post('input', quiet ? { text, at: askedAt, quiet: true }
                                 : { text, at: askedAt })
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
          if (out.text) {
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
  // BATCHED, AND PACED BY THE ANSWERING REPAINT. A trackpad fires dozens of
  // wheel events a second and momentum keeps firing them after the fingers
  // stop. Three pacing designs died here, each teaching the next: a report
  // per event flooded the wire; a 16ms timer outran the server's input
  // turnaround and banked seconds of backlog CLIENT-side; and pacing by our
  // own POST completion (~3ms once reports went quiet) just moved the
  // backlog across the pty -- WE finished sending instantly while claude
  // consumed reports at its own repaint rate, and its stdin held the queue
  // that kept scrolling after the fingers stopped.
  //
  // The consumer sets the pace, and the consumer speaks -- but only one
  // signal it sends is trustworthy. The fourth design paced on any changed,
  // non-growing paint, and hung WORSE than the third: an agent at work
  // repaints in place constantly (a ticking status line, streaming tokens),
  // every such paint released another batch, and the flood returned with a
  // bigger budget behind it. The signal that cannot lie is the SHIFT: a
  // program answering scroll reports moves existing rows to new indices,
  // and nothing else does that. A shifted paint (term.js detects the
  // dominant row displacement) releases the next batch; a 250ms backstop
  // covers a program with nothing to answer -- at the top of its
  // transcript, say -- where nothing is moving anyway.
  //
  // Deltas accumulate between batches (the carry keeps fractions from
  // rounding to nothing), with two screenfuls of momentum budget and a 2x
  // gain, tuned against iTerm's feel. Excess beyond the budget is dropped,
  // never owed. Reports go `quiet`: their answer arrives on the parked
  // poll, so the input reply's echo wait bought nothing. Coordinates are
  // read in the flush, off the hot path.
  const WHEEL_GAIN = 2;
  let wheelCarry = 0, wheelQueued = 0, wheelFlush = null;
  let wheelAwait = null;   // backstop timer while a batch awaits its repaint
  let wheelLast = { x: 0, y: 0 };
  function wheelBatchDone() {
    if (wheelAwait === null) return;
    clearTimeout(wheelAwait);
    wheelAwait = null;
    flushWheel();
  }
  function flushWheel() {
    if (wheelAwait !== null || wheelQueued === 0) return;
    const n = Math.max(-8, Math.min(8, wheelQueued));
    wheelQueued -= n;
    const box = cellSize();
    const rect = screen.getBoundingClientRect();
    const col = Math.max(1, Math.min(term.cols, Math.floor((wheelLast.x - rect.left) / box.w) + 1));
    const row = Math.max(1, Math.min(term.rows, Math.floor((wheelLast.y - rect.top) / box.h) + 1));
    wheelAwait = setTimeout(wheelBatchDone, 250);
    sendInput(`\x1b[<${n < 0 ? 64 : 65};${col};${row}M`.repeat(Math.abs(n)), true);
  }
  screen.addEventListener('wheel', (event) => {
    if (!term.mouseReporting || event.shiftKey) return;
    event.preventDefault();
    // deltaMode 1 is already lines; 0 is pixels.
    wheelCarry += WHEEL_GAIN
      * (event.deltaMode === 1 ? event.deltaY : event.deltaY / cellSize().h);
    const n = Math.trunc(wheelCarry);
    wheelCarry -= n;
    const budget = 2 * term.rows;
    wheelQueued = Math.max(-budget, Math.min(budget, wheelQueued + n));
    wheelLast = { x: event.clientX, y: event.clientY };
    // One short timer coalesces the burst a single gesture-frame delivers;
    // after it, answering repaints drive the cadence.
    if (wheelFlush !== null || wheelAwait !== null || wheelQueued === 0) return;
    wheelFlush = setTimeout(() => { wheelFlush = null; flushWheel(); }, 16);
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
          setState('');
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

  return termPanel;
}

const harnessPane = makeTerminalPane(document.getElementById('harness'), 'harness');
// Under the config panel to start with, so both are visible at once.
requestAnimationFrame(() => harnessPane.place(12, 104));

// The repl pane exists only when the server hosts a repl to connect to -- a
// window onto nothing would open, fail to start, and say "failed" about a
// feature the run deliberately turned off.
const replRoot = document.getElementById('repl');
if (window.DEV) {
  const replPane = makeTerminalPane(replRoot, 'repl');
  // Stacked under the harness bar, so all three bars read as a stack.
  requestAnimationFrame(() => replPane.place(12, 148));
} else {
  replRoot.remove();
}
