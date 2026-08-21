// The page's state, and the one loop that draws it.
//
// DECLARATIVE, WITHOUT A DIFF ENGINE. Every component keeps its state in a
// plain object here and offers one `render(state)` that reads that object and
// writes the DOM. Nothing else touches the DOM. To change what the page shows
// you change the state and say so; the loop does the rest.
//
// A DIFF ENGINE IS FOR TREES YOU CANNOT PREDICT. React diffs because it
// re-renders whole subtrees and has to discover what moved. This page has a
// fixed cast -- a row of tabs, a graph transform, a bin, some marks -- so a
// render can set each property outright. Setting a property to the value it
// already holds costs nothing: the browser compares and skips the work, which
// is the same saving a diff would have bought, already written in C.
//
// ONE WRITE PHASE PER FRAME. Mutations mark the page dirty and return; a
// single `requestAnimationFrame` calls every render once. That is what keeps
// reads and writes apart -- the six functions this replaces each measured a
// rectangle, wrote a style, and measured again, and every one of them has
// been a bug. A render may not read layout at all; whatever it needs to know
// must already be in the state.

// -- the frame ---------------------------------------------------------------

const renderers = [];
let dirty = false;
let frame = 0;

// A BACKGROUND TAB DRAWS NOTHING, and needs no help to. `requestAnimationFrame`
// stops while the tab is hidden, which is exactly right: nobody is looking, so
// nothing should be painted. The dirty flag stays set and the first frame after
// the tab comes back draws whatever accumulated -- one render for the lot,
// rather than a timer keeping a hidden page up to date for no one.
//
// (What DOES bite in a hidden tab is measuring it: rects read zero and
// transitions never finish. That is a rule for code that measures -- make the
// page paint first -- and not something this loop can fix.)
function flush() {
  frame = 0;
  if (!dirty) return;
  dirty = false;
  // EVERY RENDER, EVERY TIME, rather than tracking which component is stale.
  // There are a handful of them and each is a short walk over elements it
  // already holds; the bookkeeping to render fewer would cost more than the
  // renders it saved.
  for (const render of renderers) render();
}

function schedule() {
  if (!frame) frame = requestAnimationFrame(flush);
}

// SAY THE PAGE CHANGED. Called after mutating any state object; the render
// happens on the next frame rather than here, so a burst of changes in one
// turn -- a walk that shuts one tab, opens another and moves the row -- costs
// one write phase instead of three.
export function changed() {
  dirty = true;
  schedule();
}

// A component's render, run on every frame the page is dirty. Registered once
// at module load; there is no unregistering because nothing on this page goes
// away.
export function renders(fn) {
  renderers.push(fn);
  return fn;
}

// DRAW NOW, for the cases that cannot wait a frame: a fresh SVG that would
// otherwise flash at the wrong scale, and the tests, which have no frames to
// wait for. Ordinary changes should use `changed`.
export function renderNow() {
  dirty = true;
  flush();
}
