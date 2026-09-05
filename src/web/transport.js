const subscriptions = new Map();
const pending = new Map();
let socket = null;
let connecting = null;
let retry = null;
let serial = 0;
let subscriptionSerial = 0;
let pendingBytes = 0;
const limit = 262144;
const decoder = new TextDecoder();
const encoder = new TextEncoder();

function send(message) {
  if (!socket || socket.readyState !== WebSocket.OPEN) throw new Error('terminal disconnected');
  const text = JSON.stringify(message);
  if (socket.bufferedAmount + encoder.encode(text).length > limit) throw new Error('terminal send buffer full');
  socket.send(text);
}

function attach(pane, sub) {
  sub.id = ++subscriptionSerial;
  send({ type: 'subscribe', pane, at: sub.at, generation: sub.generation, subscription: sub.id });
}

function reconnect() {
  if (retry || !subscriptions.size) return;
  retry = setTimeout(() => {
    retry = null;
    connect().catch(() => reconnect());
  }, 500);
}

export function connect() {
  if (socket?.readyState === WebSocket.OPEN) return Promise.resolve();
  if (connecting) return connecting;
  connecting = (async () => {
    const response = await fetch('/session', { cache: 'no-store', signal: AbortSignal.timeout(5000) });
    if (!response.ok) throw new Error('terminal connection unavailable');
    const session = await response.json();
    window.TOKEN = session.token;
    const url = new URL('/terminal', location.href);
    url.protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
    url.searchParams.set('k', session.token);
    const ws = new WebSocket(url);
    ws.binaryType = 'arraybuffer';
    socket = ws;
    ws.onmessage = event => {
      let message;
      try { message = JSON.parse(typeof event.data === 'string' ? event.data : decoder.decode(event.data)); }
      catch { ws.close(1002, 'invalid terminal message'); return; }
      if (message.type === 'reply') {
        const entry = pending.get(message.id);
        if (!entry) return;
        pending.delete(message.id);
        pendingBytes -= entry.bytes;
        clearTimeout(entry.timer);
        if (!message.body || message.body.error) entry.reject(new Error(message.body?.error || 'input delivery could not be confirmed'));
        else entry.resolve(message.body);
      } else if (message.type === 'output') {
        const sub = subscriptions.get(message.pane);
        if (!sub || sub.id !== message.subscription) return;
        try {
          const position = sub.output(message.body);
          if (position) Object.assign(sub, position);
          if (subscriptions.get(message.pane) === sub) {
            send({ type: 'credit', pane: message.pane, at: sub.at, generation: sub.generation, subscription: sub.id });
          }
        } catch (error) {
          sub.state(error.message);
          ws.close(1011, 'terminal output failed');
        }
      }
    };
    ws.onclose = () => {
      if (socket !== ws) return;
      socket = null;
      for (const entry of pending.values()) {
        clearTimeout(entry.timer);
        entry.reject(new Error('terminal disconnected; delivery unconfirmed'));
      }
      pending.clear(); pendingBytes = 0;
      for (const sub of subscriptions.values()) sub.state('reconnecting...');
      reconnect();
    };
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => { ws.close(); reject(new Error('terminal connection timed out')); }, 5000);
      ws.onopen = () => { clearTimeout(timer); resolve(); };
      ws.onerror = () => { clearTimeout(timer); reject(new Error('terminal connection failed')); };
    });
    for (const [pane, sub] of subscriptions) attach(pane, sub);
  })().finally(() => { connecting = null; });
  return connecting;
}

export async function request(pane, op, body = {}, timeout = 15000) {
  if (op === 'input' && socket?.readyState !== WebSocket.OPEN) throw new Error('terminal disconnected; input was not sent');
  await connect();
  const id = ++serial;
  const message = { type: 'request', pane, id, op, body };
  const bytes = encoder.encode(JSON.stringify(message)).length;
  if (pending.size >= 512 || pendingBytes + bytes > limit) throw new Error('terminal input queue full');
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      const entry = pending.get(id);
      if (!entry) return;
      pending.delete(id); pendingBytes -= bytes;
      reject(new Error('terminal request timed out; delivery unconfirmed'));
    }, timeout);
    pending.set(id, { resolve, reject, bytes, timer });
    pendingBytes += bytes;
    try { send(message); }
    catch (error) {
      pending.delete(id); pendingBytes -= bytes; clearTimeout(timer); reject(error);
    }
  });
}

export function subscribe(pane, position, output, state) {
  const sub = { ...position, output, state, id: 0 };
  subscriptions.set(pane, sub);
  if (socket?.readyState === WebSocket.OPEN) attach(pane, sub);
  else connect().catch(error => { state(error.message); reconnect(); });
  return () => {
    if (subscriptions.get(pane) !== sub) return;
    subscriptions.delete(pane);
    if (socket?.readyState === WebSocket.OPEN) send({ type: 'unsubscribe', pane });
  };
}
