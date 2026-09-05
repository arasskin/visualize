const renderers = [];
let dirty = false;
let frame = 0;

function flush() {
  frame = 0;
  if (!dirty) return;
  dirty = false;

  for (const render of renderers) render();
}

function schedule() {
  if (!frame) frame = requestAnimationFrame(flush);
}

export function changed() {
  dirty = true;
  schedule();
}

export function renders(fn) {
  renderers.push(fn);
  return fn;
}

export function renderNow() {
  dirty = true;
  flush();
}
