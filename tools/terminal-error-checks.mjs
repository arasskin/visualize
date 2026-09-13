import { spawn } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, readFile, rm, cp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const output = resolve(process.argv[2] || '/tmp/visualize-terminal-errors.png');
const root = await mkdtemp(join(tmpdir(), 'vz-rails-'));
const chromePath = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
let server, chrome, socket;
const logs = [];
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
  const config = '(only sample) (only group) (only ?)\n(fold group)\n(prefix short sample)\n';
  await mkdir(join(root,'project','group'));
  await writeFile(join(root,'project','sample.py'),'import missing_dependency\n');
  await writeFile(join(root,'project',"sample ' $` ü.txt"),'file payload');
  await writeFile(join(root,'project','group','a.py'),'a=1');
  await writeFile(join(root,'project','group','b.py'),'b=1');
  await writeFile(join(root, 'project', 'visualize.conf'), config);
  await writeFile(join(root, 'bin', 'open'), '#!/bin/sh\nfor browser_arg do\n  browser_arg=${browser_arg%%#*}\n  case "$browser_arg" in\n    http://*|https://*) printf "%s" "$browser_arg" > "$VZ_BENCH_URL" ;;\n    --app=*) printf "%s" "${browser_arg#--app=}" > "$VZ_BENCH_URL" ;;\n  esac\ndone\n', { mode: 0o755 });
  const core = join(repo, 'src.server/core.janet');
  const serverOptions = {
    cwd: repo, stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env, VISUALIZE_ERROR_LOG_DIR: join(root,'errors'), VISUALIZE_TRACE: process.env.VISUALIZE_TRACE || '1',
      PATH: join(root, 'bin') + ':' + process.env.PATH, VZ_BENCH_URL: join(root, 'url') },
  };
  function startServer() {
    server = spawn(join(repo, 'external-src/janet/janet'), [core, join(root, 'project'), '--no-dev', '--command', 'exec /bin/cat'], serverOptions);
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
  await cdp.send('Page.enable');
  await cdp.send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false });
  await cdp.send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'light' }] });
  await cdp.send('Page.navigate', { url: url + '/?trace=1' });
  await waitFor(() => cdp.evaluate('!!window.__latency && !!document.querySelector("#harness textarea")'));
  
  await sleep(1500);




  const denied=await fetch(url+'/errors?k=invalid',{method:'POST',body:'{}'});
  if(denied.status!==403)throw new Error('error endpoint accepted unauthenticated report');
  await cdp.evaluate(`(async()=>{
    const {reportError}=await import('/errors.js');
    const send=window.fetch;
    window.logOffline=true;
    window.fetch=(url,options)=>logOffline && String(url).startsWith('/errors?')?Promise.reject(new Error('offline')):send(url,options);
    const error=new Error('synthetic unreachable');
    error.stack='RuntimeError: unreachable at /terminal?k=secret-token';
    reportError(error,{pane:'harness',phase:'resize',rows:20,cols:112});
    reportError(error,{pane:'harness',phase:'resize',rows:20,cols:112});
  })()`);
  await sleep(100);
  const queued=await cdp.evaluate('JSON.parse(localStorage.getItem("visualize-terminal-errors"))');
  if(queued.length!==1 || queued[0].stack.includes('secret-token'))throw new Error('deduplication or redaction failed');
  await cdp.evaluate('logOffline=false;window.dispatchEvent(new Event("online"))');
  const path=join(root,'errors','terminal-errors.jsonl');
  const entries=await waitFor(async()=>{
    const lines=(await readFile(path,'utf8')).trim().split('\n').map(JSON.parse);
    return lines.length?lines:null;
  });
  if(entries.length!==1 || entries[0].phase!=='resize' || entries[0].pane!=='harness' || entries[0].cols!=='112' || !entries[0].stack.includes('[redacted]'))throw new Error('persistent log fields differ');
  await waitFor(()=>cdp.evaluate('JSON.parse(localStorage.getItem("visualize-terminal-errors")).length===0'));
  console.log('Error logging checks passed: authentication, deduplication, redaction, offline queue, disk persistence, acknowledgment');
} finally {
  socket?.close();
  if(chrome){chrome.kill('SIGTERM');await sleep(500);}
  if(server){server.kill('SIGINT');await sleep(500);}
  await rm(root,{recursive:true,force:true,maxRetries:5,retryDelay:200});
}
