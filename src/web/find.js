import { pane, scale, panBy, drawing, renderedScale, screenBounds, selectGraphNode } from './graph.js';

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

export const find = document.getElementById('find');
const findInput = document.getElementById('find-input');
const findCount = document.getElementById('find-count');

export let hits = [];
let hitAt = 0;

function finding() { return !find.classList.contains('shut'); }

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

    const starts = key.toLowerCase().startsWith(needle) ||
                   label.toLowerCase().startsWith(needle);
    found.push({ node, key, label, rank: (starts ? 0 : 1) * 1000 + key.length });
  }
  found.sort((a, b) => a.rank - b.rank);
  return found;
}

function centreOf(node) {
  const shape = node.querySelector('ellipse, polygon, path');
  if (!shape) return null;
  const b = shape.getBBox();
  return { x: b.x + b.width / 2, y: b.y + b.height / 2, w: b.width, h: b.height };
}

function approachFor(svg, target, node) {
  const others = [...svg.querySelectorAll('g.node')]
    .filter(n => n !== node)
    .map(centreOf)
    .filter(Boolean);

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

  const reach = (96 + Math.max(target.w, target.h) * 0.35) / zoomNow() + edgeOf(target);
  let best = null;
  for (let i = 0; i < 8; i++) {
    const angle = (i / 8) * Math.PI * 2;
    const tail = {
      x: target.x + Math.cos(angle) * reach,
      y: target.y + Math.sin(angle) * reach
    };

    let worst = Infinity;
    for (let t = 0.15; t <= 1; t += 0.15) {
      const px = tail.x + (target.x - tail.x) * t;
      const py = tail.y + (target.y - tail.y) * t;
      for (const o of others) {
        const dx = Math.abs(px - o.x) - o.w / 2;
        const dy = Math.abs(py - o.y) - o.h / 2;
        worst = Math.min(worst, Math.max(dx, dy));
      }

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

function edgeOf(t) { return Math.max(t.w, t.h) / 2; }

function zoomNow() { return scale || 1; }

let lastArrowKey = null;

function clearArrow() {
  lastArrowKey = null;
  const old = pane.querySelector('#find-arrow');
  if (old) old.remove();
  selectGraphNode(null, null);
}

function drawArrow(hit) {

  const settled = lastArrowKey === hit.key;
  clearArrow();
  const svg = pane.querySelector('svg');
  if (!svg || !hit) return;
  const target = centreOf(hit.node);
  if (!target) return;

  const host = svg.querySelector('g.graph') || svg.querySelector('g') || svg;
  const aim = approachFor(svg, target, hit.node);

  const rx = target.w / 2, ry = target.h / 2;
  const ca = Math.cos(aim.angle), sa = Math.sin(aim.angle);
  const edge = (rx * ry) / Math.hypot(ry * ca, rx * sa);

  const g = document.createElementNS(ARROW_NS, 'g');
  g.setAttribute('id', 'find-arrow');
  g.setAttribute('pointer-events', 'none');

  const L = 96;
  const HEAD = 22, SPREAD = 0.38;
  const meet = HEAD * Math.cos(SPREAD);

  const shaft = document.createElementNS(ARROW_NS, 'line');
  shaft.setAttribute('class', 'find-shaft');
  shaft.setAttribute('x1', L);
  shaft.setAttribute('y1', 0);

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

  g.dataset.x = target.x + ca * edge;
  g.dataset.y = target.y + sa * edge;
  g.dataset.deg = (aim.angle * 180) / Math.PI;
  if (settled) g.classList.add('settled');
  host.append(g);
  lastArrowKey = hit.key;
  placeArrow();
  selectGraphNode(hit.node, g);
}

export function placeArrow() {
  const g = pane.querySelector('#find-arrow');
  if (!g) return;
  const k = 1 / ((renderedScale() || 1) * unitPx());
  g.setAttribute('transform',
    `translate(${g.dataset.x} ${g.dataset.y}) rotate(${g.dataset.deg}) scale(${k})`);
  selectGraphNode(hits[hitAt]?.node || null, g);
}

let unitCache = 0;

export function forgetUnit() { unitCache = 0; }
function unitPx() {
  if (unitCache) return unitCache;
  const current = drawing();
  if (!current) return 1;
  unitCache = current.unit;
  return unitCache;
}

function revealHit(hit) {
  const svg = pane.querySelector('svg');
  if (!svg || !hit) return;
  const node = screenBounds(hit.node);
  const arrow = pane.querySelector('#find-arrow');

  let box = node;
  if (arrow) {
    const a = screenBounds(arrow);
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

  const fits = box.width < view.width - margin * 2 &&
               box.height < view.height - margin * 2;
  const aim = fits ? box : node;

  panBy((view.left + view.width / 2) - (aim.left + aim.width / 2),
        (view.top + view.height / 2) - (aim.top + aim.height / 2));
}

function search() {
  const query = findInput.value.trim();
  hits = searchNodes(query);
  hitAt = 0;
  if (!query) {
    findCount.textContent = '';
    find.classList.remove('empty');
    clearArrow();
    return false;
  }
  if (!hits.length) {
    findCount.textContent = 'no match';
    find.classList.add('empty');
    clearArrow();
    return false;
  }
  find.classList.remove('empty');
  findCount.textContent = hits.length > 1 ? `${hitAt + 1}/${hits.length}` : '';
  return true;
}

function runFind() {
  if (search()) showHit();
}

function showHit() {
  const hit = hits[hitAt];
  if (!hit) return;
  findCount.textContent = hits.length > 1 ? `${hitAt + 1}/${hits.length}` : '';
  drawArrow(hit);
  revealHit(hit);
}

function stepHit(by) {
  if (!hits.length) return;

  if (hits.length > 1) {

    hitAt = (hitAt + by + hits.length) % hits.length;
  }
  showHit();
}

function openFind() {
  if (deps.help && !deps.help.classList.contains('shut')) deps.shutHelp();
  find.classList.remove('shut');
  findInput.select();
  findInput.focus();

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
      e.preventDefault();
      takeFind(i);
    });
    findList.appendChild(li);
  });
  if (findAt >= 0) findList.children[findAt]?.scrollIntoView({ block: 'nearest' });
}

