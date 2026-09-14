export function createCamera({minimum = .1, maximum = 10} = {}) {
  let scale = 1, tx = 0, ty = 0, touched = false;
  const clamp = value => Math.max(minimum, Math.min(maximum, value));
  return {
    get scale() { return scale; }, get tx() { return tx; }, get ty() { return ty; }, get touched() { return touched; },
    view: () => ({scale, tx, ty}),
    project(box) { return {x: tx + box.x * scale, y: ty + box.y * scale, width: box.width * scale, height: box.height * scale}; },
    zoom(factor, x, y) {
      const next = clamp(scale * factor); if (next === scale) return false;
      const ratio = next / scale; tx = x - (x - tx) * ratio; ty = y - (y - ty) * ratio;
      scale = next; touched = true; return true;
    },
    move(x, y) { tx = x; ty = y; touched = true; },
    pan(dx, dy) { tx += dx; ty += dy; touched = true; },
    anchor(box, point) { tx = point.x - (box.x + box.width / 2) * scale; ty = point.y - (box.y + box.height / 2) * scale; touched = true; },
    fit(width, height, contentWidth, contentHeight, padding = 24) {
      if (!width || !height || !contentWidth || !contentHeight) return false;
      scale = clamp(Math.min((width - padding * 2) / contentWidth, (height - padding * 2) / contentHeight));
      tx = (width - contentWidth * scale) / 2; ty = (height - contentHeight * scale) / 2;
      touched = false; return true;
    },
  };
}
