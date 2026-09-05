export const enabled = new URLSearchParams(location.search).get('trace') === '1';
const capacity = 4096;
const samples = [];
let cursor = 0;
let sequence = 0;
export function nextId() { return enabled ? ++sequence : 0; }
export function record(kind, ms, pane, id = 0, extra = {}) {
  if (!enabled) return;
  const sample = { kind, ms, pane, id, at: performance.now(), ...extra };
  if (samples.length < capacity) samples.push(sample);
  else samples[cursor] = sample;
  cursor = (cursor + 1) % capacity;
}
if (enabled) {
  window.__latency = {
    snapshot: () => samples.length < capacity ? samples.slice()
      : samples.slice(cursor).concat(samples.slice(0, cursor)),
    clear: () => { samples.length = 0; cursor = 0; },
  };
  try {
    new PerformanceObserver(list => {
      for (const entry of list.getEntries()) record('long-task', entry.duration, null);
    }).observe({ entryTypes: ['longtask'] });
  } catch {}
  new PerformanceObserver(list => {
    for (const e of list.getEntries()) {
      if (!new URL(e.name).pathname.endsWith('/input')) continue;
      record('resource', e.duration, new URL(e.name).pathname, 0, {
        preRequest: e.requestStart - e.startTime,
        responseWait: e.responseStart - e.requestStart,
        download: e.responseEnd - e.responseStart,
        server: e.serverTiming.map(s => ({ name: s.name, ms: s.duration })),
      });
    }
  }).observe({ entryTypes: ['resource'] });
}
