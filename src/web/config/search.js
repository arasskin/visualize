import {completionList} from '../shared/completion-list.js';
import { matchesText } from '../shared/text-match.js';

function ancestorsOf(model) {
  const nodes = new Map(model.nodes.map(node => [node.id, node])), edges = new Map();
  for (const [from, to] of model.edges || []) {
    if (!edges.has(to)) edges.set(to, []);
    edges.get(to).push(from);
  }
  return id => {
    const seen = new Set([id]), reachable = [], pending = [...(edges.get(id) || [])];
    for (let i = 0; i < pending.length; i++) {
      const target = pending[i]; if (seen.has(target)) continue;
      seen.add(target); if (nodes.has(target)) reachable.push(nodes.get(target));
      pending.push(...(edges.get(target) || []));
    }
    return reachable;
  };
}

export function matchConfigNodes(model, query) {
  const words = (query.trim().match(/"[^"]*"|\S+/g) || []).map(word => word.replace(/^"|"$/g, ''));
  if (!words.length) return [];
  const nodes = new Map(model.nodes.map(node => [node.id, node]));
  const ancestorsFor = ancestorsOf(model);
  const parents = new Map();
  for (const [from, to] of model.edges || []) {
    if (!parents.has(to)) parents.set(to, []);
    parents.get(to).push(from);
  }
  return model.nodes.filter(node => {
    const reachable = ancestorsFor(node.id);
    return matchesText(node.label, words[0])
      && words.slice(1).every(word => reachable.some(target => matchesText(target.label, word)));
  }).map(node => {
    const targets = (parents.get(node.id) || []).map(id => nodes.get(id)?.label || id).sort();
    return {node, identity: JSON.stringify([node.kind, node.label, targets])};
  });
}

export function configSearchCompletions(model, text, caret = text.length) {
  const tokens = [...text.matchAll(/"[^"]*"|"[^"]*$|[^\s"]+/g)];
  const token = tokens.find(token => token.index <= caret && token.index + token[0].length >= caret);
  const start = token?.index ?? caret, end = token ? start + token[0].length : caret;
  const query = text.slice(start, caret).replace(/^"|"$/g, '');
  const context = text.slice(0, start).trim();
  const ancestorsFor = ancestorsOf(model);
  const pool = context ? matchConfigNodes(model, context).flatMap(hit => ancestorsFor(hit.node.id)) : model.nodes;
  const items = [...new Set(pool.map(node => node.label))].filter(label => matchesText(label, query))
    .sort((a, b) => a.length - b.length || a.localeCompare(b));
  return {start, end, items};
}

let searchId = 0;

