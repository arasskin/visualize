import { createRenderer } from './graph-canvas.js';
let onRepaint = () => {};
let onNavigate = () => {};

export function wire(hooks) {
  if (hooks.onRepaint) onRepaint = hooks.onRepaint;
  if (hooks.onNavigate) onNavigate = hooks.onNavigate;
}

export const pane = document.getElementById('graph');
const zoomLabel = document.getElementById('zoom');
let zoomFade = null;
let paintedScale = null;
let paintedSvg = null;
let navigationEnd = null;
export let navigating = false;
const MIN = 0.1, MAX = 10;
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

export let scale = 1;
let tx = 0, ty = 0, touched = false;

export function view() { return { scale, tx, ty }; }

export function renderedScale() { return scale; }

let currentDrawing = null;

export function drawing() {
  const svg = pane.querySelector('svg');
  if (currentDrawing?.svg === svg) return currentDrawing;
  currentDrawing?.dispose();
  currentDrawing = svg ? createRenderer(svg, paint) : null;
  return currentDrawing;
}

export function screenBounds(el) {
  const bounds = drawing()?.bounds(el);
  if (!bounds) return null;
  const origin = pane.getBoundingClientRect();
  const left = origin.left + tx + bounds.x * scale;
  const top = origin.top + ty + bounds.y * scale;
  return { left, top, width: bounds.width * scale, height: bounds.height * scale,
    right: left + bounds.width * scale, bottom: top + bounds.height * scale };
}

export function selectGraphNode(node, arrow) { drawing()?.selection(node, arrow); }
export function hoverGraphEdge(edge) { drawing()?.hover(edge); }
export function edgeAt(x, y) { return drawing()?.hit((x - tx) / scale, (y - ty) / scale, scale); }

export let painting = null;

export function paint() {
  if (painting) return;
  painting = requestAnimationFrame(() => {
    painting = null;
    repaint();
  });
}

export function repaint() {
  const current = drawing();
  if (!current) return;
  const { svg } = current;
  if (!navigating && (svg !== paintedSvg || scale !== paintedScale)) {
    paintedSvg = svg;
    paintedScale = scale;
    onRepaint();
  }
  current.render(view(), navigating);
  const label = Math.round(scale * 100) + '%';
  if (zoomLabel.textContent !== label) {
    zoomLabel.textContent = label;
    zoomLabel.classList.add('active');
    clearTimeout(zoomFade);
    zoomFade = setTimeout(() => zoomLabel.classList.remove('active'), 900);
  }
}

export function zoomAt(factor, cx, cy) {
  const next = Math.min(MAX, Math.max(MIN, scale * factor));
  if (next === scale) return;
  navigateBriefly();
  const applied = next / scale;
  tx = cx - (cx - tx) * applied;
  ty = cy - (cy - ty) * applied;
  scale = next;
  touched = true;
  paint();
}

export function fit() {
  const current = drawing();
  if (!current) return;
  const { width: w, height: h } = current;
  if (!w || !h) return;
  navigateBriefly();
  const pad = 24;
  scale = Math.min((pane.clientWidth - pad * 2) / w,
                   (pane.clientHeight - pad * 2) / h);
  scale = Math.min(MAX, Math.max(MIN, scale));
  tx = (pane.clientWidth - w * scale) / 2;
  ty = (pane.clientHeight - h * scale) / 2;

  touched = false;

  repaint();
}

pane.addEventListener('wheel', (e) => {
  e.preventDefault();
  const r = pane.getBoundingClientRect();

  const k = Math.exp(-e.deltaY * (e.ctrlKey ? 0.01 : 0.002));
  zoomAt(k, e.clientX - r.left, e.clientY - r.top);
}, { passive: false });

export let dragging = null;
pane.addEventListener('pointerdown', (e) => {
  if (e.button !== 0) return;
  dragging = { x: e.clientX - tx, y: e.clientY - ty, pointerId: e.pointerId };
  beginNavigation();
  pane.setPointerCapture(e.pointerId);
  pane.classList.add('panning');
});
pane.addEventListener('pointermove', (e) => {
  if (!dragging || dragging.pointerId !== e.pointerId) return;
  tx = e.clientX - dragging.x;
  ty = e.clientY - dragging.y;
  touched = true;
  paint();
});
for (const done of ['pointerup', 'pointercancel', 'lostpointercapture']) {
  pane.addEventListener(done, (e) => {
    if (!dragging || dragging.pointerId !== e.pointerId) return;
    dragging = null;
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

export function panBy(dx, dy) {
  if (!dx && !dy) return;
  navigateBriefly();
  tx += dx;
  ty += dy;
  touched = true;
  repaint();
}

export function isTouched() { return touched; }

export function hatchFolded() {
  const svg = pane.querySelector('svg');
  if (!svg) return;
  for (const g of svg.querySelectorAll('g.folded')) {
    const shape = g.querySelector('ellipse, polygon, path');
    const ink = shape && shape.getAttribute('stroke');
    if (ink) shape.setAttribute('fill', `url(#fold-${ink.replace('#', '')})`);
  }
}

new ResizeObserver(paint).observe(pane);

export function fitSoon() { requestAnimationFrame(() => requestAnimationFrame(fit)); }
