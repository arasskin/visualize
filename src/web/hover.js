import { pane, navigating, edgeAt, hoverGraphEdge } from './graph.js';

export function moduleNames(svg) {
  const byNode = new Map();
  for (const node of svg.querySelectorAll('g.node')) {
    const key = node.querySelector('title');
    if (!key) continue;

    const texts = [...node.querySelectorAll('text')];
    const spans = texts.flatMap(t => [...t.querySelectorAll('tspan')]);
    const runs = (spans.length ? spans : texts)
      .map(t => t.textContent.trim());

    if (runs.length > 1 && /^\d+$/.test(runs[runs.length - 1])) runs.pop();
    const label = runs.join('');
    byNode.set(key.textContent.trim(), label || key.textContent.trim());
  }
  return byNode;
}

function labelEl() {
  let el = document.getElementById('edgelabel');
  if (!el) {
    el = document.createElement('div');
    el.id = 'edgelabel';
    el.style.display = 'none';
    (document.getElementById('graph') || document.body).appendChild(el);
  }
  return el;
}

export function keepEdgeLabel() {
  const el = labelEl();
  const pane = document.getElementById('graph');
  if (pane && el.parentNode !== pane) pane.appendChild(el);
  return el;
}

function showEdge(group, names) {
  if (navigating) return;

  const pair = group.dataset.edge;
  if (!pair) return;
  const [from, to] = pair.split('->');
  hoverGraphEdge(group);
  const edgeLabel = labelEl();
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

export function hideEdge() {
  hovered = null;
  hoverGraphEdge(null);
  const svg = pane.querySelector('svg');
  if (svg) svg.classList.remove('hovering');
  labelEl().style.display = 'none';
}

function moveLabel(event) {
  if (navigating) return;
  const edgeLabel = labelEl();
  if (edgeLabel.style.display !== 'block') return;
  const box = pane.getBoundingClientRect();
  let x = event.clientX - box.left + 14;
  let y = event.clientY - box.top + 14;
  if (x + edgeLabel.offsetWidth > box.width) x -= edgeLabel.offsetWidth + 24;
  if (y + edgeLabel.offsetHeight > box.height) y -= edgeLabel.offsetHeight + 24;
  edgeLabel.style.left = Math.max(0, x) + 'px';
  edgeLabel.style.top = Math.max(0, y) + 'px';
}

let hovered = null;
let names = new Map();

export function wireEdges() {
  const svg = pane.querySelector('svg');
  if (!svg) return;
  names = moduleNames(svg);
  hovered = null;
  for (const group of svg.querySelectorAll('g.edge')) {
    const title = group.querySelector('title');
    if (title) group.dataset.edge = title.textContent.trim();
  }
}

pane.addEventListener('mousemove', event => {
  if (navigating) return;
  const box = pane.getBoundingClientRect();
  const edge = edgeAt(event.clientX - box.left, event.clientY - box.top);
  if (edge !== hovered) {
    hideEdge();
    hovered = edge;
    if (edge) showEdge(edge, names);
  }
  moveLabel(event);
});
pane.addEventListener('mouseleave', hideEdge);
