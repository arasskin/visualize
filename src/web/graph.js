// The viewport: pan and zoom over the graph.
//
// ONE TRANSFORM on the <svg> element does the whole job. Not an iframe: the
// graph has to stay in this document for a redraw to swap it, and a
// same-origin frame would only add a postMessage hop. The graph is SVG, so it
// stays sharp at any scale.
//
// INDEPENDENT OF THE WINDOWS. Panels float over this and it does not react to
// them -- a window that grows covers some of the drawing and the drawing does
// not flinch. They used to be coupled, and the churn that caused when a walk
// opened and shut windows was behind a run of bugs in the row.
//
// WHAT IT NEEDS FROM ELSEWHERE is passed in rather than imported, because the
// things it would import -- the config editor's redraw, the find bar's arrow
// -- both import from here, and a circle of modules is a circle whichever way
// you enter it. `wire` is called once at startup with the two callbacks.

// Set by `wire`: what to do after a repaint, and what to do after a fit.
let onRepaint = () => {};
let onFit = () => {};

export function wire(hooks) {
  if (hooks.onRepaint) onRepaint = hooks.onRepaint;
  if (hooks.onFit) onFit = hooks.onFit;
}

// -- the viewport ------------------------------------------------------------
// One transform on the <svg> element does the whole job. Not an iframe: the
// graph has to stay in this document for a redraw to swap it, and a same-origin
// frame would only add a postMessage hop. The graph is SVG, so it stays
// sharp at any scale.

export const pane = document.getElementById('graph');
const zoomLabel = document.getElementById('zoom');
let zoomFade = null;
const MIN = 0.1, MAX = 10;
// `touched` tracks whether the user has moved the view themselves; an automatic
// refit must never discard a view they chose.
export let scale = 1;
let tx = 0, ty = 0, touched = false;
// The view, for anything that has to place something over the drawing in
// screen pixels -- the find arrow, mostly. Read-only to callers.
export function view() { return { scale, tx, ty }; }

// ONE WRITE PER FRAME. A trackpad fires wheel and pointermove faster than the
// display refreshes, and every one of those used to write a transform and
// force the work that follows it -- several repaints per frame, all but the
// last thrown away.
//
// The state (tx, ty, scale) is updated eagerly, so a reader still sees the
// latest values; only the DOM write waits for the frame that will show it.
export let painting = null;

export function paint() {
  if (painting) return;
  painting = requestAnimationFrame(() => {
    painting = null;
    repaint();
  });
}

export function repaint() {
  const svg = pane.querySelector('svg');
  if (!svg) return;
  svg.style.transform = `translate(${tx}px, ${ty}px) scale(${scale})`;
  // The arrow is built in screen pixels and un-scaled by the transform this
  // line just wrote. One attribute, so a zoom frame costs nothing.
  onRepaint();
  zoomLabel.textContent = Math.round(scale * 100) + '%';
  // Visible while it is changing, gone a moment later: the number matters
  // during a zoom and is clutter once the view has settled.
  zoomLabel.classList.add('active');
  clearTimeout(zoomFade);
  zoomFade = setTimeout(() => zoomLabel.classList.remove('active'), 900);
}

// Zoom about a fixed point: the graph coordinate under the cursor has to land
// back under the cursor, so the translation absorbs the scale change.
export function zoomAt(factor, cx, cy) {
  const next = Math.min(MAX, Math.max(MIN, scale * factor));
  const applied = next / scale;
  tx = cx - (cx - tx) * applied;
  ty = cy - (cy - ty) * applied;
  scale = next;
  touched = true;
  paint();
  // A ZOOM CAN CARRY THE MARK OFF THE SCREEN, since everything not under the
  // cursor swings away from it. Bring it back once the zooming stops.
  onFit();
}

