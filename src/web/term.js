import * as latency from './latency.js';
import { WTerm } from '@wterm/dom';
import { GhosttyCore } from '@wterm/ghostty';

const WASM_URL = '/ghostty-vt.wasm';

function terminalColors(element) {
  const style = getComputedStyle(element);
  return { foregroundColor: style.getPropertyValue('--term-ink').trim(),
    backgroundColor: style.getPropertyValue('--term-ground').trim() };
}

function loadCore(element) {
  return GhosttyCore.load({ wasmPath: WASM_URL, ...terminalColors(element) });
}

export function makeTerminal(element, options = {}) {
  const onPaint = options.onPaint || (() => {});

  const onData = options.onData || (() => {});

  let term = null;
  let ready = false;
  let awaitingRender = 0;
  let pending = [];
  let rows = 24, cols = 80;

  let appliedRows = 0, appliedCols = 0;

  function unlockHeight() {
    if (!ready) return;
    element.style.height = '';
  }

  function applyTheme() {
    if (!term) return;
    const colors = terminalColors(element);
    const style = getComputedStyle(element);
    let sequence = `\x1b]10;${colors.foregroundColor}\x07\x1b]11;${colors.backgroundColor}\x07`;
    for (let i = 0; i < 16; i++) sequence += `\x1b]4;${i};${style.getPropertyValue('--term-color-' + i).trim()}\x07`;
    term.write(sequence);
  }

  const media = matchMedia('(prefers-color-scheme: dark)');
  const themeChanged = () => {
    if (!element.isConnected) { media.removeEventListener('change', themeChanged); return; }
    applyTheme();
  };
  media.addEventListener('change', themeChanged);

  loadCore(element).then(async (core) => {
    core.init(cols, rows);
    term = new WTerm(element, {
      core, cols, rows,

      onData,

      autoResize: false,
      cursorBlink: true,
    });
    if (latency.enabled) {
      const render = term._doRender.bind(term);
      term._doRender = () => {
        const start = performance.now();
        render();
        latency.record('render', performance.now() - start, options.pane);
        if (awaitingRender) {
          latency.record('write-to-render', performance.now() - awaitingRender, options.pane);
          awaitingRender = 0;
        }
      };
    }
    await term.init();
    applyTheme();

    ready = true;

    appliedRows = rows; appliedCols = cols;
    if (term.rows !== rows || term.cols !== cols) term.resize(cols, rows);
    for (const chunk of pending) term.write(chunk);
    pending = [];
    unlockHeight();
    paint();
  }).catch((err) => {

    element.textContent = `terminal unavailable: ${err && err.message || err}`;
  });

  function paint() {
    const core = term && term.bridge;
    const lines = core ? core.getScrollbackCount() + core.getRows() : 0;
    onPaint(lines);
  }

  return {
    write(text) {
      if (!text) return;
      if (!ready) { pending.push(text); return; }
      const start = latency.enabled ? performance.now() : 0;
      if (latency.enabled && !awaitingRender) awaitingRender = start;
      term.write(text);
      paint();
      if (latency.enabled) latency.record('emulator-write', performance.now() - start, options.pane);
    },

    resize(nextRows, nextCols) {
      const known = nextRows === rows && nextCols === cols;
      rows = nextRows; cols = nextCols;

      if (ready && (rows !== appliedRows || cols !== appliedCols)) {
        term.resize(cols, rows);
        appliedRows = rows; appliedCols = cols;
        unlockHeight();
        paint();
      }

      return !known;
    },

    reset() {
      pending = [];
      if (ready) { term.write('\x1bc'); applyTheme(); paint(); }
    },

    focus() { if (ready) term.focus(); else element.focus(); },

    get rows() { return rows; },
    get cols() { return cols; },

    get title() {
      const core = term && term.bridge;
      return (core && core.getTitle()) || null;
    },

    drain() {
      const core = term && term.bridge;
      if (!core) return '';
      let out = '';
      for (;;) {
        const reply = core.getResponse();
        if (!reply) return out;
        out += reply;
      }
    },
  };
}
