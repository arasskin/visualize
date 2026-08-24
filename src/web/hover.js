// Hovering a dependency: which file does this line come from, and where does
// it go?
//
// The renderer answers that in each edge's <title>, but a <title> is only a
// native tooltip on a 1px target. This makes the target fat and the answer
// visible.

import { pane } from './graph.js';

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
export function moduleNames(svg) {
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

// THE LABEL THE EDGE HOVER WRITES INTO, and the one element on this page
// that has to survive being deleted. It lives inside #graph, and a redraw
// sets that pane's innerHTML to the new SVG -- which takes the label with
// it. So the reference is not cached: it is looked up when needed, and
// `keepEdgeLabel` puts a fresh one back after a redraw.
//
// Cached in a module-level const, this was a bug twice over. The binding
// went stale the first time the pane was rewritten, and app.js -- which does
// the rewriting -- reached for a name that only ever existed in here,
// throwing "edgelabel is not defined" on every redraw that carried an SVG.
// One config action was enough to break the page.
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

// Put the label back into a pane that has just been rewritten. Called by
// whoever replaced the SVG, because that is who knows it happened.
export function keepEdgeLabel() {
  const el = labelEl();
  const pane = document.getElementById('graph');
  if (pane && el.parentNode !== pane) pane.appendChild(el);
  return el;
}

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
  for (const lit of pane.querySelectorAll('.lit')) lit.classList.remove('lit');
  const svg = pane.querySelector('svg');
  if (svg) svg.classList.remove('hovering');
  labelEl().style.display = 'none';
}

// Follows the pointer rather than sitting in a fixed corner: a dense graph has
// edges at both ends of the pane, and a label 900px from the line it names is a
// label you have to hunt for. Flipped near the edges so it never leaves.
function moveLabel(event) {
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

// Give every edge a fat transparent twin to catch the pointer. Cloning the real
// path rather than widening it: a wider visible stroke would change the
// drawing, and a stroke that grows under the cursor can push itself out from
// under it and flicker.
export function wireEdges() {
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

