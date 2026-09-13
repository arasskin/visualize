const capacity = 8192;
let samples = [];
let cursor = 0;
let active = false;
let observer = null;
let previousFrame = 0;
let pendingInput = null;
let frame = 0;

export function begin() { return active ? performance.now() : null; }

export function end(kind, start, extra = {}) {
  if (!active || start === null) return;
  const at = performance.now();
  const sample = { kind, at, ms: at - start, frame, ...extra };
  if (samples.length < capacity) samples.push(sample);
  else samples[cursor] = sample;
  cursor = (cursor + 1) % capacity;
}

export function measure(kind, action) {
  const start = begin();
  try { return action(); } finally { end(kind, start); }
}

export function input(event) {
  if (!active) return;
  const now = performance.now();
  const at = event.timeStamp > 0 && event.timeStamp <= now ? event.timeStamp : now;
  end('input-dispatch', at, { event: event.type });
  if (!pendingInput) pendingInput = { at, event: event.type, count: 0 };
  pendingInput.count++;
}

export function frameStart() {
  if (!active) return null;
  const now = performance.now();
  frame++;
  if (pendingInput) {
    end('input-to-render', pendingInput.at, { event: pendingInput.event, count: pendingInput.count });
    if (previousFrame && now - previousFrame < 250) end('navigation-frame-gap', previousFrame);
    pendingInput = null;
    previousFrame = now;
  } else if (now - previousFrame > 250) previousFrame = 0;
  return now;
}

function snapshot() {
  return samples.length < capacity ? samples.slice() : samples.slice(cursor).concat(samples.slice(0, cursor));
}

function report() {
  const groups = new Map();
  for (const sample of snapshot()) {
    const group = groups.get(sample.kind) || [];
    group.push(sample.ms);
    groups.set(sample.kind, group);
  }
  return [...groups].map(([kind, times]) => {
    times.sort((a, b) => a - b);
    const percentile = p => times[Math.max(0, Math.ceil(times.length * p) - 1)];
    return { kind, count: times.length, total: times.reduce((a, b) => a + b, 0),
      p50: percentile(.5), p95: percentile(.95), max: times.at(-1) };
  });
}

function stop() {
  active = false;
  observer?.disconnect();
  observer = null;
  return report();
}

function start() {
  stop();
  samples = []; cursor = 0; previousFrame = 0; pendingInput = null; frame = 0;
  active = true;
  try {
    observer = new PerformanceObserver(list => {
      for (const entry of list.getEntries()) end('long-task', entry.startTime,
        { ms: entry.duration, at: entry.startTime });
    });
    observer.observe({ entryTypes: ['longtask'] });
  } catch {}
}

window.__renderTrace = { start, stop, snapshot, report };
if (new URLSearchParams(location.search).get('rendertrace') === '1') start();
