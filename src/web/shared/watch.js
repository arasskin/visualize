import {refreshSession} from './transport.js';

export function watch(endpoint, generation, update) {
  let pending = null, timer = null, stopped = false;
  async function poll() {
    if (stopped) return;
    pending = new AbortController();
    let delay = 0;
    try {
      const response = await fetch(`${endpoint}?k=${encodeURIComponent(window.TOKEN)}`, {
        method: 'POST', body: JSON.stringify({generation}),
        signal: AbortSignal.any([pending.signal, AbortSignal.timeout(35000)]),
      });
      if (response.status === 403) { await refreshSession(); generation = -1; }
      if (!response.ok) throw new Error('watch failed');
      const result = await response.json();
      if (stopped) return;
      generation = await update(result, pending.signal) ?? result.generation;
    } catch { delay = 2000; }
    finally { if (!stopped) timer = setTimeout(poll, delay); }
  }
  const stop = () => { stopped = true; pending?.abort(); clearTimeout(timer); };
  window.addEventListener('pagehide', stop);
  window.addEventListener('pageshow', event => { if (event.persisted) { stopped = false; poll(); } });
  poll();
  return stop;
}
