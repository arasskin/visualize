import { spawn } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, readFile, rm, cp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const output = resolve(process.argv[2] || '/tmp/visualize-paint-trace.json');
const root = await mkdtemp(join(tmpdir(), 'vz-paint-'));
const chromePath = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
let server, chrome, socket;
const logs = [];
const metadata = { platform: process.platform, arch: process.arch, workload: 'graph navigation', viewport: { width: 1440, height: 1000, deviceScaleFactor: 1 }, colorScheme: 'light', variant: process.env.PAINT_CASE || 'current' };
async function waitFor(fn, ms = 30000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    try { const out = await fn(); if (out) return out; } catch {}
    await sleep(50);
  }
  throw new Error('Timed out: ' + fn.toString() + '\n' + logs.join('').slice(-3000));
}
class CDP {
  constructor(ws) {
    this.ws = ws; this.id = 0; this.pending = new Map();
    ws.addEventListener('message', event => {
      const m = JSON.parse(event.data);
      if (!m.id) return;
      const pending = this.pending.get(m.id);
      if (!pending) return;
      this.pending.delete(m.id);
      m.error ? pending.reject(new Error(JSON.stringify(m.error))) : pending.resolve(m.result);
    });
  }
  send(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = ++this.id; this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }
  async evaluate(expression) {
    const out = await this.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    if (out.exceptionDetails) throw new Error(JSON.stringify(out.exceptionDetails));
    return out.result.value;
  }
}

