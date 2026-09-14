const recent = new Map();
const storageKey = 'visualize-terminal-errors';
let queue = [];
let sending = false;
let retry = null;
function save() {
  try { localStorage.setItem(storageKey, JSON.stringify(queue)); } catch {}
}
async function flush() {
  clearTimeout(retry);
  if (sending || !queue.length) return;
  if (!window.TOKEN) { retry = setTimeout(flush, 3000); return; }
  sending = true;
  try {
    while (queue.length) {
      const entry = queue[0];
      const response = await fetch('/errors?k=' + encodeURIComponent(window.TOKEN), {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(entry), signal: AbortSignal.timeout(5000),
      });
      if (!response.ok) throw new Error('error log unavailable');
      if (queue[0] === entry) queue.shift();
      save();
    }
  } catch {} finally {
    sending = false;
    if (queue.length) retry = setTimeout(flush, 3000);
  }
}
const redact = text => String(text || '').replace(/([?&]k=)[^&#\s]+/g, '$1[redacted]');

export function reportError(error, context = {}) {
  const entry = { ...context, message: redact(error?.message || error).slice(0, 2048),
    stack: redact(error?.stack).slice(0, 8192), time: new Date().toISOString() };
  const key = [entry.pane, entry.phase, entry.message].join(':');
  const now = Date.now();
  if (now - (recent.get(key) || 0) < 5000) return;
  if (recent.size >= 128) recent.clear();
  recent.set(key, now);
  const root = document.getElementById(entry.pane === 'harness' ? 'harness' : 'pane-' + entry.pane);
  entry.label = root?.querySelector('.label')?.textContent?.slice(0, 200) || '';
  console.error('Terminal error', entry);
  queue.push(entry);
  if (queue.length > 32) queue.shift();
  save();
  flush();
}

export function startErrorReporting() {
  try { queue = JSON.parse(localStorage.getItem(storageKey) || '[]').slice(-32); } catch {}
  window.addEventListener('online', flush);
  setTimeout(flush, 0);
  window.addEventListener('error', event => {
    if (event.error) reportError(event.error, { phase: 'uncaught' });
  });
  window.addEventListener('unhandledrejection', event => {
    reportError(event.reason, { phase: 'unhandled-rejection' });
  });

}
