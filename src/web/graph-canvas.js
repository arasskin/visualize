import * as renderTrace from './render-trace.js';

function rectangle(box, matrix) {
  const points = [[box.x, box.y], [box.x + box.width, box.y], [box.x, box.y + box.height], [box.x + box.width, box.y + box.height]]
    .map(([x, y]) => new DOMPoint(x, y).matrixTransform(matrix));
  const x = Math.min(...points.map(p => p.x)), y = Math.min(...points.map(p => p.y));
  return { x, y, width: Math.max(...points.map(p => p.x)) - x, height: Math.max(...points.map(p => p.y)) - y };
}

function pathFor(el) {
  const n = key => Number(el.getAttribute(key) || 0);
  const path = new Path2D();
  switch (el.localName) {
    case 'path': return new Path2D(el.getAttribute('d') || '');
    case 'ellipse': path.ellipse(n('cx'), n('cy'), n('rx'), n('ry'), 0, 0, Math.PI * 2); break;
    case 'rect': path.rect(n('x'), n('y'), n('width'), n('height')); break;
    case 'line': path.moveTo(n('x1'), n('y1')); path.lineTo(n('x2'), n('y2')); break;
    default: {
      const points = [...el.points];
      points.forEach((p, i) => i ? path.lineTo(p.x, p.y) : path.moveTo(p.x, p.y));
      if (el.localName === 'polygon') path.closePath();
    }
  }
  return path;
}

function compile(el) {
  const style = getComputedStyle(el);
  const matrix = el.getCTM();
  if (!matrix || style.display === 'none') return null;
  let opacity = 1;
  for (let p = el; p instanceof SVGElement; p = p.parentElement) opacity *= Number(getComputedStyle(p).opacity);
  const item = {
    el, matrix, opacity, localBox: el.getBBox(), box: rectangle(el.getBBox(), matrix),
    fill: style.fill, fillOpacity: Number(style.fillOpacity), stroke: style.stroke,
    strokeOpacity: Number(style.strokeOpacity), lineWidth: parseFloat(style.strokeWidth),
    dash: style.strokeDasharray === 'none' ? [] : style.strokeDasharray.split(/[ ,]+/).map(parseFloat),
    dashOffset: parseFloat(style.strokeDashoffset) || 0,
    lineJoin: style.strokeLinejoin, lineCap: style.strokeLinecap,
    node: el.closest('g.node'), edge: el.closest('g.edge'),
    fresh: el.closest('g.fresh'), folded: el.closest('g.folded'),
  };
  if (el.localName === 'text') {
    Object.assign(item, { text: el.textContent, x: el.x.baseVal[0]?.value || 0, y: el.y.baseVal[0]?.value || 0,
      font: `${style.fontStyle} ${style.fontWeight} ${style.fontSize} ${style.fontFamily}`,
      align: style.textAnchor === 'middle' ? 'center' : style.textAnchor === 'end' ? 'right' : 'left' });
  } else item.path = pathFor(el);
  return item;
}

function drawItem(ctx, item, mode, alpha = 1, matrix = item.matrix) {
  ctx.save();
  const m = matrix;
  ctx.transform(m.a, m.b, m.c, m.d, m.e, m.f);
  ctx.globalAlpha *= item.opacity * alpha;
  ctx.lineWidth = mode === 'found' ? 2.5 : mode === 'hover' ? 2.4 : item.lineWidth;
  ctx.lineJoin = item.lineJoin;
  ctx.lineCap = item.lineCap;
  ctx.setLineDash(item.dash);
  ctx.lineDashOffset = item.dashOffset;
  const fill = mode === 'hover' && item.el.localName === 'polygon' ? '#c04040' : item.fill;
  const stroke = mode === 'found' ? '#e5484d' : mode === 'hover' ? '#c04040' : item.stroke;
  if (item.text !== undefined) {
    ctx.font = item.font;
    ctx.textAlign = item.align;
    ctx.textBaseline = 'alphabetic';
    if (fill !== 'none') { ctx.fillStyle = fill; ctx.globalAlpha *= item.fillOpacity; ctx.fillText(item.text, item.x, item.y); }
  } else {
    if (mode !== 'found' && fill !== 'none' && (!item.fresh || item.folded || mode === 'flash')) {
      ctx.save();
      ctx.globalAlpha *= item.fillOpacity;
      if (fill.startsWith('url(') || item.folded) {
        ctx.clip(item.path);
        ctx.strokeStyle = item.stroke;
        ctx.lineWidth = 1;
        ctx.globalAlpha *= .55;
        const b = item.localBox;
        ctx.beginPath();
        for (let x = b.x - b.height; x < b.x + b.width + b.height; x += 6 * Math.SQRT2) {
          ctx.moveTo(x, b.y + b.height); ctx.lineTo(x + b.height, b.y);
        }
        ctx.stroke();
      } else { ctx.fillStyle = fill; ctx.fill(item.path); }
      ctx.restore();
    }
    if (stroke !== 'none' && mode !== 'flash') {
      ctx.globalAlpha *= item.strokeOpacity;
      ctx.strokeStyle = stroke;
      ctx.stroke(item.path);
    }
  }
  ctx.restore();
}

