import * as transport from './transport.js';
import * as latency from './latency.js';
import { makeTerminal } from './term.js';
import { pane, fit, isTouched } from './graph.js';
import { changed, renders, renderNow } from './state.js';

let deps = {};
export function wire(parts) { Object.assign(deps, parts); }

const panelsByRoot = new Map();

export function makePanel(root, options = {}) {
  const bar = root.querySelector('.bar');

  root.style.width = options.width || 'min(46rem, 92vw)';
  const body = root.querySelector('.panel-body');
  const grip = root.querySelector('.grip');

  function grab(handle, onMove, onDrop) {
    handle.addEventListener('pointerdown', (e) => {
      if (e.button !== 0) return;

      if (e.target.closest && e.target.closest('.label')) return;
      e.preventDefault();
      e.stopPropagation();

      raise(root);
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
      handle.addEventListener('pointermove', move);
      handle.addEventListener('pointerup', drop);
      handle.addEventListener('pointercancel', drop);
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
         railDrag(panel);
       },
       (moved) => { if (moved) railDrop(panel); });
  grab(grip,
       (dx, dy, from) => {
         const w = Math.max(options.minWidth || 240, from.w + dx);
         const h = Math.max(options.minHeight || 120, from.h + dy);
         root.style.width = w + 'px';
         root.style.height = h + 'px';
         if (options.onResize) options.onResize(w, h);

         showEdges(nearEdges(root));
       },
       () => {

         const landing = nearEdges(root);
         if (landing.length) {
           const box = root.getBoundingClientRect();
           const want = Object.assign({}, ...landing.map((name) => EDGES[name].fill(box)));
           if (want.height !== undefined) {
             root.style.height = Math.max(options.minHeight || 120, want.height) + 'px';
           }

           if (!onRail(panel)) root.dataset.snapped = landing.join(' ');
           const now = root.getBoundingClientRect();
           if (options.onResize) options.onResize(now.width, now.height);
         } else {

           delete root.dataset.snapped;
         }
         showEdges([]);
       });

  const panel = {
    root, bar, body, grip,
    place,
    get shut() { return root.classList.contains('shut'); },
    open() { if (panel.shut) bar.click(); },
    toggle() { bar.click(); },

    resized() {
      const box = root.getBoundingClientRect();
      if (options.onResize) options.onResize(box.width, box.height);
    },

    focus() {
      if (root.classList.contains('shut')) return;
      if (options.onOpen) options.onOpen(panel);
    },
  };
  panelsByRoot.set(root, panel);

  const label = bar.querySelector('.label');
  if (label) {

    label.addEventListener('mousedown', (e) => e.stopPropagation());
    label.addEventListener('click', (e) => e.stopPropagation());

    label.style.userSelect = 'text';

    const commit = () => {
      const text = label.textContent.replace(/\s+/g, ' ').trim();
      label.textContent = text;
      if (text === (label.dataset.saved || '')) return;
      label.dataset.saved = text;
      if (options.onLabel) options.onLabel(text);
    };

    label.addEventListener('keydown', (e) => {
      e.stopPropagation();
      if (e.key === 'Enter') { e.preventDefault(); commit(); label.blur(); }
      if (e.key === 'Escape') {
        e.preventDefault();
        label.textContent = label.dataset.saved || '';
        label.blur();
      }
    });
    label.addEventListener('focus', () => {
      label.dataset.saved = label.textContent;
    });
    label.addEventListener('blur', () => {
      commit();
    });
  }
  panel.label = label;

  panel.setLabel = (text) => {
    if (!label) return;
    label.textContent = text || '';
    label.dataset.saved = label.textContent;
  };

  bar.addEventListener('click', (e) => {

    if (bar.dragged) { bar.dragged = false; return; }

    if (e.target.closest && e.target.closest('.label')) return;
    const opening = root.classList.contains('shut');
    root.classList.toggle('shut', !opening);
    if (opening) {
      raise(root);

      if (!root.style.height) root.style.height = options.height || '22rem';
      if (options.onOpen) options.onOpen(panel);
    } else if (options.onShut) {
      options.onShut(panel);
    }

    if (onRail(panel)) packRail();
  });

  return panel;
}

let topmost = 5;
export function raise(root) { root.style.zIndex = ++topmost; }

export let configPanel = null;
export function makeConfigPanel(root, onOpen) {
  configPanel = makePanel(root, {
    minWidth: 240, minHeight: 120, onOpen,
    onLabel: (text) => saveLabel('config', text),
  });
  configPanel.setLabel((window.PANE_LABELS || {}).config || '');
  return configPanel;
}

export const inset = 12;

document.addEventListener('keydown', (e) => {
  if (e.key !== 'Escape') return;
  if (!configPanel || configPanel.shut) return;
  if (!configPanel.root.contains(document.activeElement)) return;
  e.preventDefault();

  document.activeElement.blur();
  configPanel.toggle();
});

export function makeTerminalPane(root, prefix) {
  const stateLine = root.querySelector('.state');
  const nameLabel = root.querySelector('.name');
  const screen = root.querySelector('.screen');

  const paneBody = root.querySelector('.panel-body');

  let following = true;
  screen.addEventListener('scroll', () => {
    following = screen.scrollTop + screen.clientHeight
      >= screen.scrollHeight - 4;
  });

  let paintedLines = 0;

  let lastKey = 0;
  if (latency.enabled) screen.addEventListener('keydown', (event) => {
    lastKey = performance.now();
    latency.record('key-dispatch', lastKey - event.timeStamp, prefix);
  }, true);

  const term = makeTerminal(screen, {
    pane: prefix,
    onPaint: (lines) => {
      const grew = lines !== paintedLines;
      paintedLines = lines;
      if (grew && following) screen.scrollTop = screen.scrollHeight;
    },

    onData: (bytes) => { sendInput(bytes); },
  });

  let at = 0;
  let generation = 0;
  let unsubscribe = null;
  let inputFault = '';

  async function post(path, body = {}, timeoutMs = 15000, traceId = 0) {
    const began = latency.enabled ? performance.now() : 0;
    const out = await transport.request(prefix, path, body, timeoutMs);
    if (latency.enabled) {
      latency.record(path + '-rpc', performance.now() - began, prefix, traceId);
      if (out?._trace) for (const [kind, ms] of Object.entries(out._trace)) latency.record(kind, ms, prefix, traceId);
    }
    return out;
  }

  let cell = null;
  function cellSize() {
    if (cell) return cell;
    const probe = document.createElement('span');
    probe.textContent = 'M';
    probe.style.cssText = 'position:absolute;visibility:hidden;white-space:pre';
    screen.appendChild(probe);
    const box = probe.getBoundingClientRect();
    probe.remove();
    cell = { w: box.width || 7, h: box.height || 16 };
    return cell;
  }

  function measure() {
    const { w: cw, h: ch } = cellSize();
    return {
      rows: Math.max(4, Math.floor((paneBody.clientHeight - 24) / ch)),
      cols: Math.max(20, Math.floor((paneBody.clientWidth - 12) / cw)),
    };
  }

  function setState(text) { stateLine.textContent = text; }

  function setProgram(name) {
    if (!name) return;
    if (nameLabel.textContent === name) return;
    nameLabel.textContent = name;

    if (typeof packRail === 'function') packRail();
  }

  function setName(argv) {
    if (!Array.isArray(argv) || !argv.length) return;

    nameLabel.textContent = String(argv[0]).split('/').filter(Boolean).pop();
  }

  function writeOutput(out) {
    if (!out.text) return;
    if (out.encoding === 'base64') term.write(Uint8Array.from(atob(out.text), c => c.charCodeAt(0)));
    else term.write(out.text);
  }

  function receive(out) {
    if (out.reachable === false) {
      if (out.absent) { setState('exited'); stopPolling(); }
      else setState(out.error || 'reconnecting...');
      return { at, generation };
    }
    setProgram(out.program);
    if (out.generation !== generation) {
      generation = out.generation;
      at = 0;
      term.reset();
    }
    if (out.at > at) {
      if (out.from > at && at > 0) {
        term.reset();
        post('redraw').catch(() => {});
      }
      writeOutput(out);
      at = out.at;
    }
    setState(inputFault || (out.running ? '' : 'exited'));
    if (!out.running) stopPolling();
    return { at, generation };
  }

  function startPolling() {
    if (unsubscribe) return;
    unsubscribe = transport.subscribe(prefix, { at, generation }, receive, setState);
  }

  function stopPolling() {
    if (unsubscribe) unsubscribe();
    unsubscribe = null;
  }

  screen.addEventListener('mousedown', () => {
    setTimeout(() => {
      if (!window.getSelection().toString()) term.focus();
    }, 0);
  });

  function sendInput(text, quiet) {
    if (!text) return Promise.resolve();
    const queued = latency.enabled ? performance.now() : 0;
    const sent = [];
    for (let offset = 0; offset < text.length;) {
      let end = Math.min(text.length, offset + 16384);
      if (end < text.length && text.charCodeAt(end - 1) >= 0xd800 && text.charCodeAt(end - 1) <= 0xdbff) end--;
      const chunk = text.slice(offset, end);
      offset = end;
      const traceId = latency.nextId();
      if (latency.enabled) {
        latency.record('input-queue', performance.now() - queued, prefix, traceId);
        if (lastKey) { latency.record('key-to-data', queued - lastKey, prefix, traceId); lastKey = 0; }
      }
      sent.push(post('input', { text: chunk, generation, quiet: !!quiet }, 15000, traceId)
        .then(() => { if (latency.enabled) latency.record('input-total', performance.now() - queued, prefix, traceId); })
        .catch(error => {
          if (latency.enabled) latency.record('input-error', performance.now() - queued, prefix, traceId);
          inputFault = error.message;
          setState(inputFault);
        }));
    }
    return Promise.all(sent);
  }

  screen.addEventListener('wheel', (event) => {

    if (event.defaultPrevented) return;

    if (screen.classList.contains('has-scrollback')) return;
    event.preventDefault();

    sendInput(event.deltaY < 0 ? '\x1b[5~' : '\x1b[6~');
  }, { passive: false });

  const termPanel = makePanel(root, {
    minWidth: 360, minHeight: 200,
    width: 'min(52rem, 94vw)', height: '24rem',
    onLabel: (text) => saveLabel(prefix, text),

    onOpen: async () => {
      term.focus();

      await new Promise(r => setTimeout(r, 50));

      if (termPanel.shut) return;

      await termPanel.boot();
      syncSize();
      startPolling();

      post('redraw', {}).catch(() => {});
    },

    onShut: () => stopPolling(),
    onResize: () => syncSize(),
  });

  let sizing = null;
  function syncSize() {
    cell = null;
    clearTimeout(sizing);
    sizing = setTimeout(() => {
      const size = measure();
      if (term.resize(size.rows, size.cols)) {
        post('resize', size).catch(() => {});
      }
    }, 150);
  }

  window.addEventListener('resize', () => { if (!termPanel.shut) syncSize(); });

  for (const signal of ['visibilitychange', 'focus', 'online']) {
    window.addEventListener(signal, () => {
      if (document.hidden || termPanel.shut || generation === 0) return;
      startPolling();
    });
  }

  termPanel.type = (text) => { if (text) sendInput(text); };

  let booting = null;
  termPanel.boot = () => {
    if (generation) return Promise.resolve();
    if (booting) return booting;
    booting = (async () => {
      try {
        const now = await post('poll', { at: 0, generation: 0 });
        if (now.running) {
          generation = now.generation;
          setProgram(now.program);
          term.resize(now.rows || 24, now.cols || 80);
          writeOutput(now);
          at = now.at;
        } else {
          if (now.reachable === false && !now.absent) throw new Error('supervisor unreachable');
          const out = await post('start', { rows: 24, cols: 80 });
          generation = out.generation;
          at = 0;
          setName(out.argv);
        }
        if (!termPanel.shut) startPolling();
      } catch (error) { setState(error.message); }
    })().finally(() => { booting = null; });
    return booting;
  };

  termPanel.stop = async () => {
    stopPolling();
    try { await post('stop', {}); } catch (e) {                              }
    try { await post('shutdown', {}); } catch (e) {                }
  };

  termPanel.setLabel((window.PANE_LABELS || {})[prefix] || '');
  return termPanel;
}

const harnessPane = makeTerminalPane(document.getElementById('harness'), 'harness');

async function saveLabel(id, text) {
  try {
    await fetch(`/label?k=${encodeURIComponent(window.TOKEN)}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ id, text }),
    });
  } catch (_) {

  }
}

export let paneCount = 1;
export const extraPanes = [];

const TAB_GAP = 6;
const RAIL_TOP = TAB_GAP;
const RAIL_GRAB = 56;
const RAIL_LEFT = TAB_GAP;

export const rail = [];

export function onRail(panel) { return rail.includes(panel); }

function railSpan(p) {

  return p.root.getBoundingClientRect().width;
}

function railShape() {
  return rail.map(railSpan).join(',');
}

const railState = {
  scroll: 0,
  end: 0,
  spans: new Map(),

  dragging: null,

  widths: '',

  scrolling: false,
};

function measureRail() {
  railState.spans = new Map(rail.map((p) => [p, railSpan(p)]));
  railState.widths = railShape();
}

function placeRail() {
  const at = new Map();
  let x = RAIL_LEFT + railState.scroll;
  for (const p of rail) {
    at.set(p, x);
    x += (railState.spans.get(p) || 0) + TAB_GAP;
  }
  railState.end = x - TAB_GAP - railState.scroll;
  return at;
}

export function packRail() { changed(); }

renders(packRailNow);

export function packRailNow() {

  unscrollPage();
  measureRail();

  placeRail();
  if (railState.end) {
    const most = railOverflows() ? Math.min(0, (innerWidth - RAIL_LEFT) - railState.end) : 0;
    railState.scroll = Math.max(most, Math.min(0, railState.scroll));
  }

  const chosen = railState.scrolling ? null : pickedPanel();
  if (chosen && rail.includes(chosen) && railOverflows()) {
    const at = placeRail().get(chosen);
    const over = at + (railState.spans.get(chosen) || 0) - innerWidth;
    const most = Math.min(0, (innerWidth - RAIL_LEFT) - railState.end);
    let want = railState.scroll;
    if (at < RAIL_LEFT) want = railState.scroll + (RAIL_LEFT - at);
    else if (over > 0) want = railState.scroll - over;
    railState.scroll = Math.max(most, Math.min(0, want));
  }
  renderRail();
}

function renderRail() {
  const at = placeRail();
  rail.forEach((p, i) => {
    const held = p.root === railState.dragging;
    if (!held) p.place(at.get(p), RAIL_TOP, true);
  });
}

function railOverflows() { return railState.end > innerWidth - RAIL_LEFT; }

function scrollRail(by) {

  measureRail();
  placeRail();
  if (!railOverflows()) {
    if (railState.scroll === 0) return false;
    railState.scroll = 0;
    packRail();
    return true;
  }

  const most = Math.min(0, (innerWidth - RAIL_LEFT) - railState.end);
  const next = Math.max(most, Math.min(0, railState.scroll + by));
  if (next === railState.scroll) return false;
  railState.scroll = next;

  packRail();
  return true;
}

function unscrollPage() {
  if (window.scrollX !== 0 || window.scrollY !== 0) window.scrollTo(0, 0);
}

export function revealTab(panel) {
  if (!panel) return;
  unscrollPage();
  packRail();
}

let scrollRelease = 0;

window.addEventListener('wheel', (e) => {

  if (e.clientY > RAIL_TOP + railHeight()) return;

  const by = Math.abs(e.deltaX) > Math.abs(e.deltaY) ? -e.deltaX : -e.deltaY;

  railState.scrolling = true;
  clearTimeout(scrollRelease);
  scrollRelease = setTimeout(() => { railState.scrolling = false; }, 400);
  if (scrollRail(by)) e.preventDefault();
}, { passive: false });

window.addEventListener('resize', () => { scrollRail(0); });

function railChanged() {
  const now = railShape();
  if (now === railState.widths) return false;
  railState.widths = now;
  return true;
}
setInterval(() => {
  if (railState.dragging) return;
  unscrollPage();
  if (railChanged()) packRail();

  resnap();

}, 250);

export function addToRail(panel, at) {
  if (onRail(panel)) return;
  rail.splice(at === undefined ? rail.length : at, 0, panel);
  packRail();
}

function removeFromRail(panel) {
  const at = rail.indexOf(panel);
  if (at < 0) return;
  rail.splice(at, 1);
  packRail();

}

const bin = document.createElement('div');
bin.id = 'bin';
bin.innerHTML =
  '<svg viewBox="0 0 48 52" aria-hidden="true">' +

  '<g class="lid"><rect x="6" y="8" width="36" height="6" rx="2"/>' +
  '<rect x="19" y="3" width="10" height="5" rx="2"/></g>' +

  '<path class="can" d="M9 17 h30 l-3 31 a3 3 0 0 1 -3 3 h-18 a3 3 0 0 1 -3 -3 z"/>' +
  '<g class="ribs"><line x1="18" y1="24" x2="17" y2="44"/>' +
  '<line x1="24" y1="24" x2="24" y2="44"/>' +
  '<line x1="30" y1="24" x2="31" y2="44"/></g>' +
  '</svg>';
document.body.appendChild(bin);

function overBin(panel) {
  if (!bin.classList.contains('up')) return false;
  const b = panel.root.querySelector('.bar').getBoundingClientRect();
  const t = bin.getBoundingClientRect();
  return b.left < t.right && b.right > t.left && b.top < t.bottom && b.bottom > t.top;
}

function binEat(panel) {

  bin.classList.add('up', 'fed');
  setTimeout(() => bin.classList.remove('up', 'fed'), 420);
  removeFromRail(panel);
  const at = extraPanes.indexOf(panel);
  if (at >= 0) extraPanes.splice(at, 1);

  if (panel.root.classList.contains('picked')) selectPane(configPanel.root);
  packRail();
  if (panel.stop) panel.stop();
  panel.root.remove();
}

const EDGE_GRAB = 48;

export const EDGES = {
  floor: {
    near: (box) => box.bottom >= innerHeight - EDGE_GRAB,

    fill: (box) => ({ height: innerHeight - box.top }),
  },
};

const edgeMarks = {};
for (const name of Object.keys(EDGES)) {
  const mark = document.createElement('div');
  mark.id = name + '-mark';
  mark.className = 'edge-mark';
  mark.innerHTML = '<i></i>';
  document.body.appendChild(mark);
  edgeMarks[name] = mark;
}

export function resnap() {
  let moved = false;
  for (const root of document.querySelectorAll('.panel[data-snapped]')) {
    const names = root.dataset.snapped.split(' ').filter(Boolean);
    if (!names.length) continue;

    if (root.classList.contains('shut')) continue;

    const panel = panelsByRoot.get(root);

    const box = root.getBoundingClientRect();
    const want = Object.assign({}, ...names.map((name) => EDGES[name] && EDGES[name].fill(box)));
    if (want.height === undefined) continue;

    const h = Math.max(120, want.height);

    const top = h > innerHeight - box.top ? Math.max(0, innerHeight - h) : box.top;
    const wantsHeight = Math.abs(box.height - h) > 0.5;
    const wantsTop = Math.abs(box.top - top) > 0.5;
    if (!wantsHeight && !wantsTop) continue;

    if (wantsHeight) root.style.height = h + 'px';
    if (wantsTop) root.style.top = top + 'px';
    moved = true;

    if (panel && panel.resized) panel.resized();
  }
  return moved;
}

function nearEdges(root) {
  const box = root.getBoundingClientRect();
  return Object.keys(EDGES).filter((name) => EDGES[name].near(box));
}

function showEdges(names) {
  for (const name of Object.keys(EDGES)) {
    edgeMarks[name].classList.toggle('near', names.includes(name));
  }
}

const railMarks = document.createElement('div');
railMarks.id = 'rail-marks';
railMarks.innerHTML = '<i></i><i></i>';
document.body.appendChild(railMarks);

function railHeight() {
  const anyBar = document.querySelector('.panel .bar');
  return anyBar ? anyBar.offsetHeight : 28;
}

function showRails(near) {
  railMarks.style.top = RAIL_TOP + 'px';
  railMarks.style.height = railHeight() + 'px';
  railMarks.classList.toggle('near', !!near);
}

function overRail(panel) {
  const bar = panel.root.querySelector('.bar').getBoundingClientRect();
  return Math.abs(bar.top - RAIL_TOP) <= RAIL_GRAB;
}

function slotFor(panel) {
  const bar = panel.root.querySelector('.bar').getBoundingClientRect();
  const mid = bar.left + bar.width / 2;
  const others = rail.filter(p => p !== panel);
  let at = others.length;
  for (let i = 0; i < others.length; i++) {
    const b = others[i].root.querySelector('.bar').getBoundingClientRect();
    if (mid < b.left + b.width / 2) { at = i; break; }
  }
  return at;
}

function railDrag(panel) {
  railState.dragging = panel.root;

  bin.classList.toggle('up', !!panel.stop);
  bin.classList.toggle('open', overBin(panel));
  const near = overRail(panel);
  showRails(near);
  if (!near) return;

  const at = slotFor(panel);
  const was = rail.indexOf(panel);
  if (was >= 0 && was !== at) {
    rail.splice(was, 1);
    rail.splice(at, 0, panel);
    packRail();
  } else if (was < 0) {
    rail.splice(at, 0, panel);
    packRail();
  }
}

function railDrop(panel) {
  railState.dragging = null;
  railMarks.classList.remove('near');

  const eaten = overBin(panel);
  bin.classList.remove('up', 'open');
  if (eaten) { binEat(panel); return; }

  if (overRail(panel)) {
    if (!onRail(panel)) addToRail(panel, slotFor(panel));
    packRail();
  } else {

    removeFromRail(panel);

    const box = panel.root.getBoundingClientRect();
    const edge = 28;
    if (box.right < edge) panel.place(edge - box.width, box.top);
    else if (box.left > innerWidth - edge) panel.place(innerWidth - edge, box.top);
  }
}

export function selectPane(root) {
  for (const p of document.querySelectorAll('.panel.picked')) {
    p.classList.remove('picked');
  }
  if (root) {
    root.classList.add('picked');

    raise(root);

    packRail();
  }

  if (deps.refitCompose) deps.refitCompose();
}

export function pickedPanel() {
  const root = document.querySelector('.panel.picked');
  return (root && panelsByRoot.get(root)) || configPanel;
}

document.addEventListener('pointerdown', (e) => {
  const inPanel = e.target.closest && e.target.closest('.panel');
  if (inPanel) selectPane(inPanel);
}, true);

const paneTemplate = (() => {
  const copy = document.getElementById('harness').cloneNode(true);

  copy.querySelector('.screen').textContent = '';
  copy.querySelector('.state').textContent = '';
  copy.classList.remove('picked');
  return copy;
})();

function reopenTerminal(id) {
  const pane = buildTerminal(id);
  addToRail(pane);

  pane.boot();
  return pane;
}

function buildTerminal(id) {
  const root = paneTemplate.cloneNode(true);
  root.id = 'pane-' + id;
  root.classList.add('shut');
  root.querySelector('.screen').textContent = '';
  root.querySelector('.state').textContent = '';
  root.querySelector('.name').textContent = 'terminal ' + id;

  root.style.cssText = '';
  document.body.appendChild(root);

  const pane = makeTerminalPane(root, id);
  extraPanes.push(pane);
  return pane;
}

export function openTerminal() {
  const id = String(++paneCount);
  const pane = buildTerminal(id);
  selectPane(pane.root);

  addToRail(pane);

  pane.boot();

  pane.open();
  return pane;
}

document.getElementById('term-new')
  .addEventListener('click', () => { openTerminal(); });

document.addEventListener('keydown', (e) => {
  if (e.key !== 't' && e.key !== 'T') return;
  if (e.altKey) return;
  const el = document.activeElement;
  const inTerm = !!(el && el.closest && el.closest('.term'));
  if (e.metaKey || (e.ctrlKey && !inTerm)) {
    e.preventDefault();
    openTerminal();
  }
}, true);

export function startRail() {

  addToRail(configPanel);
  addToRail(harnessPane);
  harnessPane.boot();

  for (const id of (window.OPEN_TERMINALS || [])) {
    const n = Number(id);
    if (Number.isFinite(n) && n > paneCount) paneCount = n;
    reopenTerminal(String(id));
  }

    selectPane(configPanel.root);
}