try {
  await mkdir(join(root, 'project'));
  await mkdir(join(root, 'bin'));
  for (const part of ['src', 'external-src', 'tools']) await cp(join(repo, part), join(root, 'project', part), { recursive: true });
  const config = (await readFile(join(repo, 'visualize.conf'), 'utf8')).split('\n').filter(line => !line.startsWith('@visualize')).join('\n');
  await writeFile(join(root, 'project', 'visualize.conf'), config);
  await writeFile(join(root, 'bin', 'open'), '#!/bin/sh\nfor browser_arg do\n  case "$browser_arg" in\n    http://*|https://*) printf "%s" "$browser_arg" > "$VZ_BENCH_URL" ;;\n    --app=*) printf "%s" "${browser_arg#--app=}" > "$VZ_BENCH_URL" ;;\n  esac\ndone\n', { mode: 0o755 });
  const core = join(repo, 'src/visualize/core.janet');
  const serverOptions = {
    cwd: repo, stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env, VISUALIZE_TRACE: process.env.VISUALIZE_TRACE || '1', VISUALIZE_HARNESS: '/bin/cat',
      PATH: join(root, 'bin') + ':' + process.env.PATH, VZ_BENCH_URL: join(root, 'url') },
  };
  function startServer() {
    server = spawn(join(repo, 'external-src/janet/janet'), [core, join(root, 'project'), '--no-dev'], serverOptions);
    for (const stream of [server.stdout, server.stderr]) stream.on('data', b => logs.push(String(b)));
  }
  startServer();
  const url = await waitFor(() => readFile(join(root, 'url'), 'utf8'));
  chrome = spawn(chromePath, ['--headless=new', '--no-first-run', '--no-default-browser-check',
    '--disable-background-timer-throttling', '--disable-renderer-backgrounding',
    '--remote-debugging-port=0', '--user-data-dir=' + join(root, 'chrome'), 'about:blank'], { stdio: 'ignore' });
  const debugPort = (await waitFor(() => readFile(join(root, 'chrome', 'DevToolsActivePort'), 'utf8'))).split('\n')[0];
  const targets = await (await fetch(`http://127.0.0.1:${debugPort}/json/list`)).json();
  socket = new WebSocket(targets.find(t => t.type === 'page').webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.addEventListener('open', resolve); socket.addEventListener('error', reject); });
  const cdp = new CDP(socket);
  metadata.browser = await cdp.send('Browser.getVersion');
  await cdp.send('Page.enable');
  await cdp.send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false });
  await cdp.send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'light' }] });
  await cdp.send('Page.navigate', { url: url + '/?trace=1' });
  await waitFor(() => cdp.evaluate('!!window.__latency && !!document.querySelector("#harness textarea")'));
  await cdp.evaluate('document.querySelectorAll(".panel").forEach(p => p.style.display = "none")');
  await sleep(1500);

  metadata.graph = await cdp.evaluate(`(() => {
    const svg = document.querySelector('#graph svg');
    return { nodes: svg.querySelectorAll('g.node').length, edges: svg.querySelectorAll('g.edge').length,
      elements: svg.querySelectorAll('*').length, width: svg.getAttribute('width'), height: svg.getAttribute('height') };
  })()`);
  const traceEvents = [];
  let complete;
  const finished = new Promise(resolve => complete = resolve);
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    if (message.method === 'Tracing.dataCollected') traceEvents.push(...message.params.value);
    if (message.method === 'Tracing.tracingComplete') complete();
  });
  await cdp.send('Tracing.start', { categories: 'devtools.timeline,blink.user_timing,cc,gpu,disabled-by-default-devtools.timeline,disabled-by-default-devtools.timeline.invalidationTracking', transferMode: 'ReportEvents' });
  async function gesture(name, zoom) {
    await cdp.evaluate(`(async () => { const g = await import('/graph.js'); g.fit(); })()`);
    await sleep(400);
    await cdp.evaluate(`performance.mark(${JSON.stringify(name + ':start')})`);
    if (!zoom) await cdp.send('Input.dispatchMouseEvent', { type: 'mousePressed', x: 600, y: 450, button: 'left', buttons: 1, clickCount: 1 });
    for (let i = 0; i < 90; i++) {
      const phase = Math.sin(i / 89 * Math.PI * 2);
      if (zoom) await cdp.send('Input.dispatchMouseEvent', { type: 'mouseWheel', x: 720, y: 500, deltaX: 0, deltaY: i < 45 ? -12 : 12 });
      else await cdp.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: 600 + phase * 180, y: 450 + Math.cos(i / 89 * Math.PI * 2) * 80, button: 'left', buttons: 1 });
      await sleep(16);
    }
    if (!zoom) await cdp.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: 600, y: 530, button: 'left', buttons: 0, clickCount: 1 });
    await sleep(200);
    await cdp.evaluate(`performance.mark(${JSON.stringify(name + ':end')})`);
    console.log('Captured', name);
  }
  if (process.env.PAINT_CASE === 'wrapper') {
    await cdp.evaluate(`(() => {
      const svg = document.querySelector('#graph svg');
      const wrapper = document.createElement('div');
      wrapper.style.cssText = 'position:absolute;left:0;top:0;transform-origin:0 0;will-change:transform;';
      wrapper.style.width = svg.width.baseVal.value + 'px';
      wrapper.style.height = svg.height.baseVal.value + 'px';
      wrapper.style.transform = svg.style.transform;
      svg.style.transform = '';
      svg.style.willChange = 'auto';
      svg.before(wrapper); wrapper.append(svg);
      Object.defineProperty(svg.style, 'transform', { get: () => wrapper.style.transform, set: value => { wrapper.style.transform = value; } });
    })()`);
    await gesture('wrapper-pan', false);
    await gesture('wrapper-zoom', true);
  } else {
  await gesture('pan', false);
  await gesture('zoom', true);
  await cdp.evaluate(`(() => {
    const input = document.getElementById('find-input');
    input.value = 'graph'; input.dispatchEvent(new Event('input', { bubbles: true }));
  })()`);
  await sleep(300);
  metadata.searchArrow = await cdp.evaluate('!!document.getElementById("find-arrow")');
  await gesture('zoom-with-search', true);
  await cdp.evaluate(`(async () => { const g = await import('/graph.js'); g.wire({ onRepaint: () => {} }); })()`);
  await gesture('zoom-frozen-arrow', true);
  await cdp.evaluate(`document.querySelectorAll('#graph .edge .hit').forEach(p => p.style.display = 'none')`);
  await gesture('zoom-without-hit-paths', true);
  }
  await cdp.send('Tracing.end');
  await finished;
  await writeFile(output, JSON.stringify({ traceEvents, metadata }));
  console.log('Trace:', output, JSON.stringify(metadata.graph));
} finally {
  socket?.close();
  if (chrome) { chrome.kill('SIGTERM'); await sleep(500); }
  if (server) { server.kill('SIGINT'); await sleep(500); }
  await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
}
