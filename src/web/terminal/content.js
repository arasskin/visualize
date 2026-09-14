import {reportError} from '../shared/errors.js';
import * as transport from '../shared/transport.js';
import * as latency from '../shared/latency.js';
import {makeTerminal} from './term.js';

export function terminalContent(termPanel, prefix, launch = {}) {
  const root = termPanel.root;
  const content = {};
  const screen = document.createElement('div'); screen.className = 'screen'; screen.tabIndex = 0;
  termPanel.body.append(screen);
  const stateLine = root.querySelector('.state');
  const nameLabel = root.querySelector('.name');
  let disposed = false;
  const lifetime = new AbortController();

  let following = true;
  let resizing = false;
  let sizeRevision = 0;
  screen.addEventListener('scroll', () => {
    if (resizing || root.classList.contains('shut')) return;
    following = screen.scrollTop + screen.clientHeight
      >= screen.scrollHeight - 4;
  });

  let paintedLines = 0;
  let paintedRows = 0, paintedCols = 0;

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
    onPaint: (lines, rows, cols) => {
      const grew = lines !== paintedLines;
      paintedLines = lines;
      paintedRows = rows; paintedCols = cols;
      if ((grew || resizing) && following) screen.scrollTop = screen.scrollHeight;
      if (rows === term.rows && cols === term.cols) resizing = false;
    },

    onData: (bytes) => { sendInput(bytes); },
  });
  termPanel.body.addEventListener('click', event => {
    if (event.target === termPanel.body) term.focus();
  }, {signal: lifetime.signal});

  let at = 0;
  let generation = 0;
  let unsubscribe = null;
  let inputFault = null;
  let resizeFault = null;
  let inputSerial = 0, inputSettled = 0;
  let terminalState = '';

  async function post(path, body = {}, timeoutMs = 15000, traceId = 0) {
    const began = latency.enabled ? performance.now() : 0;
    const out = await transport.request(prefix, path, body, timeoutMs);
    if (latency.enabled) {
      latency.record(path + '-rpc', performance.now() - began, prefix, traceId);
      if (out?._trace) for (const [kind, ms] of Object.entries(out._trace)) latency.record(kind, ms, prefix, traceId);
    }
    return out;
  }

  function setState(text) {
    terminalState = text;
    if (!disposed) {
      stateLine.textContent = resizeFault?.message || text || inputFault?.message || '';
      stateLine.title = resizeFault?.detail || '';
    }
  }

  function setProgram(name) {
    if (disposed) return;
    if (!name) return;
    if (nameLabel.textContent === name) return;
    nameLabel.textContent = name;


  }

  function setName(argv) {
    if (disposed) return;
    if (!Array.isArray(argv) || !argv.length) return;

    nameLabel.textContent = String(argv[0]).split('/').filter(Boolean).pop();
  }

  function writeOutput(out) {
    if (disposed) return;
    if (out.error) throw new Error(out.error);
    term.apply(out.screen);
  }

  function receive(out) {
    if (disposed) return { at, generation };
    if (out.reachable === false) {
      if (out.absent) { setState('exited'); stopPolling(); }
      else {
        if (out.error) reportError(new Error(out.error), { pane: prefix, phase: 'supervisor' });
        setState(out.error || 'reconnecting...');
      }
      return { at, generation };
    }
    if (out.error) { setState(out.error); stopPolling(); return { at, generation }; }
    const reconnected = terminalState === 'reconnecting...';
    const replaced = out.generation !== generation;
    setProgram(out.program);
    if (replaced) {
      cancelResize();
      resizeFault = null;
      generation = out.generation;
      remoteSize = null;
      at = 0;
      term.reset();
    }
    if (out.at > at) {
      writeOutput(out);
      at = out.at;
    }
    if (inputFault?.reconnect) inputFault = null;
    setState(out.running ? '' : 'exited');
    if (!out.running) stopPolling();
    else if (replaced || reconnected) {
      cancelResize();
      remoteSize = null;
      syncSize();
    }
    return { at, generation };
  }

  function startPolling() {
    if (disposed || termPanel.shut || !root.isConnected) return;
    if (unsubscribe) return;
    unsubscribe = transport.subscribe(prefix, { at, generation }, receive, setState);
  }

  function stopPolling() {
    if (unsubscribe) unsubscribe();
    unsubscribe = null;
  }

  function sendInput(text, quiet) {
    if (!text || disposed) return Promise.resolve();
    const queued = latency.enabled ? performance.now() : 0;
    const sent = [];
    for (let offset = 0; offset < text.length;) {
      let end = Math.min(text.length, offset + 16384);
      if (end < text.length && text.charCodeAt(end - 1) >= 0xd800 && text.charCodeAt(end - 1) <= 0xdbff) end--;
      const chunk = text.slice(offset, end);
      offset = end;
      const traceId = latency.nextId();
      const serial = ++inputSerial;
      if (latency.enabled) {
        latency.record('input-queue', performance.now() - queued, prefix, traceId);
        if (lastKey) { latency.record('key-to-data', queued - lastKey, prefix, traceId); lastKey = 0; }
      }
      sent.push(post('input', { text: chunk, generation, quiet: !!quiet }, 15000, traceId)
        .then(() => {
          if (serial > inputSettled) { inputSettled = serial; inputFault = null; setState(terminalState); }
          if (latency.enabled) latency.record('input-total', performance.now() - queued, prefix, traceId);
        })
        .catch(error => {
          if (latency.enabled) latency.record('input-error', performance.now() - queued, prefix, traceId);
          reportError(error, { pane: prefix, phase: 'input', rows: term.rows, cols: term.cols });
          if (serial > inputSettled) { inputSettled = serial; inputFault = error; setState(terminalState); }
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

  content.focus = async () => {
    term.focus();
    await new Promise(resolve => requestAnimationFrame(resolve));
    if (disposed || termPanel.shut || !root.isConnected) return;
    if (!await content.boot()) return;
    if (disposed || termPanel.shut || !root.isConnected) return;
    syncSize(); startPolling(); post('redraw', {}).catch(() => {});
  };
  content.shut = () => { clearTimeout(sizing); cancelResize(); stopPolling(); };
  content.resize = () => syncSize();

  let sizing = null;
  let remoteSize = null;
  let sizeRequest = null;
  const resizeDelays = [300, 600, 1200];

  function cancelResize() {
    clearTimeout(sizeRequest?.timer);
    sizeRequest = null;
  }

  async function sendSize(request) {
    const current = () => !disposed && sizeRequest === request && request.generation === generation
      && !termPanel.shut && root.isConnected;
    if (!current()) return;
    ++request.attempts;
    try {
      await post('resize', request.size);
      if (!current()) return;
      remoteSize = request.size;
      resizeFault = null;
      cancelResize();
      setState(terminalState);
    } catch (error) {
      if (!current()) return;
      if (request.attempts <= resizeDelays.length) {
        request.timer = setTimeout(() => sendSize(request), resizeDelays[request.attempts - 1]);
      } else {
        request.failed = true;
        resizing = false;
        resizeFault = {message: `resize failed after ${request.attempts} attempts`, detail: error.message};
        setState(terminalState);
        reportError(error, {pane: prefix, phase: 'resize-delivery', attempts: request.attempts, ...request.size});
      }
    }
  }

  function syncSize() {
    if (disposed || !generation) return;
    const revision = ++sizeRevision;
    resizing = true;
    clearTimeout(sizing);
    if (termPanel.shut || !root.isConnected) return;
    sizing = setTimeout(() => {
      if (termPanel.shut || !root.isConnected) return;
      const size = term.measure();
      if (!size) return;
      term.resize(size.rows, size.cols);
      const sameSize = other => other && size.rows === other.rows && size.cols === other.cols;
      if (sameSize(sizeRequest?.size) && sizeRequest.failed) { resizing = false; return; }
      if (!sameSize(remoteSize) && !sameSize(sizeRequest?.size)) {
        cancelResize();
        remoteSize = null;
        sizeRequest = {size, generation, attempts: 0, timer: null};
        sendSize(sizeRequest);
      }
      requestAnimationFrame(() => {
        if (revision === sizeRevision && paintedRows === size.rows && paintedCols === size.cols) resizing = false;
      });
    }, 150);
  }

  window.addEventListener('resize', () => { if (!termPanel.shut) syncSize(); }, {signal: lifetime.signal});

  for (const signal of ['visibilitychange', 'focus', 'online']) {
    (signal === 'visibilitychange' ? document : window).addEventListener(signal, () => {
      if (document.hidden || termPanel.shut || generation === 0) return;
      startPolling();
    }, {signal: lifetime.signal});
  }

  content.type = (text) => { if (text) sendInput(text); };

  let booting = null;
  let bootRetry = null;
  content.boot = () => {
    if (disposed) return Promise.resolve(false);
    if (generation) return Promise.resolve(true);
    if (booting) return booting;
    clearTimeout(bootRetry);
    booting = (async () => {
      let starting = false;
      try {
        const now = await post('screen', { at: 0, generation: 0 });
        if (disposed) return;
        if (now.generation) {
          await post('theme', { theme: term.theme });
          if (disposed) return;
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
          starting = true;
          const out = await post('start', { rows: 24, cols: 80, theme: term.theme, ...launch });
          generation = out.generation;
          at = 0;
          setName(out.argv);
        }
        if (!termPanel.shut) startPolling();
        return true;
      } catch (error) {
        if (disposed) return false;
        if (error.reconnect && !starting) {
          setState('reconnecting...');
          bootRetry = setTimeout(async () => { if (await content.boot()) syncSize(); }, 500);
        } else {
          reportError(error, { pane: prefix, phase: 'boot' }); setState(error.message);
        }
        return false;
      }
    })().finally(() => { booting = null; });
    return booting;
  };

  content.detach = () => {
    if (disposed) return;
    disposed = true;
    lifetime.abort();
    clearTimeout(sizing);
    cancelResize();
    clearTimeout(bootRetry);
    stopPolling();
    term.destroy();
  };
  content.settled = () => booting || Promise.resolve();
  return content;
}
