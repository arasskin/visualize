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

export function createHover(graph) {
  const {pane, edgeAt, hoverGraphEdge} = graph;
  function labelEl() {
    let el = document.getElementById('edgelabel');
    if (!el) {
      el = document.createElement('div');
      el.id = 'edgelabel';
      el.style.display = 'none';
      pane.appendChild(el);
    }
    return el;
  }

  function keepEdgeLabel() {
    const el = labelEl();
    if (pane && el.parentNode !== pane) pane.appendChild(el);
    return el;
  }

  function showEdge(group, names) {
    if (graph.navigating) return;

    const pair = group.dataset.edge;
    if (!pair) return;
    hoverGraphEdge(group);
    const edgeLabel = labelEl();
    edgeLabel.replaceChildren();
    for (const connection of pair.split('\n')) {
      const [from, to] = connection.split('->');
      const row = document.createElement('div');
      const a = document.createElement('b');
      a.textContent = names.get((from || '').trim()) || from || '?';
      const arrow = document.createElement('span');
      arrow.className = 'arrow';
      arrow.textContent = '→';
      const b = document.createElement('b');
      b.textContent = names.get((to || '').trim()) || to || '?';
      row.append(a, arrow, b); edgeLabel.append(row);
    }
    edgeLabel.style.display = 'block';
  }

  function hideEdge() {
    hovered = null;
    hoverGraphEdge(null);
    const svg = pane.querySelector('svg');
    if (svg) svg.classList.remove('hovering');
    labelEl().style.display = 'none';
  }

  function moveLabel(event) {
    if (graph.navigating) return;
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

  function wireEdges() {
    const svg = pane.querySelector('svg');
    if (!svg) return;
    names = moduleNames(svg);
    hovered = null;
    for (const group of svg.querySelectorAll('g.edge')) {
      const title = group.querySelector('title');
      const tooltip = group.querySelector('a')?.getAttributeNS('http://www.w3.org/1999/xlink', 'title');
      if (title) group.dataset.edge = tooltip || title.textContent.trim();
    }
  }

  pane.addEventListener('mousemove', event => {
    if (graph.navigating) return;
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

  return {hideEdge, wireEdges, keepEdgeLabel};
}
