export function createPaneFrame(root, options = {}) {
  const lifetime = new AbortController();
  const listen = (target, type, handler, options = {}) => target?.addEventListener(type, handler, {...options, signal: lifetime.signal});
  const bar = root.querySelector('.bar');

  root.style.width = options.width || 'min(46rem, 92vw)';
  const body = root.querySelector('.panel-body');
  const grip = root.querySelector('.grip');
  const sideGrip = document.createElement('div');
  sideGrip.className = 'side-grip';
  sideGrip.title = 'drag to resize horizontally';
  root.appendChild(sideGrip);

  function grab(handle, onMove, onDrop) {
    listen(handle, 'pointerdown', (e) => {
      if (e.button !== 0) return;

      if (e.target.closest && e.target.closest('.label')) return;
      e.preventDefault();
      e.stopPropagation();

      options.onRaise?.();
      const box = root.getBoundingClientRect();
      const from = { x: e.clientX, y: e.clientY, w: box.width, h: box.height,
                     left: box.left, top: box.top, at: performance.now() };
      let moved = false;
      handle.setPointerCapture(e.pointerId);
      const move = (m) => {
        const dx = m.clientX - from.x, dy = m.clientY - from.y;

        if (Math.abs(dx) > 3 || Math.abs(dy) > 3) moved = true;
        if (moved) onMove(dx, dy, from);
      };
      const drop = () => {
        handle.removeEventListener('pointermove', move);
        handle.removeEventListener('pointerup', drop);
        handle.removeEventListener('pointercancel', drop);
        handle.dragged = moved;
        if (onDrop) onDrop(moved);
      };
      listen(handle, 'pointermove', move);
      listen(handle, 'pointerup', drop);
      listen(handle, 'pointercancel', drop);
    });
  }

  function place(left, top, free) {
    const w = root.offsetWidth, edge = 28;
    root.style.left = (free ? left
      : Math.min(Math.max(left, edge - w), innerWidth - edge)) + 'px';
    root.style.top = Math.min(Math.max(top, 0), innerHeight - edge) + 'px';
  }

  grab(bar,
       (dx, dy, from) => {
         place(from.left + dx, from.top + dy);
         options.onDrag?.(panel);
       },
       (moved) => { if (moved) options.onDrop?.(panel); });
  grab(grip,
      (dx, dy, from) => {
        const w = Math.max(options.minWidth || 240, from.w + dx);
        const bottom = panel.root.classList.contains('bottom-docked');
        const h = Math.max(options.minHeight || 120, from.h + (bottom ? -dy : dy));
        root.style.width = w + 'px';
        if (panel.shut) {
          options.onChange?.();
          return;
        }
         root.style.height = h + 'px';
         options.onChange?.();
         if (options.onResize) options.onResize(w, h);

         options.onResizeMove?.(panel);
       },
       () => {
         if (panel.shut || panel.root.classList.contains('bottom-docked')) return;

         options.onResizeEnd?.(panel);
       });

  grab(sideGrip,
       (dx, dy, from) => {
         const width = Math.max(options.minWidth || 240, from.w + dx);
         root.style.width = width + 'px';
         options.onChange?.();
         if (options.onResize) options.onResize(width, root.getBoundingClientRect().height);
       },
       () => {});

  const panel = {
    root, bar, body, grip, minHeight: options.minHeight || 120,
    place,
    get size() {
      const box = root.getBoundingClientRect();
      const height = root.style.height || options.height || '22rem';
      const unit = height.endsWith('rem') ? parseFloat(getComputedStyle(document.documentElement).fontSize) : 1;
      return [box.width, panel.shut ? Math.max(options.minHeight || 120, parseFloat(height) * unit) : box.height];
    },
    get shut() { return root.classList.contains('shut'); },
    open() { setOpen(true); },
    toggle() { setOpen(panel.shut); },

    resized() {
      const box = root.getBoundingClientRect();
      if (options.onResize) options.onResize(box.width, box.height);
    },

    focus() {
      if (root.classList.contains('shut')) return;
      if (options.onOpen) options.onOpen(panel);
    },
  };
  const geometry = new ResizeObserver(() => { options.onChange?.(); options.onResize?.(); });
  geometry.observe(root);
  geometry.observe(bar);
  panel.dispose = () => { lifetime.abort(); geometry.disconnect(); };
  const closeButton = bar.querySelector('.tab-close');
  listen(closeButton, 'pointerdown', event => event.stopPropagation());
  listen(closeButton, 'click', event => {
    event.stopPropagation();
    options.onClose?.(panel);
  });
  const fadeButton = bar.querySelector('.tab-fade');
  panel.setUnfaded = (enabled) => {
    root.classList.toggle('unfaded', enabled);
    fadeButton?.setAttribute('aria-pressed', String(enabled));
  };
  listen(fadeButton, 'pointerdown', event => event.stopPropagation());
  listen(fadeButton, 'click', event => {
    event.stopPropagation();
    panel.setUnfaded(!root.classList.contains('unfaded'));
    options.onChange?.();
  });

  const label = bar.querySelector('.label');
  if (label) {

    listen(label, 'mousedown', (e) => e.stopPropagation());
    listen(label, 'click', (e) => {
      if (panel.shut) { e.preventDefault(); panel.open(); }
      e.stopPropagation();
    });

    label.style.userSelect = 'text';

    const commit = () => {
      const text = label.textContent.replace(/\s+/g, ' ').trim();
      label.textContent = text;
      if (text === (label.dataset.saved || '')) return;
      label.dataset.saved = text;
      if (options.onLabel) options.onLabel(text);
    };

    listen(label, 'keydown', (e) => {
      e.stopPropagation();
      if (e.key === 'Enter') { e.preventDefault(); commit(); label.blur(); }
      if (e.key === 'Escape') {
        e.preventDefault();
        label.textContent = label.dataset.saved || '';
        label.blur();
      }
    });
    listen(label, 'focus', () => {
      label.dataset.saved = label.textContent;
    });
    listen(label, 'blur', () => {
      commit();
    });
  }
  panel.label = label;

  panel.setLabel = (text) => {
    if (!label) return;
    label.textContent = text || '';
    label.dataset.saved = label.textContent;
  };

  listen(bar, 'click', (e) => {

    if (bar.dragged) { bar.dragged = false; return; }

    if (e.target.closest && e.target.closest('.label')) return;
    setOpen(panel.shut);
  });

  function setOpen(opening) {
    if (!root.isConnected || panel.shut !== opening) return;
    if (!opening) root.style.height = root.getBoundingClientRect().height + 'px';
    root.classList.toggle('shut', !opening);
    if (opening) {
      options.onRaise?.();

      if (!root.style.height) root.style.height = options.height || '22rem';
      if (options.onOpen) options.onOpen(panel);
    } else if (options.onShut) {
      options.onShut(panel);
    }

    options.onChange?.();
  }

  return panel;
}
