import { createConnection } from 'node:net';
import { spawn } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, readFile, rm, cp, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const output = resolve(process.argv[2] || '/tmp/visualize-latency.json');
const root = await mkdtemp(join(tmpdir(), 'vz-latency-'));
const chromePath = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
let server, chrome, socket;
const logs = [];
const results = [];
const metadata = { platform: process.platform, arch: process.arch, trace: process.env.VISUALIZE_TRACE || '1', workload: process.env.LATENCY_CASE || 'panes', variant: process.env.LATENCY_VARIANT || 'current', backlog: process.env.VISUALIZE_BACKLOG || '4000' };
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
function summary(samples) {
  const groups = {};
  for (const s of samples) (groups[s.kind] ||= []).push(s.ms);
  return Object.fromEntries(Object.entries(groups).map(([key, values]) => {
    values.sort((a,b) => a-b);
    const p = n => Math.round(values[Math.min(values.length-1, Math.floor(values.length*n))] * 100) / 100;
    return [key, { n: values.length, p50: p(.5), p95: p(.95), max: p(1) }];
  }));
}
try {
  await mkdir(join(root, 'project'));
  await mkdir(join(root, 'bin'));
  await writeFile(join(root, 'project', 'main.js'), 'export const a = 1;\n');
  await writeFile(join(root, 'bin', 'open'), '#!/bin/sh\nfor browser_arg do\n  case "$browser_arg" in\n    http://*|https://*) printf "%s" "$browser_arg" > "$VZ_BENCH_URL" ;;\n    --app=*) printf "%s" "${browser_arg#--app=}" > "$VZ_BENCH_URL" ;;\n  esac\ndone\n', { mode: 0o755 });
  let core = join(repo, 'src/visualize/core.janet');
  if (process.env.LATENCY_VARIANT === 'backlog-counter') {
    const variant = join(root, 'variant');
    await mkdir(variant);
    await cp(join(repo, 'src'), join(variant, 'src'), { recursive: true });
    await symlink(join(repo, 'external-src'), join(variant, 'external-src'));
    const host = join(variant, 'src/visualize/term/host.janet');
    let source = await readFile(host, 'utf8');
    source = source.replace('before (length backlog)', 'before (+ base (length backlog))')
      .replaceAll('(= (length backlog) before)', '(= (+ base (length backlog)) before)');
    await writeFile(host, source);
    core = join(variant, 'src/visualize/core.janet');
  }
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
  await cdp.send('Page.navigate', { url: url + '/?trace=1' });
  await waitFor(() => cdp.evaluate('!!window.__latency && !!document.querySelector("#harness textarea")'));
  await cdp.evaluate('document.querySelector("#harness .bar").click()');
  await sleep(1500);
  async function scenario(name, count = 100, spacing = 25, during) {
    await cdp.evaluate('document.querySelector("#harness textarea").focus(); window.__latency.clear(); performance.clearResourceTimings()');
    await cdp.evaluate(`(() => {
      const screen = document.querySelector('#harness .screen');
      const keyTimes = [];
      const visible = [];
      let seen = (screen.textContent.match(/x/g) || []).length;
      const listener = event => { if (event.key === 'x') keyTimes.push(performance.now()); };
      screen.addEventListener('keydown', listener, true);
      const observer = new MutationObserver(() => {
        const count = (screen.textContent.match(/x/g) || []).length;
        for (let i = seen; i < count && keyTimes.length; i++) {
          visible.push({ kind: 'key-to-DOM', ms: performance.now() - keyTimes.shift(), pane: 'harness', at: performance.now() });
        }
        seen = count;
      });
      observer.observe(screen, { childList: true, characterData: true, subtree: true });
      window.__echoTrace = { visible, stop: () => { observer.disconnect(); screen.removeEventListener('keydown', listener, true); } };
    })()`);
    const pending = during?.();
    for (let i = 0; i < count; i++) {
      await cdp.send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'x', code: 'KeyX', text: 'x', unmodifiedText: 'x' });
      await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'x', code: 'KeyX' });
      await sleep(spacing);
    }
    await waitFor(async () => (await cdp.evaluate('window.__latency.snapshot().filter(s => s.kind === "input-total" || s.kind === "input-error").length')) >= count, 60000);
    await pending;
    await sleep(200);
    const samples = await cdp.evaluate('window.__echoTrace.stop(); window.__latency.snapshot().concat(window.__echoTrace.visible)');
    const diagnostics = await cdp.evaluate('fetch("/diagnostics?k="+window.TOKEN).then(r=>r.json())');
    const hostDiagnostics = await cdp.evaluate('fetch("/pane/harness/diagnostics?k="+window.TOKEN, {method: "POST", body: "{}"}).then(r=>r.json())');
    const graphDiagnostics = await cdp.evaluate('fetch("/diagnostics/graph?k="+window.TOKEN).then(r=>r.ok?r.json():null)');
    const result = { name, summary: summary(samples), samples, diagnostics, graphDiagnostics, hostDiagnostics };
    results.push(result);
    await writeFile(output, JSON.stringify({ metadata, results, logs }, null, 2));
    console.log(name, JSON.stringify(result.summary));
  }
  await scenario('one-pane');
  if (process.env.LATENCY_CASE === 'protocol') {
    const { check } = await import('./stream-checks.mjs');
    await check({ cdp, url, root, waitFor, restart: async during => {
      const child = server;
      child.kill('SIGTERM');
      await new Promise(resolve => child.once('exit', resolve));
      await during();
      startServer();
    } });
  }
  else if (process.env.LATENCY_CASE === 'default-backlog') {
    const conf = await readFile(join(root, 'project', 'visualize.conf'), 'utf8');
    const path = conf.match(/@visualize terminal harness socket (.+)/)[1];
    const conn = createConnection(path);
    await new Promise((resolve, reject) => { conn.once('connect', resolve); conn.once('error', reject); });
    let carry = '';
    const pending = [];
    conn.on('data', b => {
      carry += String(b);
      for (;;) {
        const end = carry.indexOf('\n'); if (end < 0) break;
        const line = carry.slice(0, end); carry = carry.slice(end + 1);
        pending.shift()(JSON.parse(line));
      }
    });
    const ask = message => new Promise(resolve => { pending.push(resolve); conn.write(JSON.stringify(message)+'\n'); });
    try {
      let chunks = 0;
      while (chunks < 4100) {
        for (let i = 0; i < 100; i++) {
          await ask({ op: 'input', text: 'x\x7f', quiet: true });
          await sleep(1);
        }
        chunks = (await ask({ op: 'state' })).chunks;
      }
      console.log('Warmed default backlog:', chunks, 'chunks');
    } finally { conn.end(); }
    await sleep(250);
    await scenario('default-full-backlog', 100);
  }
  else if (process.env.LATENCY_CASE === 'backlog') await scenario('full-backlog', 100);
  else if (process.env.LATENCY_CASE === 'scan') {
    const files = join(root, 'project', 'files');
    await mkdir(files);
    for (let i = 0; i < 3000; i++) await writeFile(join(files, `f${i}.js`), `export const a = ${i};\n`);
    await writeFile(join(root, 'project', 'visualize.conf'), '(fold files)\n');
    await sleep(3000);
    await scenario('3000-files-idle', 150);
    await scenario('3000-files-edits', 150, 25, async () => {
      for (let i = 0; i < 12; i++) {
        await writeFile(join(files, 'f0.js'), `export const a = ${i};\n`);
        await sleep(350);
      }
    });
  }
  else for (let panes = 2; panes <= 5; panes++) {
    await cdp.evaluate('(async () => { const m = await import("/panes.js"); m.openTerminal(); })()');
    await sleep(1500);
    await scenario(panes + '-panes', 60);
  }
  console.log('Results:', output);
} finally {
  socket?.close();
  if (chrome) { chrome.kill('SIGTERM'); await sleep(500); }
  if (server) { server.kill('SIGINT'); await sleep(500); }
  await writeFile(output, JSON.stringify({ metadata, results, logs }, null, 2));
  await rm(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
}
