import {createCamera} from './camera.js';
export function svgViewport(container, {onPaint = () => {}} = {}) {
  const camera = createCamera();
  let svg = null, layer = null, bounds = null;
  let dragging = null, frame = null, stopped = false;
  const listeners = new AbortController();
  container.tabIndex = 0;
  container.setAttribute('aria-label', 'Graph: drag to pan, scroll to zoom');
  function paint() {
    if (frame !== null || stopped) return;
    frame = requestAnimationFrame(() => {
      frame = null;
      layer?.setAttribute('transform', `translate(${camera.tx} ${camera.ty}) scale(${camera.scale}) translate(${-bounds.x} ${-bounds.y})`);
      onPaint();
    });
  }
  function fit() {
    const width = container.clientWidth, height = container.clientHeight;
    if (!bounds?.width || !bounds.height || !width || !height) return;
    camera.fit(width, height, bounds.width, bounds.height); paint();
  }
  function resize() {
    if (!svg || !container.clientWidth || !container.clientHeight) return;
    svg.setAttribute('viewBox', `0 0 ${container.clientWidth} ${container.clientHeight}`);
    if (!camera.touched) fit(); else paint();
  }
  function zoomAt(factor, x, y) {
    if (!bounds) return;
    camera.zoom(factor, x, y); paint();
  }
  container.addEventListener('wheel', event => {
    if (!svg) return;
    event.preventDefault(); event.stopPropagation();
    const box = container.getBoundingClientRect();
    zoomAt(Math.exp(-event.deltaY * (event.ctrlKey ? .01 : .002)), event.clientX - box.left, event.clientY - box.top);
  }, {passive: false, signal: listeners.signal});
  container.addEventListener('pointerdown', event => {
    if (!svg || event.button !== 0 || dragging || event.target.closest('[role="button"], button, a, input, textarea')) return;
    event.preventDefault(); container.focus({preventScroll: true});
    dragging = {id: event.pointerId, x: event.clientX - camera.tx, y: event.clientY - camera.ty};
    container.setPointerCapture(event.pointerId); container.classList.add('panning');
  }, {signal: listeners.signal});
  container.addEventListener('pointermove', event => {
    if (!dragging || dragging.id !== event.pointerId) return;
    camera.move(event.clientX - dragging.x, event.clientY - dragging.y); paint();
  }, {signal: listeners.signal});
  function end(event) {
    if (!dragging || dragging.id !== event.pointerId) return;
    dragging = null; container.classList.remove('panning');
    if (container.hasPointerCapture(event.pointerId)) container.releasePointerCapture(event.pointerId);
  }
  for (const type of ['pointerup', 'pointercancel', 'lostpointercapture']) container.addEventListener(type, end, {signal: listeners.signal});
  container.addEventListener('keydown', event => {
    if (!(event.ctrlKey || event.metaKey) || !['0', '+', '=', '-'].includes(event.key)) return;
    event.preventDefault(); event.stopPropagation();
    if (event.key === '0') fit();
    else zoomAt(event.key === '-' ? 1 / 1.2 : 1.2, container.clientWidth / 2, container.clientHeight / 2);
  }, {signal: listeners.signal});
  const observer = new ResizeObserver(resize); observer.observe(container);
  return {
    bounds(element) {
      const box = element.getBBox();
      const matrix = layer.getCTM().inverse().multiply(element.getCTM());
      const points = [[box.x, box.y], [box.x + box.width, box.y], [box.x, box.y + box.height], [box.x + box.width, box.y + box.height]]
        .map(([x, y]) => new DOMPoint(x, y).matrixTransform(matrix));
      const x = Math.min(...points.map(point => point.x)) - bounds.x;
      const y = Math.min(...points.map(point => point.y)) - bounds.y;
      return {x, y, width: Math.max(...points.map(point => point.x)) - bounds.x - x,
        height: Math.max(...points.map(point => point.y)) - bounds.y - y};
    },
    project: camera.project,
    anchor(box, point = {x: container.clientWidth / 2, y: container.clientHeight / 2}) { camera.anchor(box, point); paint(); },
    setSvg(next) {
      svg = next;
      const box = svg.viewBox.baseVal;
      bounds = {x: box.x, y: box.y, width: box.width, height: box.height};
      layer = document.createElementNS('http://www.w3.org/2000/svg', 'g'); layer.classList.add('graph-camera');
      for (const child of [...svg.children]) if (child.localName === 'g') layer.append(child);
      svg.append(layer); svg.setAttribute('width', '100%'); svg.setAttribute('height', '100%');
      resize();
    },
    stop() {
      stopped = true; listeners.abort(); observer.disconnect();
      if (frame !== null) cancelAnimationFrame(frame);
      if (dragging && container.hasPointerCapture(dragging.id)) container.releasePointerCapture(dragging.id);
      container.classList.remove('panning'); dragging = null;
    },
  };
}
