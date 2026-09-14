import {completionList} from '../shared/completion-list.js';
import { measure } from '../shared/render-trace.js';
import { matchesText } from '../shared/text-match.js';

export function createFind(graph, deps) {
  const {pane, panBy, drawing, renderedScale, screenBounds, selectGraphNode} = graph;
  const find = document.getElementById('find');
  const findInput = document.getElementById('find-input');
  const findCount = document.getElementById('find-count');

  let hits = [];
  let hitAt = 0;

  function finding() { return !find.classList.contains('shut'); }

  function searchNodes(query) {
    return measure('search-match', () => matchNodes(query));
  }

  function matchNodes(query) {
    const svg = pane.querySelector('svg');
    if (!svg || !query) return [];
    const names = deps.moduleNames(svg);
    const found = [];
    for (const node of svg.querySelectorAll('g.node')) {
      const title = node.querySelector('title');
      if (!title) continue;
      const key = title.textContent.trim();
      const label = names.get(key) || key;
      if (!matchesText(key, query) && !matchesText(label, query)) continue;
      found.push({ node, key, label });
    }
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

  function zoomNow() { return graph.scale || 1; }

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

  function placeArrow() {
    const g = pane.querySelector('#find-arrow');
    if (!g) return;
    const k = 1 / ((renderedScale() || 1) * unitPx());
    g.setAttribute('transform',
      `translate(${g.dataset.x} ${g.dataset.y}) rotate(${g.dataset.deg}) scale(${k})`);
    selectGraphNode(hits[hitAt]?.node || null, g);
  }

  let unitCache = 0;

  function forgetUnit() { unitCache = 0; }
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
  const suggestions = completionList(findInput, findList, {preview: true,
    visibility: visible => find.classList.toggle('listing', visible),
    take(text) { findInput.value = text; runFind(); },
  });
  function renderFindList() {
    const typed = findInput.value.trim();
    suggestions.set(finding() ? measure('search-suggestions', () => deps.prefixCandidates().filter(text => matchesText(text, typed))) : []);
  }
  const shutFindList = suggestions.close;

  findInput.addEventListener('input', () => {
    runFind();

    renderFindList();
  });

  findList.addEventListener('mousemove', () => find.classList.add('mousing'));
  findInput.addEventListener('keydown', () => find.classList.remove('mousing'));

  findInput.addEventListener('keydown', (e) => {
    if (suggestions.key(e, false)) return;
    if (e.key === 'Escape') { e.preventDefault(); shutFind(); return; }
    if (e.key === 'Enter') { e.preventDefault(); stepHit(e.shiftKey ? -1 : 1); return; }
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); stepHit(e.key === 'ArrowDown' ? 1 : -1); }
  });

  document.addEventListener('keydown', (e) => {
    if (!(e.metaKey || e.ctrlKey) || e.key !== 'f') return;
    e.preventDefault();
    if (finding()) { findInput.select(); findInput.focus(); return; }
    openFind();
  }, true);

  function anchorHit() {
    if (!finding()) return null;
    const hit = hits[hitAt];
    if (!hit || !hit.node.isConnected) return null;
    const title = hit.node.querySelector('title');
    if (!title) return null;
    const box = screenBounds(hit.node);
    return { key: title.textContent.trim(),
             x: box.left + box.width / 2, y: box.top + box.height / 2 };
  }

  function restoreAnchor(anchor) {
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

  function redrawFind() {
    if (finding() && findInput.value.trim()) search();
  }

  return {placeArrow, redrawFind, anchorHit, restoreAnchor, forgetUnit};
}
