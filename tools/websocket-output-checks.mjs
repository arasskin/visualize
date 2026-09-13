import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { resolve } from 'node:path';

const repo = resolve(import.meta.dirname, '..');
const size = 3 * 1024 * 1024;
const server = spawn(resolve(repo, 'external-src/janet/janet'), ['-e', `
(import ./src.server/http)
(import ./src.server/websocket :as ws)
(def large (string/repeat "x" ${size}))
(def [server port accept-loop]
  (http/serve 19100 50
    (fn [request]
      {:upgrade (fn [connection carry]
        (ws/serve connection carry request
          (fn [send]
            {:message (fn [_]
                        (send large)
                        (for i 0 20 (send (string i ":" (string/repeat "y" 65536)))))
             :close (fn [] )})))})))
(print port)
(file/flush stdout)
(accept-loop)
`], { cwd: repo, stdio: ['ignore', 'pipe', 'pipe'] });
let errors = '', socket;
server.stderr.on('data', b => { errors += b; });
try {
  const port = await new Promise((resolve, reject) => {
    server.stdout.once('data', b => resolve(Number(String(b).trim())));
    server.once('exit', code => reject(new Error(`server exited ${code}: ${errors}`)));
  });
  for (let attempt = 0; attempt < 3; attempt++) {
    await new Promise((resolve, reject) => {
      let received = 0;
      const timer = setTimeout(() => reject(new Error('output stalled')), 15000);
      socket = new WebSocket(`ws://127.0.0.1:${port}/`);
      socket.binaryType = 'arraybuffer';
      socket.onopen = () => socket.send('snapshot');
      socket.onmessage = e => {
        try {
          const text = Buffer.from(e.data).toString();
          if (received === 0) assert.equal(text, 'x'.repeat(size));
          else assert.equal(text, `${received - 1}:` + 'y'.repeat(65536));
          received++;
          if (received === 21) { clearTimeout(timer); socket.close(); resolve(); }
        } catch (error) { clearTimeout(timer); reject(error); }
      };
      socket.onclose = () => { if (received !== 21) { clearTimeout(timer); reject(new Error(`closed after ${received} messages`)); } };
      socket.onerror = () => { clearTimeout(timer); reject(new Error('websocket error')); };
    });
  }
  console.log('Passed: 3 reconnects, each with a 3 MiB snapshot and 20 following messages.');
} finally {
  socket?.close();
  if (server.exitCode === null) { const ended = once(server, 'exit'); server.kill('SIGTERM'); await ended; }
}
