// The find bar: type a name, jump to it, point at it with a big red arrow.
//
// WHAT IT NEEDS FROM ELSEWHERE is imported where the dependency runs one way
// and taken as a hook where it would run both. The viewport calls back into
// here after every repaint and every fit -- the arrow is drawn in screen
// pixels so a zoom has to replace it, and a zoom can carry the mark off the
// edge -- and this reads the viewport's transform to place the arrow. Those
// two are wired by app.js at startup rather than imported in a circle.

import { pane, scale, view, repaint, panBy } from './graph.js';

// Set by `wire`: the page's parts this needs but must not import.
let deps = {
  moduleNames: () => [],
  help: null,
  shutHelp: () => {},
  rank: () => [],
  prefixCandidates: () => [],
  compose: null,
  lines: () => [],
  rows: null,
};

export function wire(parts) { Object.assign(deps, parts); }

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

export const find = document.getElementById('find');
const findInput = document.getElementById('find-input');
const findCount = document.getElementById('find-count');

// The current hits, and where in them we are. Held rather than recomputed on
// Enter: the list must not reorder under the cursor while stepping through
// it, the same reason the completion list freezes during ctrl-n.
export let hits = [];
let hitAt = 0;

function finding() { return !find.classList.contains('shut'); }

// A node matches on either name it has: the dotted key (`src.visualize.scan`)
// or the label as drawn, which is the key minus whatever prefix an alias
// replaced. Typing what you SEE has to work, and so does typing the full
// path -- they differ whenever a `prefix` is in play.
function searchNodes(query) {
  const svg = pane.querySelector('svg');
  if (!svg || !query) return [];
  const names = deps.moduleNames(svg);
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
export function placeArrow() {
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
// svg, and reading a CTM forces layout. Cleared whenever the svg is replaced
// -- by `forgetUnit` below, because an imported binding is READ-ONLY at the
// far end: app.js assigning `unitCache = 0` after a redraw could never have
// worked, and threw "unitCache is not defined" instead, taking the redraw
// with it.
let unitCache = 0;

// The svg was replaced, so the measurement taken from the old one is void.
export function forgetUnit() { unitCache = 0; }
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
  panBy((view.left + view.width / 2) - (aim.left + aim.width / 2),
        (view.top + view.height / 2) - (aim.top + aim.height / 2));
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
export function keepHitInView() {
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
  if (deps.help && !deps.help.classList.contains('shut')) deps.shutHelp();
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
  findItems = finding() ? deps.rank(deps.prefixCandidates(), typed) : [];
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
export function redrawFind() {
  if (finding() && findInput.value.trim()) runFind();
}



