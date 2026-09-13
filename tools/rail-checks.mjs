import { spawn } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, readFile, rm, cp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const output = resolve(process.argv[2] || '/tmp/visualize-rails.png');
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
  for (const part of ['src', 'src.server', 'src.mcp', 'src.vterm', 'src.wterm', 'src.graphviz', 'external-src', 'tools']) await cp(join(repo, part), join(root, 'project', part), { recursive: true });
  const config = (await readFile(join(repo, 'visualize.conf'), 'utf8')).split('\n').filter(line => !line.startsWith('@visualize')).join('\n');
  await writeFile(join(root, 'project', 'visualize.conf'), config);
  await writeFile(join(root, 'bin', 'open'), '#!/bin/sh\nfor browser_arg do\n  browser_arg=${browser_arg%%#*}\n  case "$browser_arg" in\n    http://*|https://*) printf "%s" "$browser_arg" > "$VZ_BENCH_URL" ;;\n    --app=*) printf "%s" "${browser_arg#--app=}" > "$VZ_BENCH_URL" ;;\n  esac\ndone\n', { mode: 0o755 });
  const core = join(repo, 'src.server/core.janet');
  const serverOptions = {
    cwd: repo, stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env, VISUALIZE_TRACE: process.env.VISUALIZE_TRACE || '1',
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




  await cdp.send('Runtime.enable');
  const failures = [];
  socket.addEventListener('message', e => { const m=JSON.parse(e.data); if(m.method==='Runtime.exceptionThrown') failures.push(m.params); });
  await sleep(1000);
  const checks=[];
  async function check(expression,name) {
    if(!await cdp.evaluate(`(async()=>(${expression}))()`))throw new Error(name);
    checks.push(name);
  }
  async function drag(x,y,dx,dy) {
    await cdp.send('Input.dispatchMouseEvent',{type:'mousePressed',x,y,button:'left',buttons:1,clickCount:1});
    for(let i=1;i<=8;i++) {
      await cdp.send('Input.dispatchMouseEvent',{type:'mouseMoved',x:x+dx*i/8,y:y+dy*i/8,button:'left',buttons:1});
      await sleep(20);
    }
    await cdp.send('Input.dispatchMouseEvent',{type:'mouseReleased',x:x+dx,y:y+dy,button:'left',buttons:0,clickCount:1});
    await sleep(200);
  }
  await cdp.evaluate(`(async()=>{
    window.panes=await import('/panes.js');
    window.config=panes.configPanel;
    if(config.root.dataset.rail!=='bottom'||config.root.offsetWidth>416)throw new Error('Visualize default placement or width');
    panes.addToRail(config,0,'top');
    config.root.style.width='400px';
    document.querySelector('#harness').style.width='400px';
    panes.packRailNow();
  })()`);
  await check('!document.querySelector("#hud,#term-new,#help-open,#bin")','bottom controls and trash can removed');
  await cdp.evaluate('document.querySelector("#find").classList.remove("shut");document.querySelector("#compose").classList.remove("shut")');
  await check('Math.abs(document.querySelector("#find-box").getBoundingClientRect().top-document.querySelector("#compose-box").getBoundingClientRect().top)<1','search and command inputs align');
  await cdp.evaluate('document.querySelector("#find").classList.add("shut");document.querySelector("#compose").classList.add("shut")');
  await drag(25,20,0,960);
  await check('config.root.dataset.rail==="bottom"','native drag docks at bottom');
  await check('Math.abs(config.root.getBoundingClientRect().bottom-994)<1','closed tab has 6px bottom inset');
  await cdp.evaluate('config.open();panes.packRailNow()');
  await check('!config.shut && config.body.getBoundingClientRect().bottom<=config.bar.getBoundingClientRect().top+1','bottom panel opens upward');
  await check('Math.abs(config.root.getBoundingClientRect().bottom-994)<1','opening preserves bottom inset');
  const before=await cdp.evaluate('({width:config.root.offsetWidth,height:config.root.offsetHeight,grip:config.grip.getBoundingClientRect().toJSON()})');
  await drag(before.grip.x+6,before.grip.y+6,50,-70);
  await check(`config.root.offsetHeight===${before.height+70} && config.root.offsetWidth===${before.width+50}`,'bottom grip grows upward and right');
  await check('Math.abs(config.root.getBoundingClientRect().bottom-994)<1','resize preserves bottom inset');
  await cdp.evaluate('config.toggle();panes.packRailNow()');
  const grip=await cdp.evaluate('config.grip.getBoundingClientRect().toJSON()');
  await drag(grip.x+4,grip.y+8,40,0);
  await check(`config.shut && config.root.offsetWidth===${before.width+90}`,'closed bottom tab resizes horizontally');
  await cdp.evaluate(`panes.addToRail(panes.rail.find(p=>p.root.id==='harness'),undefined,'bottom');panes.packRailNow()`);
  await check('Math.abs(document.querySelector("#harness").getBoundingClientRect().left-config.root.getBoundingClientRect().right-6)<1','bottom tab gap matches edge inset');
  await cdp.send('Emulation.setDeviceMetricsOverride',{width:1000,height:700,deviceScaleFactor:1,mobile:false});
  await sleep(300);
  await check('Math.abs(config.root.getBoundingClientRect().bottom-694)<1','bottom tabs follow viewport resize');
  await drag(25,680,0,-660);
  await check('config.root.dataset.rail==="top" && !config.root.classList.contains("bottom-docked")','native drag moves bottom tab to top');
  await cdp.evaluate('config.open();panes.packRailNow()');
  await check('config.body.getBoundingClientRect().top>=config.bar.getBoundingClientRect().bottom-1','top panel opens downward');
  await cdp.evaluate('config.toggle();panes.packRailNow()');
  await drag(25,20,250,260);
  await check('!panes.onRail(config)','tab can undock between rails');
  await cdp.evaluate(`panes.addToRail(config);panes.packRailNow();panes.selectPane(document.querySelector('#harness'));window.extra=panes.openTerminal();extra.root.style.width='750px';panes.packRailNow()`);
  await check('extra.root.dataset.rail==="bottom"','new terminal uses selected bottom rail');
  const topLeft=await cdp.evaluate('config.root.getBoundingClientRect().left');
  const bottomLeft=await cdp.evaluate('document.querySelector("#harness").getBoundingClientRect().left');
  await cdp.send('Input.dispatchMouseEvent',{type:'mouseWheel',x:300,y:685,deltaX:-200,deltaY:0});
  await sleep(200);
  await check(`document.querySelector('#harness').getBoundingClientRect().left>${bottomLeft} && config.root.getBoundingClientRect().left===${topLeft}`,'bottom rail scrolls independently of top');
  await cdp.evaluate('extra.root.style.width="480px";panes.packRailNow()');
  await sleep(400);
  await cdp.evaluate(`window.readTerminalSize=async()=>{
    const {request}=await import('/transport.js');
    const out=await request(extra.root.id.slice(5),'poll',{at:0});
    return JSON.stringify([out.rows,out.cols]);
  }`);
  const terminalSize=await cdp.evaluate('readTerminalSize()');
  await cdp.evaluate('extra.resized();extra.toggle()');
  await sleep(250);
  await check(`extra.shut && await readTerminalSize()===${JSON.stringify(terminalSize)}`,'closing cancels pending terminal resize');
  await cdp.evaluate('extra.root.style.width="510px";extra.resized()');
  await sleep(250);
  await check(`await readTerminalSize()===${JSON.stringify(terminalSize)}`,'closed tab resize preserves terminal dimensions');
  await cdp.evaluate('extra.open()');
  await sleep(350);
  await check(`await readTerminalSize()!==${JSON.stringify(terminalSize)}`,'reopening applies the visible terminal dimensions');
  await cdp.evaluate('window.closeCalls=0;const stop=extra.stop;extra.stop=()=>{closeCalls++;return stop()}');
  const close=await cdp.evaluate('extra.root.querySelector(".tab-close").getBoundingClientRect().toJSON()');
  await cdp.send('Input.dispatchMouseEvent',{type:'mousePressed',x:close.x+close.width/2,y:close.y+close.height/2,button:'left',buttons:1,clickCount:1});
  await cdp.send('Input.dispatchMouseEvent',{type:'mouseReleased',x:close.x+close.width/2,y:close.y+close.height/2,button:'left',buttons:0,clickCount:1});
  await check('!extra.root.isConnected && closeCalls===1 && config.root.isConnected','tab close removes only its terminal and stops its session');
  async function altKey(code, key) {
    await cdp.send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Alt', code: 'AltLeft', modifiers: 1 });
    await cdp.send('Input.dispatchKeyEvent', { type: 'keyDown', key, code, modifiers: 1 });
    await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key, code, modifiers: 1 });
    await cdp.send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Alt', code: 'AltLeft', modifiers: 0 });
    await sleep(100);
  }
  await cdp.evaluate("panes.selectPane(document.getElementById('harness'))");
  await altKey('Enter', 'Enter');
  await check("panes.pickedPanel().root.dataset.rail === 'top' && !panes.pickedPanel().shut", 'Alt Enter opens a top terminal from a selected bottom pane');
  await cdp.evaluate("window.created = panes.pickedPanel(); window.bottomExtra = panes.openTerminal('bottom'); panes.selectPane(config.root)");
  await altKey('KeyH', 'h');
  await check('panes.pickedPanel() === bottomExtra', 'left from top left continues at bottom right');
  await altKey('KeyL', 'l');
  await check('panes.pickedPanel() === config', 'right from bottom right continues at top left');
  await altKey('KeyL', 'l');
  await check('panes.pickedPanel() === created', 'right traverses the top rail in visual order');
  await altKey('KeyL', 'l');
  await check('panes.pickedPanel() === created', 'right stops at the top right endpoint');
  await altKey('KeyH', 'h');
  await check('panes.pickedPanel() === config', 'left traverses the top rail');
  await altKey('KeyH', 'h');
  await check('panes.pickedPanel() === bottomExtra', 'left crosses back onto the bottom rail');
  await altKey('KeyH', 'h');
  await check("panes.pickedPanel().root.id === 'harness'", 'left traverses the bottom rail');
  await altKey('KeyH', 'h');
  await check("panes.pickedPanel().root.id === 'harness'", 'left stops at the bottom left endpoint');
  await cdp.evaluate("panes.addToRail(created, 0, 'top'); panes.selectPane(created.root)");
  await altKey('KeyL', 'l');
  await check('panes.pickedPanel() === config', 'navigation follows reordered tabs');
  await cdp.evaluate("created.root.style.width='350px'; panes.selectPane(created.root); panes.packRailNow()");
  const floatingId = await cdp.evaluate('created.root.id');
  const floatingBar = await cdp.evaluate('created.bar.getBoundingClientRect().toJSON()');
  await drag(floatingBar.x+10,floatingBar.y+12,260,220);
  await check('!panes.onRail(created)', 'recovery fixture has a floating terminal');
  const snapshot = `JSON.stringify({rails:['top','bottom'].map(side=>panes.rail.filter(p=>p.root.dataset.rail===side).map(p=>p.root.id)),floating:(()=>{const r=document.getElementById(${JSON.stringify(floatingId)});return [r.offsetLeft,r.offsetTop]})()})`;
  const expected = await cdp.evaluate(snapshot);
  await waitFor(async () => {
    const lines = await readFile(join(root,'project','visualize.conf'),'utf8');
    const [x,y] = JSON.parse(expected).floating;
    return lines.includes(`@visualize placement ${floatingId.slice(5)} floating ${x} ${y}`);
  });
  await cdp.send('Page.reload');
  await waitFor(() => cdp.evaluate(`!!document.getElementById(${JSON.stringify(floatingId)})`));
  await cdp.evaluate("import('/panes.js').then(module=>{window.panes=module})");
  await check(`${snapshot}===${JSON.stringify(expected)}`, 'reload restores both rail orders and floating terminal coordinates');
  await cdp.send('Page.navigate', {url:'about:blank'});
  const stopped = new Promise(resolve=>server.once('exit',resolve));
  server.kill('SIGTERM');
  await stopped;
  await rm(join(root,'url'));
  startServer();
  const recoveredUrl = await waitFor(()=>readFile(join(root,'url'),'utf8'));
  await cdp.send('Page.navigate',{url:recoveredUrl});
  await waitFor(()=>cdp.evaluate(`!!document.getElementById(${JSON.stringify(floatingId)})`));
  await cdp.evaluate("import('/panes.js').then(module=>{window.panes=module})");
  await check(`${snapshot}===${JSON.stringify(expected)}`, 'server restart recovers terminal rail order and floating coordinates');
  await check(`!document.getElementById(${JSON.stringify(floatingId)}).classList.contains('shut')`, 'recovered floating terminal opens at its saved position');
  console.log(JSON.stringify(checks,null,2));
  if(failures.length)throw new Error(JSON.stringify(failures));
  const shot=await cdp.send('Page.captureScreenshot',{format:'png'});
  await writeFile(output,Buffer.from(shot.data,'base64'));
} finally {
 socket?.close();
 if(chrome){chrome.kill('SIGTERM');await sleep(500);}
 if(server){server.kill('SIGINT');await sleep(500);}
 await rm(root,{recursive:true,force:true,maxRetries:5,retryDelay:200});
}
