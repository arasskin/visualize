
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

function drawItem(ctx, item, mode, alpha = 1) {
  ctx.save();
  const m = item.matrix;
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
  let items = [], overview = null, detail = null, arrow = [], selected = null, hovered = null;
  let revision = 0, detailRevision = -1, detailView = '';
  const flashStart = performance.now();
  const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
  const boxes = new WeakMap();
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
  function rebuild() {
    if (disposed || !svg.isConnected) return;
    items = [...svg.querySelectorAll('path,ellipse,polygon,polyline,rect,line,text')]
      .filter(el => !el.closest('defs,#find-arrow') && !el.classList.contains('hit'))
      .map(compile).filter(Boolean);
    revision++;
    overview = null; detail = null;
    repaint();
  }
  function bounds(el) {
    if (!el) return null;
    if (el.id === 'find-arrow') return rectangle(el.getBBox(), el.getCTM());
    if (!boxes.has(el)) boxes.set(el, rectangle(el.getBBox(), el.getCTM()));
    return boxes.get(el);
  }
  function raster(region, density) {
    const surface = document.createElement('canvas');
    surface.width = Math.max(1, Math.ceil(region.width * density));
    surface.height = Math.max(1, Math.ceil(region.height * density));
    const c = surface.getContext('2d');
    c.setTransform(density, 0, 0, density, -region.x * density, -region.y * density);
    for (const item of items) {
      const b = item.box;
      if (b.x + b.width + 4 < region.x || b.y + b.height + 4 < region.y || b.x - 4 > region.x + region.width || b.y - 4 > region.y + region.height) continue;
      drawItem(c, item);
    }
    return { surface, ...region };
  }
  function render(view, navigating) {
    if (disposed) return;
    const { scale, tx, ty } = view;
    const w = viewportWidth, h = viewportHeight;
    if (!w || !h) return;
    const dpr = Math.min(devicePixelRatio || 1, Math.sqrt(16777216 / Math.max(1, w * h)), 8192 / Math.max(1, w, h));
    if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) {
      canvas.width = Math.round(w * dpr); canvas.height = Math.round(h * dpr);
    }
    if (!overview) overview = raster({ x: 0, y: 0, width, height }, Math.min(1, Math.sqrt(4194304 / Math.max(1, width * height)), 4096 / Math.max(width, height)));
    const key = [scale, w, h, dpr].join(':');
    const uncovered = !detail || -tx / scale < detail.x || -ty / scale < detail.y || (w - tx) / scale > detail.x + detail.width || (h - ty) / scale > detail.y + detail.height;
    if (!navigating && (detailView !== key || detailRevision !== revision || uncovered)) {
      const pad = 128;
      const region = { x: (-tx - pad) / scale, y: (-ty - pad) / scale, width: (w + pad * 2) / scale, height: (h + pad * 2) / scale };
      const density = Math.min(scale * dpr, Math.sqrt(16777216 / (region.width * region.height)), 8192 / Math.max(region.width, region.height));
      detail = raster(region, density);
      detailView = key; detailRevision = revision;
    }
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.setTransform(dpr * scale, 0, 0, dpr * scale, dpr * tx, dpr * ty);
    ctx.globalAlpha = hovered ? .22 : 1;
    ctx.imageSmoothingEnabled = true;
    const draw = tile => ctx.drawImage(tile.surface, tile.x, tile.y, tile.width, tile.height);
    draw(overview);
    if (detail) {
      ctx.clearRect(detail.x, detail.y, detail.width, detail.height);
      draw(detail);
    }
    ctx.globalAlpha = 1;
    if (hovered) for (const item of items) if (item.edge === hovered) drawItem(ctx, item, 'hover');
    if (selected) for (const item of items) if (item.node === selected && item.path) drawItem(ctx, item, 'found');
    for (const item of arrow) drawItem(ctx, item);
    const elapsed = performance.now() - flashStart;
    if (!navigating && elapsed < 3000 && !reducedMotion.matches && items.some(i => i.fresh)) {
      for (const item of items) if (item.fresh && item.path) drawItem(ctx, item, 'flash', .55 * Math.sin(Math.PI * elapsed / 3000));
      requestAnimationFrame(repaint);
    }
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
  function selection(node, element) {
    selected = node;
    arrow = element ? [...element.querySelectorAll('path,line,polygon')].map(compile).filter(Boolean) : [];
    repaint();
  }
  function hover(edge) { if (hovered !== edge) { hovered = edge; repaint(); } }
  function dispose() {
    if (disposed) return;
    disposed = true; observer.disconnect(); resize.disconnect();
    media.removeEventListener('change', update);
    document.fonts.removeEventListener('loadingdone', update);
    overview = null; detail = null; items = []; arrow = [];
  }
  const media = matchMedia('(prefers-color-scheme: dark)');
  const update = () => rebuild();
  media.addEventListener('change', update);
  document.fonts.addEventListener('loadingdone', update);
  document.fonts.ready.then(update);
  rebuild();
  return { svg, canvas, width, height, unit, render, bounds, hit, selection, hover, rebuild, dispose };
}