export function createRenderer(svg, repaint) {
  const width = svg.width.baseVal.value, height = svg.height.baseVal.value;
  const box = svg.viewBox.baseVal;
  const unit = box.width ? width / box.width : 1;
  const canvas = document.createElement('canvas');
  canvas.className = 'graph-canvas';
  canvas.setAttribute('role', 'img');
  canvas.setAttribute('aria-label', 'Dependency graph. Use search to find nodes.');
  svg.before(canvas);
  svg.classList.add('graph-layout');
  const ctx = canvas.getContext('2d');
  const probe = document.createElement('canvas').getContext('2d');
  let items = [], arrow = [], selected = null, hovered = null;
  let arrowScale = 1, arrowBox = null;
  const tileSize = 512, gutter = 2, tileLimit = 96;
  const tiles = new Map();
  let tileDensity = null;
  const flashStart = performance.now();
  const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
  const boxes = new WeakMap();
  const labelSizes = new WeakMap();
  let disposed = false;
  let viewportWidth = canvas.clientWidth, viewportHeight = canvas.clientHeight;
  const resize = new ResizeObserver(entries => {
    viewportWidth = entries[0].contentRect.width;
    viewportHeight = entries[0].contentRect.height;
    repaint();
  });
  resize.observe(canvas);
  const observer = new MutationObserver(() => { if (!svg.isConnected) dispose(); });
  observer.observe(svg.parentElement, { childList: true });
  let fileLabels = [];
  function rebuild() {
    if (disposed || !svg.isConnected) return;
    const traceStart = renderTrace.begin();
    for (const node of svg.querySelectorAll('g.node')) {
      const oval = node.querySelector('ellipse');
      if (!oval) continue;
      const center = new DOMPoint(oval.cx.baseVal.value, oval.cy.baseVal.value).matrixTransform(oval.getCTM());
      for (const text of node.querySelectorAll('text')) {
        const local = center.matrixTransform(text.getCTM().inverse());
        text.setAttribute('x', local.x);
        text.setAttribute('text-anchor', 'middle');
      }
    }
    for (const group of svg.querySelectorAll('g.cluster')) {
      const border = group.querySelector(':scope > polygon, :scope > rect, :scope > path');
      if (!border) continue;
      for (const text of group.querySelectorAll(':scope > text')) {
        if (!labelSizes.has(text)) labelSizes.set(text, parseFloat(getComputedStyle(text).fontSize));
        const size = labelSizes.get(text);
        text.setAttribute('font-size', size);
        const bounds = rectangle(border.getBBox(), text.getCTM().inverse().multiply(border.getCTM()));
        text.setAttribute('x', bounds.x + bounds.width / 2);
        text.setAttribute('text-anchor', 'middle');
        const width = text.getBBox().width;
        if (width > 0) text.setAttribute('font-size', size * Math.min(1, Math.max(1, bounds.width - 12) / width));
      }
    }
    items = [...svg.querySelectorAll('path,ellipse,polygon,polyline,rect,line,text')]
      .filter(el => !el.closest('defs,#find-arrow') && !el.classList.contains('hit'))
      .map(compile).filter(Boolean);
    fileLabels = [...svg.querySelectorAll('g.node')].flatMap(node => {
      const link = node.querySelector('a');
      const href = link?.getAttribute('xlink:href') || link?.getAttribute('href') || '';
      if (!href.startsWith('visualize-file:') || node.classList.contains('folded')) return [];
      const file = href.slice('visualize-file:'.length);
      const name = node.querySelector('title')?.textContent;
      return [...node.querySelectorAll('text')].map(el => ({ name, file, box: rectangle(el.getBBox(), el.getCTM()) }));
    });
    renderTrace.end('geometry-rebuild', traceStart, { items: items.length, fileLabels: fileLabels.length });
    clearTiles();
    repaint();
  }
  function bounds(el, scale = arrowScale) {
    if (!el) return null;
    if (el.id === 'find-arrow' && arrowBox && arrow.length) {
      const ratio = arrowScale / scale, m = arrow[0].matrix;
      return { x: m.e + (arrowBox.x - m.e) * ratio, y: m.f + (arrowBox.y - m.f) * ratio,
        width: arrowBox.width * ratio, height: arrowBox.height * ratio };
    }
    if (!boxes.has(el)) boxes.set(el, rectangle(el.getBBox(), el.getCTM()));
    return boxes.get(el);
  }
  function releaseTile(tile) { tile.width = 0; tile.height = 0; }
  function clearTiles() {
    for (const tile of tiles.values()) releaseTile(tile);
    tiles.clear();
  }
  function raster(column, row, density, candidates) {
    const traceStart = renderTrace.begin();
    const surface = document.createElement('canvas');
    surface.width = surface.height = tileSize + gutter * 2;
    const c = surface.getContext('2d');
    c.setTransform(density, 0, 0, density, gutter - column * tileSize, gutter - row * tileSize);
    for (const item of candidates) drawItem(c, item);
    renderTrace.end('raster', traceStart, { reason: 'tile', column, row, density, drawn: candidates.length, items: items.length, width: surface.width, height: surface.height, pixels: surface.width * surface.height });
    return surface;
  }
  function render(view, navigating) {
    if (disposed) return;
    const { scale, tx, ty } = view;
    const w = viewportWidth, h = viewportHeight;
    if (!w || !h) return;
    const traceStart = renderTrace.begin();
    let rebuilt = 0;
    const dpr = Math.min(devicePixelRatio || 1, Math.sqrt(16777216 / Math.max(1, w * h)), 8192 / Math.max(1, w, h));
    if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) {
      canvas.width = Math.round(w * dpr); canvas.height = Math.round(h * dpr);
    }
    const density = scale * dpr;
    if (density !== tileDensity) { clearTiles(); tileDensity = density; }
    const x = Math.round(tx * dpr), y = Math.round(ty * dpr);
    const left = Math.floor(-x / tileSize), top = Math.floor(-y / tileSize);
    const right = Math.ceil((canvas.width - x) / tileSize), bottom = Math.ceil((canvas.height - y) / tileSize);
    const visible = [];
    const missing = new Map();
    for (let row = top; row < bottom; row++) for (let column = left; column < right; column++) {
      const key = `${column}:${row}`;
      const entry = {key, column, row, tile: tiles.get(key), candidates: []};
      if (!entry.tile) missing.set(key, entry);
      visible.push(entry);
    }
    if (missing.size) for (const item of items) {
      const b = item.box;
      const x0 = Math.max(left, Math.floor(((b.x - 4) * density - gutter) / tileSize));
      const y0 = Math.max(top, Math.floor(((b.y - 4) * density - gutter) / tileSize));
      const x1 = Math.min(right - 1, Math.floor(((b.x + b.width + 4) * density + gutter) / tileSize));
      const y1 = Math.min(bottom - 1, Math.floor(((b.y + b.height + 4) * density + gutter) / tileSize));
      for (let row = y0; row <= y1; row++) for (let column = x0; column <= x1; column++) {
        missing.get(`${column}:${row}`)?.candidates.push(item);
      }
    }
    for (const entry of visible) {
      if (!entry.tile) { entry.tile = raster(entry.column, entry.row, density, entry.candidates); rebuilt++; }
      tiles.delete(entry.key); tiles.set(entry.key, entry.tile);
    }
    while (tiles.size > tileLimit) {
      const key = tiles.keys().next().value;
      releaseTile(tiles.get(key)); tiles.delete(key);
    }
    const compositeStart = renderTrace.begin();
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.globalAlpha = hovered ? .22 : 1;
    for (const entry of visible) ctx.drawImage(entry.tile, gutter, gutter, tileSize, tileSize,
      entry.column * tileSize + x, entry.row * tileSize + y, tileSize, tileSize);
    renderTrace.end('canvas-composite', compositeStart);
    const overlayStart = renderTrace.begin();
    ctx.setTransform(density, 0, 0, density, x, y);
    ctx.globalAlpha = 1;
    if (hovered) for (const item of items) if (item.edge === hovered) drawItem(ctx, item, 'hover');
    if (selected) for (const item of items) if (item.node === selected && item.path) drawItem(ctx, item, 'found');
    for (const item of arrow) {
      const m = item.matrix, ratio = arrowScale / scale;
      drawItem(ctx, item, undefined, 1,
        { a: m.a * ratio, b: m.b * ratio, c: m.c * ratio, d: m.d * ratio, e: m.e, f: m.f });
    }
    const elapsed = performance.now() - flashStart;
    if (!navigating && elapsed < 3000 && !reducedMotion.matches && items.some(i => i.fresh)) {
      for (const item of items) if (item.fresh && item.path) drawItem(ctx, item, 'flash', .55 * Math.sin(Math.PI * elapsed / 3000));
      requestAnimationFrame(repaint);
    }
    renderTrace.end('overlays', overlayStart, { selected: !!selected, hovered: !!hovered, arrow: arrow.length });
    renderTrace.end('canvas-render', traceStart, { scale, navigating, rebuilt, cached: tiles.size, visible: visible.length, width: canvas.width, height: canvas.height });
  }
  function hit(x, y, scale) {
    for (let i = items.length - 1; i >= 0; i--) {
      const item = items[i];
      if (!item.path || !item.edge) continue;
      const point = new DOMPoint(x, y).matrixTransform(item.matrix.inverse());
      probe.setTransform(1, 0, 0, 1, 0, 0);
      probe.lineWidth = 16 / (scale * Math.hypot(item.matrix.a, item.matrix.b));
      if (probe.isPointInStroke(item.path, point.x, point.y)) return item.edge;
    }
    return null;
  }
  function fileAt(x, y) {
    for (const label of fileLabels) {
      const b = label.box;
      if (x >= b.x && x <= b.x + b.width && y >= b.y && y <= b.y + b.height) return label;
    }
    return null;
  }
  function selection(node, element, scale = 1) {
    selected = node;
    arrow = element ? [...element.querySelectorAll('path,line,polygon')].map(compile).filter(Boolean) : [];
    arrowScale = scale;
    arrowBox = element ? rectangle(element.getBBox(), element.getCTM()) : null;
    repaint();
  }
  function hover(edge) { if (hovered !== edge) { hovered = edge; repaint(); } }
  function dispose() {
    if (disposed) return;
    disposed = true; observer.disconnect(); resize.disconnect();
    media.removeEventListener('change', update);
    document.fonts.removeEventListener('loadingdone', update);
    clearTiles(); items = []; arrow = [];
  }
  const media = matchMedia('(prefers-color-scheme: dark)');
  const update = () => rebuild();
  media.addEventListener('change', update);
  document.fonts.addEventListener('loadingdone', update);
  document.fonts.ready.then(update);
  rebuild();
  return { svg, canvas, width, height, unit, render, bounds, hit: (...args) => renderTrace.measure('edge-hit', () => hit(...args)), fileAt: (...args) => renderTrace.measure('file-hit', () => fileAt(...args)), selection: (...args) => renderTrace.measure('selection-compile', () => selection(...args)), hover, rebuild, dispose };
}