export function configSearch(host, canvas, navigation) {
  const field = document.createElement('div'); field.className = 'config-search';
  const input = document.createElement('input'); input.placeholder = 'Find a node…'; input.spellcheck = false; input.autocomplete = 'off';
  input.setAttribute('aria-label', 'Find configuration nodes by label and prefix ancestry'); input.setAttribute('role', 'combobox');
  input.setAttribute('aria-autocomplete', 'list'); input.setAttribute('aria-expanded', 'false');
  const list = document.createElement('ul'); list.className = 'config-completions config-search-completions'; list.hidden = true;
  list.id = `config-search-completions-${++searchId}`; list.setAttribute('role', 'listbox'); input.setAttribute('aria-controls', list.id);
  const count = document.createElement('span'); count.className = 'config-search-count'; count.setAttribute('role', 'status');
  field.append(input, count, list); host.append(field);
  let model = {nodes: [], edges: []}, svg = null, hits = [], at = 0, selected = null, geometry = null, arrow = null;
  let boxes = new Map(), groups = new Map(), identity = null, occurrence = 0, angle = -90;
  let completion = {items: []};
  const suggestions = completionList(input, list, {preview: true, take(value, preview = false) {
    input.setRangeText(/\s/.test(value) ? JSON.stringify(value) : value, completion.start, completion.end, 'end');
    completion.end = input.selectionEnd;
    if (!preview) suggestions.close();
    input.focus({preventScroll: true}); search();
  }});
  const closeList = suggestions.close;
  function complete() {
    completion = configSearchCompletions(model, input.value, input.selectionStart ?? input.value.length);
    suggestions.set(completion.items.slice(0, 12));
  }
  function clear() {
    selected?.classList.remove('search-hit'); selected = null; geometry = null;
    arrow?.remove(); arrow = null;
  }
  function aim() {
    const box = navigation.project(geometry), cx = box.x + box.width / 2, cy = box.y + box.height / 2;
    let best = -Infinity;
    for (const degrees of [-90, 90, 0, 180]) {
      const radians = degrees * Math.PI / 180, dx = Math.cos(radians), dy = Math.sin(radians);
      const tip = {x: cx + dx * box.width / 2, y: cy + dy * box.height / 2};
      const tail = {x: tip.x + dx * 72, y: tip.y + dy * 72};
      let clearance = Math.min(tail.x, tail.y, canvas.clientWidth - tail.x, canvas.clientHeight - tail.y);
      for (const [id, other] of boxes) {
        if (id === hits[at]?.node.id) continue;
        const rect = navigation.project(other);
        for (const distance of [24, 48, 72]) {
          const x = tip.x + dx * distance, y = tip.y + dy * distance;
          clearance = Math.min(clearance, Math.max(rect.x - x, x - rect.x - rect.width, rect.y - y, y - rect.y - rect.height));
        }
      }
      if (clearance > best) { best = clearance; angle = degrees; }
    }
  }
  function placeArrow() {
    if (!arrow || !geometry) return;
    const box = navigation.project(geometry), radians = angle * Math.PI / 180;
    arrow.setAttribute('transform', `translate(${box.x + box.width / 2 + Math.cos(radians) * box.width / 2} ${box.y + box.height / 2 + Math.sin(radians) * box.height / 2}) rotate(${angle})`);
  }
  function show(point) {
    clear();
    const hit = hits[at];
    count.textContent = !input.value.trim() ? '' : !hit ? 'no match' : `${at + 1}/${hits.length}`;
    if (!hit || !svg) { identity = null; return; }
    selected = groups.get(hit.node.id); geometry = boxes.get(hit.node.id);
    if (!selected || !geometry) return;
    identity = hit.identity; occurrence = hits.slice(0, at).filter(item => item.identity === identity).length;
    selected.classList.add('search-hit'); navigation.anchor(geometry, point);
    const ns = 'http://www.w3.org/2000/svg';
    arrow = document.createElementNS(ns, 'g'); arrow.classList.add('config-find-arrow'); arrow.setAttribute('pointer-events', 'none');
    arrow.dataset.node = hit.node.id; arrow.setAttribute('aria-hidden', 'true');
    const shaft = document.createElementNS(ns, 'line'); shaft.classList.add('find-shaft');
    shaft.setAttribute('x1', '72'); shaft.setAttribute('x2', '18');
    const head = document.createElementNS(ns, 'polygon'); head.classList.add('find-head'); head.setAttribute('points', '0,0 20,8 20,-8');
    arrow.append(shaft, head); svg.append(arrow); aim(); placeArrow();
  }
  function measure() {
    boxes = input.value.trim() && canvas.clientWidth && canvas.clientHeight
      ? new Map([...groups].map(([id, group]) => [id, navigation.bounds(group.querySelector('ellipse'))])) : new Map();
  }
  function search() { measure(); hits = matchConfigNodes(model, input.value); at = 0; show(); }
  input.addEventListener('input', () => { search(); complete(); });
  input.addEventListener('focus', complete);
  input.addEventListener('click', complete);
  input.addEventListener('blur', closeList);
  input.addEventListener('keyup', event => {
    if (['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) complete();
  });
  input.addEventListener('keydown', event => {
    if (suggestions.key(event)) return;
    if (event.key === 'Escape') {
      event.preventDefault(); event.stopPropagation(); input.value = ''; search(); return;
    }
    if (!['Enter', 'ArrowDown', 'ArrowUp'].includes(event.key)) return;
    event.preventDefault(); event.stopPropagation();
    closeList();
    if (hits.length) at = (at + (event.key === 'ArrowUp' || event.shiftKey ? -1 : 1) + hits.length) % hits.length;
    show();
  });
  return {
    focus() { input.focus({preventScroll: true}); input.select(); },
    capture() {
      if (!geometry) return null;
      const box = navigation.project(geometry); return {x: box.x + box.width / 2, y: box.y + box.height / 2};
    },
    update(nextModel, nextSvg, point) {
      model = nextModel; svg = nextSvg;
      groups = new Map([...svg.querySelectorAll('g.node')].map(group => [group.dataset.node, group]));
      measure();
      hits = matchConfigNodes(model, input.value);
      const matches = hits.map((hit, index) => hit.identity === identity ? index : -1).filter(index => index >= 0);
      at = matches[Math.min(occurrence, matches.length - 1)] ?? 0;
      show(matches.length ? point : undefined);
      if (document.activeElement === input && !list.hidden) complete();
    },
    placeArrow,
    stop() { clear(); field.remove(); },
  };
}