export function fit() {
  const svg = pane.querySelector('svg');
  if (!svg) return;
  // Measure the element's own untransformed size, NOT getBBox(). This was
  // written because graphviz sizes the root svg in POINTS (width="2276pt"),
  // so the box it occupies is the pt->px conversion of that, ~4/3 larger than
  // the user units getBBox reports -- centring against the bbox offsets the
  // graph by that ratio. baseVal.value is the size the element OCCUPIES,
  // which is what a fit is against, whatever the units in the attribute.
  const w = svg.width.baseVal.value;
  const h = svg.height.baseVal.value;
  if (!w || !h) return;
  const pad = 24;
  scale = Math.min((pane.clientWidth - pad * 2) / w,
                   (pane.clientHeight - pad * 2) / h);
  scale = Math.min(MAX, Math.max(MIN, scale));
  tx = (pane.clientWidth - w * scale) / 2;
  ty = (pane.clientHeight - h * scale) / 2;
  // Back to a view the page chose, so a resize may reframe again.
  touched = false;
  // Immediate, like the redraw path: a fit follows a fresh SVG or a resize,
  // where a deferred frame is a visible jump rather than a smoother one.
  repaint();
}

pane.addEventListener('wheel', (e) => {
  e.preventDefault();
  const r = pane.getBoundingClientRect();
  // ctrl+wheel is what a trackpad pinch arrives as; it wants a finer step than
  // a mouse wheel notch.
  const k = Math.exp(-e.deltaY * (e.ctrlKey ? 0.01 : 0.002));
  zoomAt(k, e.clientX - r.left, e.clientY - r.top);
}, { passive: false });

export let dragging = null;
pane.addEventListener('pointerdown', (e) => {
  if (e.button !== 0) return;
  dragging = { x: e.clientX - tx, y: e.clientY - ty };
  pane.setPointerCapture(e.pointerId);
  pane.classList.add('panning');
});
pane.addEventListener('pointermove', (e) => {
  if (!dragging) return;
  tx = e.clientX - dragging.x;
  ty = e.clientY - dragging.y;
  touched = true;
  paint();
});
for (const done of ['pointerup', 'pointercancel']) {
  pane.addEventListener(done, () => {
    dragging = null;
    pane.classList.remove('panning');
  });
}

// Drops the cached scan, so the next draw re-reads the sources. The one action
// that is about the SOURCE changing rather than the config.

// The view keys take a modifier now that a bare keystroke is TEXT. `0` used
// to fit the graph, and it still does with the platform's modifier held --
// but on its own it is the first character of a line, because typing
// anywhere is the way the config is written.
document.addEventListener('keydown', (e) => {
  // The editor owns the keyboard while it has focus -- typing `(box ...)`
  // must not also zoom the graph.
  if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') return;
  if (!(e.metaKey || e.ctrlKey)) return;
  const c = { x: pane.clientWidth / 2, y: pane.clientHeight / 2 };
  if (e.key === '0') { e.preventDefault(); fit(); }
  else if (e.key === '+' || e.key === '=') { e.preventDefault(); zoomAt(1.2, c.x, c.y); }
  else if (e.key === '-') { e.preventDefault(); zoomAt(1 / 1.2, c.x, c.y); }
});

// Two frames: the pane is absolutely positioned, so its height is only real
// after layout -- fitting any earlier measures against a collapsed box and
// bottoms out at the minimum scale.
/* SHIFT THE VIEW by a screen-pixel offset, as the find bar does to bring a
   mark into the middle. Counts as a view the user chose, so an automatic
   refit will not throw it away.

   IMMEDIATE, not next frame: a caller that measures straight after this --
   the next hit in a walk, or the reveal for a second arrow -- would read the
   old transform and pan against a view that is already moving. */
export function panBy(dx, dy) {
  tx += dx;
  ty += dy;
  touched = true;
  repaint();
}

// Has the user moved the view themselves? An automatic refit must never
// discard a view they chose.
export function isTouched() { return touched; }

export function fitSoon() { requestAnimationFrame(() => requestAnimationFrame(fit)); }

