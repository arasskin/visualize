import {createCamera} from './camera.js';
import * as renderTrace from '../shared/render-trace.js';
import { createRenderer } from './canvas.js';
export function createGraph(pane, {onRepaint = () => {}, onNavigate = () => {}, onFileClick = () => {}} = {}) {
  let paintedScale = null;
  let paintedSvg = null;
  let navigationEnd = null;
  let navigating = false;
  const ZOOM_SETTLE_MS = 0;

  function beginNavigation() {
    if (navigating) return;
    navigating = true;
    onNavigate();
    pane.classList.add('navigating');
  }

  function endNavigation() {
    if (dragging || navigationEnd) return;
    navigating = false;
    paint();
    pane.classList.remove('navigating');
  }

  function navigateBriefly() {
    beginNavigation();
    clearTimeout(navigationEnd);
    navigationEnd = setTimeout(() => {
      navigationEnd = null;
      endNavigation();
    }, ZOOM_SETTLE_MS);
  }

  const camera = createCamera();

  function view() { return camera.view(); }

  function renderedScale() { return camera.scale; }

  let currentDrawing = null;

  function drawing() {
    const svg = pane.querySelector('svg');
    if (currentDrawing?.svg === svg) return currentDrawing;
    currentDrawing?.dispose();
    currentDrawing = svg ? createRenderer(svg, paint) : null;
    return currentDrawing;
  }

  function screenBounds(el) {
    const bounds = drawing()?.bounds(el, camera.scale);
    if (!bounds) return null;
    const origin = pane.getBoundingClientRect();
    const left = origin.left + camera.tx + bounds.x * camera.scale;
    const top = origin.top + camera.ty + bounds.y * camera.scale;
    return { left, top, width: bounds.width * camera.scale, height: bounds.height * camera.scale,
      right: left + bounds.width * camera.scale, bottom: top + bounds.height * camera.scale };
  }

  function selectGraphNode(node, arrow) { drawing()?.selection(node, arrow, camera.scale); }
  function hoverGraphEdge(edge) { drawing()?.hover(edge); }
  function edgeAt(x, y) { return drawing()?.hit((x - camera.tx) / camera.scale, (y - camera.ty) / camera.scale, camera.scale); }

  function fileAt(x, y) {
    const r = pane.getBoundingClientRect();
    return drawing()?.fileAt((x - r.left - camera.tx) / camera.scale, (y - r.top - camera.ty) / camera.scale);
  }

  let painting = null;

  function paint() {
    if (painting) return;
    const queued = renderTrace.begin();
    painting = requestAnimationFrame(() => {
      renderTrace.end('raf-wait', queued);
      painting = null;
      repaint();
    });
  }

  function repaint() {
    const traceStart = renderTrace.frameStart();
    const current = drawing();
    if (!current) return;
    const { svg } = current;
    if (!navigating && (svg !== paintedSvg || camera.scale !== paintedScale)) {
      paintedSvg = svg;
      paintedScale = camera.scale;
      renderTrace.measure('repaint-hook', onRepaint);
    }
    current.render(view(), navigating);
    renderTrace.end('graph-repaint', traceStart, {scale: camera.scale, navigating});

  }

  function zoomAt(factor, cx, cy) {
    if (!camera.zoom(factor, cx, cy)) return;
    navigateBriefly(); paint();
  }

  function fit() {
    const current = drawing();
    if (!current) return;
    const { width: w, height: h } = current;
    if (!w || !h) return;
    navigateBriefly();
    camera.fit(pane.clientWidth, pane.clientHeight, w, h);
    repaint();
  }

  pane.addEventListener('wheel', (e) => {
    renderTrace.input(e);
    const traceStart = renderTrace.begin();
    e.preventDefault();
    const r = pane.getBoundingClientRect();

    const k = Math.exp(-e.deltaY * (e.ctrlKey ? 0.01 : 0.002));
    zoomAt(k, e.clientX - r.left, e.clientY - r.top);
    renderTrace.end('wheel-handler', traceStart);
  }, { passive: false });

  let dragging = null;
  pane.addEventListener('pointerdown', (e) => {
    if (e.button !== 0) return;
    dragging = { x: e.clientX - camera.tx, y: e.clientY - camera.ty, pointerId: e.pointerId, startX: e.clientX, startY: e.clientY, moved: false };
    beginNavigation();
    pane.setPointerCapture(e.pointerId);
    pane.classList.add('panning');
  });
  pane.addEventListener('pointermove', (e) => {
    if (!dragging) { pane.style.cursor = fileAt(e.clientX, e.clientY) ? 'pointer' : ''; return; }
    if (dragging.pointerId !== e.pointerId) return;
    renderTrace.input(e);
    const traceStart = renderTrace.begin();
    if (Math.hypot(e.clientX - dragging.startX, e.clientY - dragging.startY) > 4) dragging.moved = true;
    camera.move(e.clientX - dragging.x, e.clientY - dragging.y);
    paint();
    renderTrace.end('pan-handler', traceStart);
  });
  for (const done of ['pointerup', 'pointercancel', 'lostpointercapture']) {
    pane.addEventListener(done, (e) => {
      if (!dragging || dragging.pointerId !== e.pointerId) return;
      const clicked = done === 'pointerup' && !dragging.moved ? fileAt(e.clientX, e.clientY) : null;
      dragging = null;
      if (clicked) onFileClick(clicked, { x: e.clientX, y: e.clientY });
      pane.classList.remove('panning');
      endNavigation();
    });
  }

  document.addEventListener('keydown', (e) => {

    if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') return;
    if (!(e.metaKey || e.ctrlKey)) return;
    const c = { x: pane.clientWidth / 2, y: pane.clientHeight / 2 };
    if (e.key === '0') { e.preventDefault(); fit(); }
    else if (e.key === '+' || e.key === '=') { e.preventDefault(); zoomAt(1.2, c.x, c.y); }
    else if (e.key === '-') { e.preventDefault(); zoomAt(1 / 1.2, c.x, c.y); }
  });

  function panBy(dx, dy) {
    if (!dx && !dy) return;
    navigateBriefly();
    camera.pan(dx, dy);
    repaint();
  }

  function isTouched() { return camera.touched; }

  function hatchFolded() {
    const svg = pane.querySelector('svg');
    if (!svg) return;
    for (const g of svg.querySelectorAll('g.folded')) {
      const shape = g.querySelector('ellipse, polygon, path');
      const ink = shape && shape.getAttribute('stroke');
      if (ink) shape.setAttribute('fill', `url(#fold-${ink.replace('#', '')})`);
    }
  }

  new ResizeObserver(paint).observe(pane);

  function fitSoon() { requestAnimationFrame(() => requestAnimationFrame(fit)); }

  return {pane, paint, repaint, fit, fitSoon, isTouched, hatchFolded, view, zoomAt, panBy,
    drawing, screenBounds, selectGraphNode, hoverGraphEdge, edgeAt, fileAt, renderedScale,
    get scale() { return camera.scale; }, get navigating() { return navigating; }, get dragging() { return dragging; }};
}