function renderFindList() {
  const typed = findInput.value.trim();

  findItems = finding() ? deps.rank(deps.prefixCandidates(), typed) : [];
  findAt = -1;
  renderFindRows();
}

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

  renderFindList();
});

findList.addEventListener('mousemove', () => find.classList.add('mousing'));
findInput.addEventListener('keydown', () => find.classList.remove('mousing'));

findInput.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') {
    e.preventDefault();

    if (findItems.length) shutFindList(); else shutFind();
    return;
  }

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

    stepHit(e.shiftKey ? -1 : 1);
    return;
  }

  if (e.key === 'ArrowDown') {
    e.preventDefault();
    if (findItems.length) moveFindList(1); else stepHit(1);
  }
  if (e.key === 'ArrowUp') {
    e.preventDefault();
    if (findItems.length) moveFindList(-1); else stepHit(-1);
  }
});

document.addEventListener('keydown', (e) => {
  if (!(e.metaKey || e.ctrlKey) || e.key !== 'f') return;
  e.preventDefault();
  if (finding()) { findInput.select(); findInput.focus(); return; }
  openFind();
}, true);

export function anchorHit() {
  if (!finding()) return null;
  const hit = hits[hitAt];
  if (!hit || !hit.node.isConnected) return null;
  const title = hit.node.querySelector('title');
  if (!title) return null;
  const box = screenBounds(hit.node);
  return { key: title.textContent.trim(),
           x: box.left + box.width / 2, y: box.top + box.height / 2 };
}

export function restoreAnchor(anchor) {
  const svg = pane.querySelector('svg');
  if (anchor && svg) {
    for (const node of svg.querySelectorAll('g.node')) {
      const title = node.querySelector('title');
      if (!title || title.textContent.trim() !== anchor.key) continue;
      const box = screenBounds(node);
      panBy(anchor.x - (box.left + box.width / 2),
            anchor.y - (box.top + box.height / 2));

      const at = hits.findIndex(h => h.node === node);
      if (at >= 0) hitAt = at;
      break;
    }
  }

  if (finding() && hits[hitAt] && hits[hitAt].node.isConnected) {
    drawArrow(hits[hitAt]);
  }
}

export function redrawFind() {
  if (finding() && findInput.value.trim()) search();
}
