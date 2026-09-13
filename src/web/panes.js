import { reportError } from './errors.js';
import { documentReader } from './document.js';
import * as transport from './transport.js';
import * as latency from './latency.js';
import { makeTerminal } from './term.js';
import { pane, fit, isTouched } from './graph.js';
import { changed, renders, renderNow } from './state.js';

let deps = {};
export function wire(parts) { Object.assign(deps, parts); }

const panelsByRoot = new Map();
const COMPACT_WIDTH = 'min(26rem, 92vw)';

export function makePanel(root, options = {}) {
  const bar = root.querySelector('.bar');

  root.style.width = options.width || 'min(46rem, 92vw)';
  const body = root.querySelector('.panel-body');
  const grip = root.querySelector('.grip');
  const sideGrip = document.createElement('div');
  sideGrip.className = 'side-grip';
  sideGrip.title = 'drag to resize horizontally';
  root.appendChild(sideGrip);

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
        const bottom = panel.root.classList.contains('bottom-docked');
        const h = Math.max(options.minHeight || 120, from.h + (bottom ? -dy : dy));
        root.style.width = w + 'px';
        if (panel.shut) {
          if (onRail(panel)) packRail();
          return;
        }
         root.style.height = h + 'px';
         if (bottom) { packRail(); }
         if (options.onResize) options.onResize(w, h);

         showEdges(bottom ? [] : nearEdges(root));
       },
       () => {
         if (panel.shut || panel.root.classList.contains('bottom-docked')) return;

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

  grab(sideGrip,
       (dx, dy, from) => {
         const width = Math.max(options.minWidth || 240, from.w + dx);
         root.style.width = width + 'px';
         if (onRail(panel)) packRail();
         if (options.onResize) options.onResize(width, root.getBoundingClientRect().height);
       },
       () => {});

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
  const closeButton = bar.querySelector('.tab-close');
  closeButton?.addEventListener('pointerdown', event => event.stopPropagation());
  closeButton?.addEventListener('click', event => {
    event.stopPropagation();
    closePanel(panel);
  });

  const label = bar.querySelector('.label');
  if (label) {

    label.addEventListener('mousedown', (e) => e.stopPropagation());
    label.addEventListener('click', (e) => {
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
    width: COMPACT_WIDTH, minWidth: 240, minHeight: 120, onOpen,
    onLabel: (text) => saveLabel('config', text),
  });
  let reader = null;
  configPanel.showDocument = file => {
    if (configPanel.documentFile === file) return;
    reader?.stop();
    configPanel.documentFile = file;
    root.classList.add('document-pane', 'config-pane');
    configPanel.body.replaceChildren();
    reader = documentReader(configPanel, 'config', file);
  };
  configPanel.detach = () => reader?.stop();
  configPanel.stop = async () => { reader?.stop(); reader = null; };
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

export function makeTerminalPane(root, prefix, launch = {}) {
  const stateLine = root.querySelector('.state');
  const nameLabel = root.querySelector('.name');
  const screen = root.querySelector('.screen');
  let reader = null;

  let following = true;
  let resizing = false;
  let sizeRevision = 0;
  screen.addEventListener('scroll', () => {
    if (resizing || root.classList.contains('shut')) return;
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
    isFollowing: () => following,
    onReady: () => syncSize(),
    onTheme: theme => { if (generation) post('theme', { theme }).catch(() => {}); },
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

  function setState(text) { if (!reader) stateLine.textContent = text; }

  function setProgram(name) {
    if (reader) return;
    if (!name) return;
    if (nameLabel.textContent === name) return;
    nameLabel.textContent = name;

    if (typeof packRail === 'function') packRail();
  }

  function setName(argv) {
    if (reader) return;
    if (!Array.isArray(argv) || !argv.length) return;

    nameLabel.textContent = String(argv[0]).split('/').filter(Boolean).pop();
  }

  function writeOutput(out) {
    if (reader) return;
    if (out.error) throw new Error(out.error);
    term.apply(out.screen);
  }

  function receive(out) {
    if (reader) return { at, generation };
    if (out.reachable === false) {
      if (out.absent) { setState('exited'); stopPolling(); }
      else {
        if (out.error) reportError(new Error(out.error), { pane: prefix, phase: 'supervisor' });
        setState(out.error || 'reconnecting...');
      }
      return { at, generation };
    }
    if (out.error) { setState(out.error); stopPolling(); return { at, generation }; }
    setProgram(out.program);
    if (out.generation !== generation) {
      generation = out.generation;
      remoteSize = null;
      at = 0;
      term.reset();
    }
    if (out.at > at) {
      writeOutput(out);
      at = out.at;
    }
    setState(inputFault || (out.running ? '' : 'exited'));
    if (!out.running) stopPolling();
    return { at, generation };
  }

  function startPolling() {
    if (reader) return;
    if (unsubscribe) return;
    unsubscribe = transport.subscribe(prefix, { at, generation }, receive, setState);
  }

  function stopPolling() {
    if (unsubscribe) unsubscribe();
    unsubscribe = null;
  }

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
          reportError(error, { pane: prefix, phase: 'input', rows: term.rows, cols: term.cols });
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
    minWidth: prefix.startsWith('agent-') ? 240 : 360, minHeight: 200,
    width: prefix.startsWith('agent-') ? COMPACT_WIDTH : 'min(52rem, 94vw)', height: '24rem',
    onLabel: (text) => saveLabel(prefix, text),

    onOpen: async () => {
      if (reader) { reader.focus(); return; }
      term.focus();

      await new Promise(r => setTimeout(r, 50));

      if (termPanel.shut) return;

      await termPanel.boot();
      syncSize();
      startPolling();

      post('redraw', {}).catch(() => {});
    },

    onShut: () => { clearTimeout(sizing); stopPolling(); },
    onResize: () => syncSize(),
  });

  let sizing = null;
  let remoteSize = null;
  function syncSize() {
    if (reader) return;
    const revision = ++sizeRevision;
    resizing = true;
    clearTimeout(sizing);
    if (termPanel.shut || !root.isConnected) return;
    sizing = setTimeout(() => {
      if (termPanel.shut || !root.isConnected) return;
      const size = term.measure();
      if (!size) return;
      term.resize(size.rows, size.cols);
      if (!remoteSize || size.rows !== remoteSize.rows || size.cols !== remoteSize.cols) {
        post('resize', size).then(() => { remoteSize = size; }).catch(error => {
          reportError(error, { pane: prefix, phase: 'resize-delivery', ...size });
          if (revision === sizeRevision && !termPanel.shut && root.isConnected) {
            sizing = setTimeout(syncSize, 300);
          }
        });
      }
      requestAnimationFrame(() => { if (revision === sizeRevision) resizing = false; });
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
    if (reader) return Promise.resolve();
    if (generation) return Promise.resolve();
    if (booting) return booting;
    booting = (async () => {
      try {
        const now = await post('screen', { at: 0, generation: 0 });
        if (now.generation) {
          await post('theme', { theme: term.theme });
          generation = now.generation;
          setName(now.argv);
          setProgram(now.program);
          setState(now.running ? '' : 'exited');
          term.resize(now.rows || 24, now.cols || 80);
          writeOutput(now);
          at = now.at;
        } else {
          if (launch?.recover) { setState(now.absent ? 'exited' : 'reconnecting...'); return; }
          if (now.reachable === false && !now.absent) throw new Error('supervisor unreachable');
          const out = await post('start', { rows: 24, cols: 80, theme: term.theme, ...launch });
          generation = out.generation;
          at = 0;
          setName(out.argv);
        }
        if (!termPanel.shut) startPolling();
      } catch (error) { reportError(error, { pane: prefix, phase: 'boot' }); setState(error.message); }
    })().finally(() => { booting = null; });
    return booting;
  };

  termPanel.showDocument = file => {
    if (termPanel.documentFile === file) return;
    stopPolling();
    clearTimeout(sizing);
    reader?.stop();
    termPanel.documentFile = file;
    root.classList.add('document-pane');
    root.classList.toggle('markdown-pane', /\.(md|markdown|mdown)$/i.test(file));
    term.destroy();
    stateLine.textContent = '';
    nameLabel.textContent = file.split('/').pop();
    reader = documentReader(termPanel, prefix, file);
    if (!termPanel.shut && root.classList.contains('picked')) reader.focus();
  };
  termPanel.showMarkdown = termPanel.showDocument;
  termPanel.detach = () => { stopPolling(); reader?.stop(); };
  termPanel.stop = async () => {
    stopPolling();
    reader?.stop();
    try { await post('stop', {}); } catch (e) {                              }
    try { await post('shutdown', {}); } catch (e) {                }
  };

  termPanel.setLabel((window.PANE_LABELS || {})[prefix] || '');
  return termPanel;
}

let harnessPane = makeTerminalPane(document.getElementById('harness'), 'harness', { recover: true });

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
const RAIL_GRAB = 56;

export const rail = [];
const railStates = Object.fromEntries(['top', 'bottom'].map(side => [side, {
  scroll: 0, scrolling: false, release: null,
}]));
let draggingPanel = null;

export function onRail(panel) { return rail.includes(panel); }
function railSide(panel) { return panel.root.dataset.rail || 'top'; }
function railPanels(side) { return rail.filter(p => railSide(p) === side); }

export function packRail() { changed(); }
renders(packRailNow);

export function packRailNow() {
  unscrollPage();
  for (const side of ['top', 'bottom']) {
    const state = railStates[side], panels = railPanels(side);
    const widths = panels.map(p => p.root.getBoundingClientRect().width);
    const total = widths.reduce((sum, width) => sum + width + TAB_GAP, TAB_GAP);
    const most = Math.min(0, innerWidth - total);
    state.scroll = Math.max(most, Math.min(0, state.scroll));
    const chosen = state.scrolling ? null : pickedPanel();
    const index = panels.indexOf(chosen);
    if (index >= 0 && most < 0) {
      const left = TAB_GAP + state.scroll + widths.slice(0, index).reduce((sum, width) => sum + width + TAB_GAP, 0);
      if (left < TAB_GAP) state.scroll += TAB_GAP - left;
      else if (left + widths[index] > innerWidth - TAB_GAP) state.scroll -= left + widths[index] - innerWidth + TAB_GAP;
      state.scroll = Math.max(most, Math.min(0, state.scroll));
    }
    let x = TAB_GAP + state.scroll;
    panels.forEach((panel, index) => {
      panel.root.style.setProperty('--rail-tab-height', panel.bar.offsetHeight + 'px');
      if (panel !== draggingPanel) {
        panel.root.classList.toggle('bottom-docked', side === 'bottom');
        panel.place(x, side === 'bottom' ? innerHeight - TAB_GAP - panel.root.offsetHeight : TAB_GAP, true);
      }
      x += widths[index] + TAB_GAP;
    });
  }
}

function unscrollPage() {
  if (window.scrollX !== 0 || window.scrollY !== 0) window.scrollTo(0, 0);
}

export function revealTab(panel) {
  if (!panel) return;
  unscrollPage();
  packRail();
}

window.addEventListener('wheel', e => {
  const side = e.clientY <= TAB_GAP + railHeight('top') ? 'top'
    : e.clientY >= innerHeight - TAB_GAP - railHeight('bottom') ? 'bottom' : null;
  if (!side) return;
  const state = railStates[side];
  const total = railPanels(side).reduce((sum, panel) => sum + panel.root.offsetWidth + TAB_GAP, TAB_GAP);
  const by = Math.abs(e.deltaX) > Math.abs(e.deltaY) ? -e.deltaX : -e.deltaY;
  const next = Math.max(Math.min(0, innerWidth - total), Math.min(0, state.scroll + by));
  if (next === state.scroll) return;
  state.scroll = next;
  state.scrolling = true;
  clearTimeout(state.release);
  state.release = setTimeout(() => { state.scrolling = false; }, 400);
  packRail();
  e.preventDefault();
}, { passive: false });

window.addEventListener('resize', packRail);
let railShape = '';
setInterval(() => {
  if (draggingPanel) return;
  unscrollPage();
  const shape = rail.map(p => [railSide(p), p.root.offsetWidth, p.root.offsetHeight].join(':')).join(',');
  if (shape !== railShape) { railShape = shape; packRail(); }
  resnap();
}, 250);

export function addToRail(panel, at, side = 'top') {
  const old = rail.indexOf(panel);
  if (old >= 0) rail.splice(old, 1);
  const others = railPanels(side);
  const before = others[at === undefined ? others.length : at];
  rail.splice(before ? rail.indexOf(before) : rail.length, 0, panel);
  panel.root.dataset.rail = side;
  delete panel.root.dataset.snapped;
  packRail();
  savePlacementSoon();
}

function removeFromRail(panel) {
  const at = rail.indexOf(panel);
  if (at < 0) return;
  const bar = panel.bar.getBoundingClientRect();
  rail.splice(at, 1);
  delete panel.root.dataset.rail;
  if (panel.root.classList.contains('bottom-docked')) {
    panel.root.classList.remove('bottom-docked');
    panel.place(bar.left, bar.top);
  }
  packRail();
}

function closePanel(panel, remote = false) {
  removeFromRail(panel);
  const at = extraPanes.indexOf(panel);
  if (at >= 0) extraPanes.splice(at, 1);

  if (panel.root.classList.contains('picked')) selectPane(configPanel.root);
  packRail();
  if (remote) panel.detach?.();
  else if (panel.stop) panel.stop();
  panel.root.remove();
  panelsByRoot.delete(panel.root);
  savePlacementSoon();
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

const railMarks = Object.fromEntries(['top', 'bottom'].map(side => {
  const mark = document.createElement('div');
  mark.className = 'rail-marks ' + side;
  mark.innerHTML = '<i></i><i></i>';
  document.body.appendChild(mark);
  return [side, mark];
}));

function railHeight(side) {
  const panels = railPanels(side);
  const panel = draggingPanel || panels[0] || configPanel;
  if (!panel) return 28;
  const style = getComputedStyle(panel.root);
  return panel.bar.getBoundingClientRect().height
    + parseFloat(style.borderTopWidth) + parseFloat(style.borderBottomWidth);
}

function showRails(near) {
  for (const [side, mark] of Object.entries(railMarks)) {
    mark.style.height = railHeight(side) + 'px';
    mark.classList.toggle('near', side === near);
  }
}

function overRail(panel) {
  const bar = panel.bar.getBoundingClientRect();
  const top = Math.abs(bar.top - TAB_GAP);
  const bottom = Math.abs(bar.bottom - (innerHeight - TAB_GAP));
  if (Math.min(top, bottom) > RAIL_GRAB) return null;
  return top <= bottom ? 'top' : 'bottom';
}

function slotFor(panel, side) {
  const bar = panel.bar.getBoundingClientRect();
  const mid = bar.left + bar.width / 2;
  const others = railPanels(side).filter(p => p !== panel);
  const at = others.findIndex(p => {
    const b = p.bar.getBoundingClientRect();
    return mid < b.left + b.width / 2;
  });
  return at < 0 ? others.length : at;
}

function railDrag(panel) {
  draggingPanel = panel;
  const near = overRail(panel);
  showRails(near);
  if (near) addToRail(panel, slotFor(panel, near), near);
}

function railDrop(panel) {
  const near = overRail(panel);
  draggingPanel = null;
  showRails(null);
  if (near) addToRail(panel, slotFor(panel, near), near);
  else removeFromRail(panel);
  packRail();
  savePlacementSoon();
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
  const pane = buildTerminal(id, { recover: true });
  addToRail(pane, undefined, id.startsWith('agent-') ? 'bottom' : 'top');

  pane.boot();
  return pane;
}

let remotePanes = new Set();
let harnessRequest = 0;
export function syncAgentPanes(ids, labels = {}, documents = {}, requestedHarness = 0) {
  window.PANE_LABELS = labels;
  const wanted = new Set(ids);
  for (const pane of [harnessPane, ...extraPanes]) {
    const id = pane === harnessPane ? 'harness' : pane.root.id.slice(5);
    if (remotePanes.has(id) && !wanted.has(id)) closePanel(pane, true);
  }
  for (const id of wanted) {
    if (id === 'harness' && !harnessPane.root.isConnected) {
      harnessPane = buildTerminal('harness', { recover: true });
      addToRail(harnessPane);
      harnessPane.boot();
    } else if (id.startsWith('agent-') && !document.getElementById('pane-' + id)) reopenTerminal(id);
  }
  if (requestedHarness > harnessRequest) {
    harnessRequest = requestedHarness;
    harnessPane.open();
    selectPane(harnessPane.root);
  }
  for (const panel of [configPanel, harnessPane, ...extraPanes]) {
    const id = paneId(panel);
    if (documents[id] && panel.root.isConnected) {
      panel.showDocument?.(documents[id]);
    }
    if (document.activeElement !== panel.label) {
      const id = panel === configPanel ? 'config' : panel === harnessPane ? 'harness' : panel.root.id.slice(5);
      panel.setLabel(labels[id] || '');
    }
  }
  remotePanes = wanted;
}

function buildTerminal(id, launch) {
  const root = paneTemplate.cloneNode(true);
  root.id = id === 'harness' ? 'harness' : 'pane-' + id;
  root.classList.add('shut');
  root.querySelector('.screen').textContent = '';
  root.querySelector('.state').textContent = '';
  root.querySelector('.name').textContent = 'terminal ' + id;

  root.style.cssText = '';
  document.body.appendChild(root);

  const pane = makeTerminalPane(root, id, launch);
  if (id !== 'harness') extraPanes.push(pane);
  return pane;
}

export function openFileTerminal(file, command, position) {
  const pane = buildTerminal(String(++paneCount), { node: file.name, file: file.file, command });
  selectPane(pane.root);
  pane.open();
  pane.place(Math.max(6, Math.min(position.x, innerWidth - pane.root.offsetWidth - 6)),
    Math.max(6, Math.min(position.y, innerHeight - pane.root.offsetHeight - 6)));
  savePlacementSoon();
  return pane;
}

export function openTerminal(side) {
  const selected = pickedPanel();
  side ??= onRail(selected) ? railSide(selected) : 'top';
  const id = String(++paneCount);
  const pane = buildTerminal(id);
  selectPane(pane.root);

  addToRail(pane, undefined, side);

  pane.boot();

  pane.open();
  return pane;
}


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

  const savedConfig = !!(window.PANE_POSITIONS && window.PANE_POSITIONS.config);
  if (window.START_EMPTY || savedConfig) {
    addToRail(configPanel, undefined, 'bottom');
    if (savedConfig) configPanel.open();
  }
  if (window.HARNESS_PRESENT) {
    addToRail(harnessPane);
    harnessPane.boot();
  } else closePanel(harnessPane, true);

  for (const id of (window.OPEN_TERMINALS || [])) {
    const n = Number(id);
    if (Number.isFinite(n) && n > paneCount) paneCount = n;
    reopenTerminal(String(id));
  }

  restorePlacements();
  placementsReady = true;
  savePlacementSoon();
  if (configPanel.root.isConnected) selectPane(configPanel.root);
}

let placementsReady = false;
let placementTimer = null;
let placementSaving = false;
let placementDirty = false;

function paneId(panel) {
  return panel === configPanel ? 'config' : panel === harnessPane ? 'harness' : panel.root.id.slice(5);
}

function placementSnapshot() {
  return Object.fromEntries([configPanel, harnessPane, ...extraPanes]
    .filter(p => p.root.isConnected)
    .filter(p => p !== configPanel || !p.shut)
    .map(p => {
      const box = p.root.getBoundingClientRect();
      const size = [Math.round(box.width), Math.round(box.height)];
      return [paneId(p), onRail(p)
        ? [railSide(p), railPanels(railSide(p)).indexOf(p), ...size]
        : ['floating', p.root.offsetLeft, p.root.offsetTop, ...size]];
    }));
}

function savePlacementSoon() {
  if (!placementsReady || draggingPanel) return;
  placementDirty = true;
  clearTimeout(placementTimer);
  placementTimer = setTimeout(savePlacements, 100);
}

async function savePlacements() {
  if (!placementDirty || placementSaving) return;
  placementSaving = true;
  placementDirty = false;
  try {
    const response = await fetch('/panes/placements?k=' + encodeURIComponent(window.TOKEN), {
      method: 'POST', body: JSON.stringify(placementSnapshot()), keepalive: true,
    });
    if (response.status === 403) await transport.refreshSession();
    if (!response.ok) throw new Error('could not save pane placement');
  } catch (error) {
    placementDirty = true;
    reportError(error, { phase: 'pane-placement' });
  } finally {
    placementSaving = false;
    if (placementDirty) placementTimer = setTimeout(savePlacements, 1000);
  }
}

function restorePlacements() {
  const saved = window.PANE_POSITIONS || {};
  for (const panel of [configPanel, harnessPane, ...extraPanes]) {
    if (!panel.root.isConnected) continue;
    const position = saved[paneId(panel)];
    if (!position) continue;
    const sizeAt = position[0] === 'floating' ? 3 : 2;
    if (position.length >= sizeAt + 2 && position[sizeAt] > 0 && position[sizeAt + 1] > 0) {
      panel.root.style.width = position[sizeAt] + 'px';
      panel.root.style.height = position[sizeAt + 1] + 'px';
    }
    if (position[0] === 'floating') {
      removeFromRail(panel);
      panel.open();
      panel.place(position[1], position[2]);
    } else addToRail(panel, undefined, position[0]);
  }
  for (const side of ['top', 'bottom']) {
    const ordered = railPanels(side).sort((a, b) =>
      (saved[paneId(a)]?.[1] ?? Infinity) - (saved[paneId(b)]?.[1] ?? Infinity));
    for (const panel of ordered) addToRail(panel, undefined, side);
  }
  packRailNow();
}

window.addEventListener('pagehide', () => {
  clearTimeout(placementTimer);
  savePlacements();
});
