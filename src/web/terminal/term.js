import { reportError } from '../shared/errors.js';
import * as latency from '../shared/latency.js';
import { WTerm } from '@wterm/dom';
import { ScreenCore } from './screen-core.js';

export function makeTerminal(element, options = {}) {
  const onPaint = options.onPaint || (() => {});

  const onData = options.onData || (() => {});

  let term = null;
  let ready = false;
  let revision = 0;
  let awaitingRender = 0;
  let pending = [];
  let rows = 24, cols = 80;

  function unlockHeight() {
    if (!ready) return;
    element.style.height = '';
  }

  function initialize(restoreFocus = false) {
    const current = ++revision;
    Promise.resolve(new ScreenCore()).then(async (core) => {
      if (current !== revision) return;
      term = new WTerm(element, {
        core, cols, rows,

        onData,

        autoResize: false,
        cursorBlink: true,
        onRender(duration) {
          paint();
          if (latency.enabled) latency.record('render', duration, options.pane);
          if (awaitingRender) {
            latency.record('write-to-render', performance.now() - awaitingRender, options.pane);
            awaitingRender = 0;
          }
        },
        onRenderError(error) { reportError(error, {pane: options.pane, phase: 'render', rows, cols}); },
      });
      const previousFocus = restoreFocus ? document.activeElement : null;
      const initialized = term.init();
      if (previousFocus?.isConnected) previousFocus.focus({ preventScroll: true });
      await initialized;
      if (current !== revision) return;

      ready = true;

      if (term.rows !== rows || term.cols !== cols) term.resize(cols, rows);
      for (const screen of pending) applyScreen(screen);
      pending = [];
      unlockHeight();
      options.onReady?.();
    }).catch((err) => {
      if (current !== revision) return;
      reportError(err, { pane: options.pane, phase: 'initialize', rows, cols });
      ready = false;
      element.textContent = `terminal unavailable: ${err && err.message || err}`;
    });
  }

  function theme() {
    const style = getComputedStyle(element);
    const rgb = name => parseInt(style.getPropertyValue(name).trim().replace('#', ''), 16);
    return { foreground: rgb('--term-ink'), background: rgb('--term-ground'),
      palette: Array.from({ length: 16 }, (_, i) => rgb('--term-color-' + i)) };
  }
  const media = matchMedia('(prefers-color-scheme: dark)');
  const themeChanged = () => {
    if (!element.isConnected) { media.removeEventListener('change', themeChanged); return; }
    options.onTheme?.(theme());
  };
  media.addEventListener('change', themeChanged);

  initialize();

  function paint() {
    const core = term && term.core;
    const lines = core ? core.getScrollbackCount() + core.getRows() : 0;
    onPaint(lines, core?.getRows(), core?.getCols());
  }

  function applyScreen(screen) {
    const start = latency.enabled ? performance.now() : 0;
    const follow = options.isFollowing?.() ?? true;
    try {
      term.core.apply(screen);
      if (latency.enabled && !awaitingRender) awaitingRender = start;
      term.refreshScreen({follow, historyChanged: !!screen.history.lines.length});
      unlockHeight();
    } catch (error) {
      reportError(error, { pane: options.pane, phase: 'screen', rows, cols });
      throw error;
    }
    if (latency.enabled) latency.record('screen-apply', performance.now() - start, options.pane);
  }

  return {
    destroy() {
      ++revision;
      ready = false;
      pending = [];
      media.removeEventListener('change', themeChanged);
      term?.destroy();
      term = null;
    },
    get theme() { return theme(); },

    apply(screen) {
      if (!screen) return;
      if (!ready) { pending.push(screen); return; }
      applyScreen(screen);
    },

    measure() {
      if (!ready) return null;
      const size = term.measure();
      if (!size) return null;
      return { rows: Math.max(4, Math.floor(element.clientHeight / size.rowHeight)),
        cols: Math.max(20, Math.floor(element.clientWidth / size.charWidth)),
        cellWidth: Math.round(size.charWidth), cellHeight: Math.round(size.rowHeight) };
    },

    resize(nextRows, nextCols) {
      const known = nextRows === rows && nextCols === cols;
      rows = nextRows; cols = nextCols;

      return !known;
    },

    reset() {
      pending = [];
      ready = false;
      awaitingRender = 0;
      term?.destroy();
      term = null;
      initialize(true);
    },

    focus() { if (ready) term.focus(); else element.focus(); },

    get rows() { return rows; },
    get cols() { return cols; },

    get title() {
      const core = term && term.core;
      return (core && core.getTitle()) || null;
    },

  };
}
