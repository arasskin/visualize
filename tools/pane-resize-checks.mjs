import { spawn } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, readFile, rm, cp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const output = resolve(process.argv[2] || '/tmp/visualize-pane-resize');
await mkdir(output, { recursive: true });
const checks = [];
const caseName = process.env.PANE_RESIZE_CASE || 'all';
if (!['all', 'matrix', 'hyperlinks'].includes(caseName)) throw new Error('Unknown PANE_RESIZE_CASE: ' + caseName);
let cdp;
const failures = [];
const consoleChecks = [];
let lastSnapshot;
const root = await mkdtemp(join(tmpdir(), 'vz-rails-'));
const chromePath = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
let server, chrome, socket;
const logs = [];
async function waitFor(fn, ms = 30000) {
  const end = Date.now() + ms;
  let lastError;
  while (Date.now() < end) {
    try { const out = await fn(); if (out) return out; } catch (error) { lastError = error; }
    await sleep(50);
  }
  throw new Error('Timed out: ' + fn.toString() + '\n' + (lastError?.message || '') + '\n' + logs.join('').slice(-3000));
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
      const id = ++this.id;
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error('Browser stalled: ' + method)); }, 10000);
      this.pending.set(id, { resolve: value => { clearTimeout(timer); resolve(value); }, reject: error => { clearTimeout(timer); reject(error); } });
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
  for (const part of ['src', 'src.server', 'src.vterm', 'src.wterm', 'src.graphviz', 'external-src', 'tools']) await cp(join(repo, part), join(root, 'project', part), { recursive: true });
  const config = (await readFile(join(repo, 'visualize_config'), 'utf8')).split('\n').filter(line => !line.startsWith('@visualize')).join('\n');
  await writeFile(join(root, 'project', 'visualize_config'), config);
  await writeFile(join(root, 'bin', 'open'), '#!/bin/sh\nfor browser_arg do\n  browser_arg=${browser_arg%%#*}\n  case "$browser_arg" in\n    http://*|https://*) printf "%s" "$browser_arg" > "$VZ_BENCH_URL" ;;\n    --app=*) printf "%s" "${browser_arg#--app=}" > "$VZ_BENCH_URL" ;;\n  esac\ndone\n', { mode: 0o755 });
  const fixture = join(root, 'bin', 'pane-terminal.janet');
  await cp(join(repo, 'tools/fixtures/pane-terminal.janet'), fixture);
  const shellQuote = value => "'" + value.replaceAll("'", "'\\''") + "'";
  await writeFile(join(root, 'bin', 'pane-terminal'), '#!/bin/sh\nexec ' +
    shellQuote(join(repo, 'external-src/janet/janet')) + ' ' + shellQuote(fixture) + ' "$@"\n', { mode: 0o755 });
  const core = join(repo, 'src.server/core.janet');
  const serverOptions = {
    cwd: repo, stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env, VISUALIZE_ERROR_LOG_DIR: join(root,'errors'), VISUALIZE_TRACE: process.env.VISUALIZE_TRACE || '1',
      PATH: join(root, 'bin') + ':' + process.env.PATH, VZ_BENCH_URL: join(root, 'url') },
  };
  function startServer() {
    server = spawn(join(repo, 'external-src/janet/janet'), [core, join(root, 'project'), '--no-dev', '--command', 'exec ' + shellQuote(join(root, 'bin', 'pane-terminal'))], serverOptions);
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
  cdp = new CDP(socket);
  await cdp.send('Page.enable');
  await cdp.send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false });
  await cdp.send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'light' }] });
  await cdp.send('Page.navigate', { url: url + '/?trace=1' });
  await waitFor(() => cdp.evaluate('!!window.__latency && !!document.querySelector("#harness textarea")'));

  await sleep(1500);

  await cdp.send('Runtime.enable');
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    if (message.method === 'Runtime.exceptionThrown') failures.push(message.params);
    if (message.method === 'Runtime.consoleAPICalled' && message.params.type === 'error') {
      consoleChecks.push((async () => {
        const argument = message.params.args?.[1];
        const properties = argument?.objectId
          ? (await cdp.send('Runtime.getProperties', { objectId: argument.objectId, ownProperties: true })).result
          : [];
        if (!properties.some(p => p.name === 'message' && p.value?.value === 'injected resize disconnect')) failures.push(message.params);
      })().catch(error => failures.push({ message: String(error) })));
    }
  });
  await cdp.evaluate(`(async()=>{
    window.panes=await import('/panes.js');
    window.transport=await import('/transport.js');
    window.emulators=new Map();
    const {WTerm}=await import('@wterm/dom');
    const init=WTerm.prototype.init;
    WTerm.prototype.init=function(){emulators.set(this.element.closest('.panel').id,this);return init.call(this)};
    for(const p of panes.rail)if(!p.shut)p.toggle();
    window.subject=panes.openTerminal();
    window.other=panes.openTerminal();
    other.root.style.width='400px';other.root.style.height='300px';other.resized();
    subject.root.style.width='600px';subject.root.style.height='400px';subject.resized();
    window.fixtureSnapshot=async(p=subject)=>{
      const t=emulators.get(p.root.id);
      const remote=await transport.request(p.root.id.slice(5),'poll',{at:0});
      const el=p.root.querySelector('.screen');
      const grid=el.querySelector('.term-grid');
      const active=[...el.querySelectorAll('.term-row:not(.term-scrollback-row)')];
      const rect=el.getBoundingClientRect();
      const cell=t?._measureCharSize();
      const bottom=active.at(-1)?.getBoundingClientRect();
      return {id:p.root.id,shut:p.shut,box:p.root.getBoundingClientRect().toJSON(),
        body:p.body.getBoundingClientRect().toJSON(),screen:rect.toJSON(),
        cols:t?.cols,rows:t?.rows,coreCols:t?.bridge.getCols(),coreRows:t?.bridge.getRows(),
        expected:cell?[Math.max(20,Math.floor(el.clientWidth/cell.charWidth)),Math.max(4,Math.floor(el.clientHeight/cell.rowHeight))]:null,
        remote:[remote.cols,remote.rows],activeRows:active.length,text:active.map(e=>e.textContent).join('\\n'),
        scrollTop:el.scrollTop,scrollHeight:el.scrollHeight,clientHeight:el.clientHeight,
        bottom:bottom?.toJSON(),grid:grid?.getBoundingClientRect().toJSON(),
        status:p.root.querySelector('.state').textContent,grids:el.querySelectorAll('.term-grid').length,
        inputs:el.querySelectorAll('textarea').length};
    };
  })()`);
  const fixtureCommand = 'exec ' + shellQuote(join(root, 'bin', 'pane-terminal')) + '\r';
  for (const name of ['subject', 'other']) {
    await waitFor(() => cdp.evaluate(`transport.request(${name}.root.id.slice(5),'capture',{}).then(s=>s.running)`));
    await cdp.evaluate(`transport.request(${name}.root.id.slice(5),'input',{text:${JSON.stringify(fixtureCommand)}})`);
  }
  async function snapshot() {
    lastSnapshot = await cdp.evaluate('fixtureSnapshot()');
    return lastSnapshot;
  }
  function assert(value, message) {
    if (!value) throw new Error(message + '\n' + JSON.stringify(lastSnapshot));
  }
  async function healthy(name) {
    await waitFor(async () => {
      const s = await snapshot();
      await Promise.all(consoleChecks);
      if (failures.length) throw new Error('Browser errors: ' + JSON.stringify(failures));
      return !s.shut && s.cols === s.remote[0] && s.rows === s.remote[1]
        && s.cols === s.expected?.[0] && s.rows === s.expected?.[1]
        && s.text.includes(`PANE ${s.cols}x${s.rows}`) && s.text.includes(`BOTTOM-${s.cols}x${s.rows}`);
    }, 7000);
    const s = lastSnapshot;
    assert(s.cols === s.coreCols && s.rows === s.coreRows, 'emulator/core sizes differ');
    assert(s.activeRows === s.rows, 'rendered row count differs');
    assert(s.grids === 1 && s.inputs === 1, 'duplicate or missing terminal DOM');
    assert(s.screen.width > 0 && s.screen.height > 0, 'terminal is blank or hidden');
    assert(s.bottom.top < s.screen.bottom && s.bottom.bottom <= s.screen.bottom + 2, 'last terminal row is clipped');
    assert(!s.status, 'terminal status error: ' + s.status);
    assert(!failures.length, 'browser errors: ' + JSON.stringify(failures));
    checks.push(name);
    console.log('PASS', name);
  }
  async function drag(handle, dx, dy, steps = 8, delay = 15) {
    const rect = await cdp.evaluate(`${handle}.getBoundingClientRect().toJSON()`);
    const x = rect.x + Math.min(5, rect.width / 2), y = rect.y + Math.min(5, rect.height / 2);
    await cdp.send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', buttons: 1, clickCount: 1 });
    for (let i = 1; i <= steps; i++) {
      await cdp.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: x + dx * i / steps, y: y + dy * i / steps, button: 'left', buttons: 1 });
      if (delay) await sleep(delay);
    }
    await cdp.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: x + dx, y: y + dy, button: 'left', buttons: 0, clickCount: 1 });
  }
  async function position(side) {
    await cdp.evaluate(`subject.open();panes.addToRail(subject,0,${JSON.stringify(side === 'floating' ? 'top' : side)});subject.root.style.width='600px';subject.root.style.height='400px';subject.resized();panes.selectPane(subject.root);panes.packRailNow()`);
    await sleep(100);
    if (side === 'floating') await drag('subject.bar', 180, 150);
    await healthy(side + ': initial contents');
    assert(await cdp.evaluate(side === 'floating' ? '!panes.onRail(subject)' : `subject.root.dataset.rail===${JSON.stringify(side)}`), 'wrong docking');
  }
  await healthy('initial output');
  if (caseName === 'hyperlinks') {
    await cdp.evaluate('subject.type("nl")');
    await waitFor(() => cdp.evaluate('!!subject.root.querySelector(".term-link")'));
    assert(await cdp.evaluate('!!subject.root.querySelector(".term-link")'), 'terminal recognizes visible web URLs');
    await position('top');
    for (const [dx,dy] of [[100,90],[-160,-130],[80,0],[0,60]]) {
      await drag('subject.grip', dx, dy);
      await healthy(`hyperlinked output: resize ${dx},${dy}`);
    }
    await cdp.evaluate('subject.type("mq")');
    await waitFor(()=>cdp.evaluate('subject.root.querySelector(".screen").textContent.includes(" q")'));
    await cdp.evaluate('window.getSelection().removeAllRanges()');
    await drag('subject.root.querySelector(".term-row:not(.term-scrollback-row)")', 100, 0, 10, 30);
    assert(await cdp.evaluate('window.getSelection().toString().length > 5'), 'plain dragging selects text even with application mouse reporting enabled');
    checks.push('native drag selection with application mouse reporting');
    await cdp.evaluate(`window.getSelection().removeAllRanges();window.linkClicks=[];document.addEventListener('click',event=>{if(event.target.closest('.term-link')){linkClicks.push(!event.defaultPrevented);event.preventDefault()}})`);
    const link = await cdp.evaluate('subject.root.querySelector(".term-link").getBoundingClientRect().toJSON()');
    await cdp.send('Input.dispatchMouseEvent',{type:'mousePressed',x:link.x+5,y:link.y+5,button:'left',buttons:1,clickCount:1});
    await cdp.send('Input.dispatchMouseEvent',{type:'mouseReleased',x:link.x+5,y:link.y+5,button:'left',buttons:0,clickCount:1});
    assert(await cdp.evaluate('linkClicks.at(-1)===true'), 'plain link clicks allow browser navigation');
    checks.push('clickable web links without a modifier');
    await cdp.evaluate('window.allowedBeforeDrag=linkClicks.filter(Boolean).length');
    await drag('subject.root.querySelector(".term-link")', 70, 0, 10, 30);
    assert(await cdp.evaluate('window.getSelection().toString().length>0 && linkClicks.filter(Boolean).length===allowedBeforeDrag'), 'dragging over a link selects it without navigating: ' + JSON.stringify(await cdp.evaluate('({selection:window.getSelection().toString(),clicks:linkClicks,link:subject.root.querySelector(".term-link").outerHTML})')));
    checks.push('link dragging selects text without navigation');
  } else {
  for (const mode of ['normal', 'alternate']) {
    await cdp.evaluate(`subject.type(${JSON.stringify(mode === 'normal' ? 'n' : 'a')})`);
    for (const side of ['top', 'bottom', 'floating']) {
      await position(side);
      const sign = side === 'bottom' ? -1 : 1;
      for (const [name, dx, dy] of [['grow',100,90],['shrink',-160,-130],['width only',80,0],['height only',0,60]]) {
        const before = await snapshot();
        await drag('subject.grip', dx, dy * sign);
        await healthy(`${mode}/${side}: ${name}`);
        assert(Math.abs(lastSnapshot.box.width - before.box.width - dx) < 2, 'drag width differs');
        assert(Math.abs(lastSnapshot.box.height - before.box.height - dy) < 2, 'drag height differs');
        if (side === 'bottom') assert(Math.abs(lastSnapshot.box.bottom - 994) < 2, 'bottom anchor moved');
      }
      await drag('subject.grip', -200, -160 * sign, 20, 0);
      await healthy(`${mode}/${side}: rapid shrink`);
      await drag('subject.grip', 210, 170 * sign, 20, 0);
      await healthy(`${mode}/${side}: rapid grow`);
      await cdp.evaluate('subject.resized();subject.toggle()');
      const closed = await snapshot();
      await drag('subject.grip', 75, 25 * sign);
      await sleep(250);
      const resized = await snapshot();
      assert(resized.shut && resized.remote.join() === closed.remote.join(), 'closed tab changed PTY dimensions');
      assert(resized.rows === closed.rows && resized.cols === closed.cols, 'closed tab resized emulator');
      await cdp.evaluate('subject.open()');
      await healthy(`${mode}/${side}: collapse, drag width, reopen`);
      await cdp.evaluate('subject.toggle();subject.open();subject.toggle();subject.open();subject.resized()');
      await healthy(`${mode}/${side}: rapid toggle`);
    }
  }
  await position('top');
  await drag('subject.grip', 80, 40, 6, 180);
  await healthy('slow drag with intermediate PTY resizes');
  await drag('subject.grip', -1000, -1000);
  await healthy('minimum terminal dimensions');
  assert(lastSnapshot.box.width === 360 && lastSnapshot.box.height === 200, 'terminal minimum size not enforced');
  await position('top');
  await cdp.evaluate('subject.root.style.height="900px";subject.resized()');
  await healthy('tall terminal before floor snap');
  await drag('subject.grip', 0, 60);
  await healthy('resize snaps to viewport floor');
  assert(Math.abs(lastSnapshot.box.bottom - 1000) < 2, 'floor snap failed');
  await position('top');
  for (const [width,height,dpr] of [[900,650,1],[1440,1000,2],[1100,800,2],[1440,1000,1]]) {
    await cdp.send('Emulation.setDeviceMetricsOverride', {width,height,deviceScaleFactor:dpr,mobile:false});
    await healthy(`viewport ${width}x${height} DPR ${dpr}`);
  }
  await position('bottom');
  await cdp.evaluate('subject.toggle()');
  const hidden = await snapshot();
  await cdp.send('Emulation.setDeviceMetricsOverride',{width:1000,height:700,deviceScaleFactor:1,mobile:false});
  await sleep(300);
  assert((await snapshot()).remote.join()===hidden.remote.join(),'viewport resize changed a collapsed PTY');
  await cdp.evaluate('subject.open()');
  await healthy('collapsed pane survives viewport resize');
  assert(Math.abs(lastSnapshot.box.bottom-694)<2,'bottom tab lost its viewport anchor');
  await cdp.send('Emulation.setDeviceMetricsOverride',{width:1440,height:1000,deviceScaleFactor:1,mobile:false});
  await position('top');
  await cdp.evaluate('subject.type("nqs")');
  await healthy('normal scrollback before resize');
  await drag('subject.grip', -130, -70);
  await healthy('paused output survives shrinking');
  await drag('subject.grip', 180, 100);
  await healthy('paused output survives growing');
  await cdp.evaluate('subject.root.querySelector(".screen").scrollTop=0');
  await sleep(150);
  const history=await cdp.evaluate('subject.root.querySelector(".term-scrollback-row")?.textContent.trim()');
  assert(history?.includes('HISTORY-'), 'scrollback fixture is missing');
  await drag('subject.grip', -40, 0);
  await sleep(500);
  assert(await cdp.evaluate('subject.root.querySelector(".screen").scrollTop<20'),'resizing forced a user reading history to the bottom');
  assert(await cdp.evaluate(`subject.root.querySelector('.term-scrollback-row')?.textContent.trim()===${JSON.stringify(history)}`),'resize changed the visible history anchor');
  checks.push('resize preserves user scrollback position');
  await cdp.evaluate('subject.root.querySelector(".screen").scrollTop=subject.root.querySelector(".screen").scrollHeight');
  await sleep(100);
  await cdp.evaluate('subject.type("w")');
  await healthy('output resumes after scrollback resize');
  await cdp.evaluate('subject.type("f")');
  await waitFor(async()=> (await snapshot()).text.includes(' f'));
  for(const [dx,dy] of [[70,0],[-40,0],[0,40],[0,-60]]){
    await drag('subject.grip',dx,dy);
    await waitFor(async()=>{const s=await snapshot();return s.cols===s.remote[0] && s.rows===s.remote[1] && s.cols===s.expected[0] && s.rows===s.expected[1]});
    await sleep(100);
    const frozen=await snapshot();
    assert(frozen.text.includes('BOTTOM-') && frozen.text.includes('ROW-'),'static output blanked during resize');
    checks.push(`no application redraw: resize ${dx},${dy}`);
  }
  await cdp.evaluate('subject.type("w")');
  await healthy('static application resumes after resize');
  const sibling = await cdp.evaluate('fixtureSnapshot(other)');
  await drag('subject.grip', 40, 30);
  await healthy('one pane resizes under sibling output');
  const siblingAfter = await cdp.evaluate('fixtureSnapshot(other)');
  assert(sibling.remote.join() === siblingAfter.remote.join(), 'resizing changed sibling dimensions');
  await cdp.evaluate('subject.type("h");subject.root.style.width="650px";subject.resized()');
  await healthy('resize during synchronized output');
  await cdp.evaluate(`window.failedResize=0;const send=WebSocket.prototype.send;WebSocket.prototype.send=function(text){const m=JSON.parse(text);if(!failedResize && m.type==='request' && m.op==='resize' && m.pane===subject.root.id.slice(5)){failedResize++;throw new Error('injected resize disconnect')}return send.call(this,text)};subject.root.style.width='690px';subject.resized()`);
  await healthy('failed resize delivery retries without another drag');
  assert(await cdp.evaluate('failedResize===1'),'resize failure injection did not fire');
  await cdp.evaluate(`transport.request(subject.root.id.slice(5),'start',{rows:24,cols:80})`);
  await cdp.evaluate(`transport.request(subject.root.id.slice(5),'input',{text:${JSON.stringify(fixtureCommand)}})`);
  await healthy('new terminal generation restores the pane size');
  await cdp.evaluate('subject.toggle();other.toggle();window.config=panes.configPanel');
  for (const side of ['top','bottom','floating']) {
    await cdp.evaluate(`config.open();panes.selectPane(config.root);panes.addToRail(config,0,${JSON.stringify(side==='floating'?'top':side)});config.root.style.width='500px';config.root.style.height='350px';panes.packRailNow()`);
    await waitFor(() => cdp.evaluate('!!config.body.querySelector(".config-diagram .node")'));
    await sleep(100);
    if(side==='floating')await drag('config.bar',160,150);
    const sign=side==='bottom'?-1:1;
    for(const [dx,dy] of [[70,60],[-120,-100],[60,0],[0,50]]){
      const before=await cdp.evaluate('config.root.getBoundingClientRect().toJSON()');
      await drag('config.grip',dx,dy*sign);
      const after=await cdp.evaluate('({box:config.root.getBoundingClientRect().toJSON(),body:config.body.getBoundingClientRect().toJSON(),text:config.body.textContent})');
      assert(Math.abs(after.box.width-before.width-dx)<2 && Math.abs(after.box.height-before.height-dy)<2,'config drag dimensions differ');
      assert(after.body.height>0 && after.text.trim().length>0,'config contents blanked');
      checks.push(`Visualize/${side}: resize ${dx},${dy}`);
    }
    await cdp.evaluate('config.toggle()');
    const width=await cdp.evaluate('config.root.offsetWidth');
    await drag('config.grip',50,0);
    await cdp.evaluate('config.open()');
    assert(await cdp.evaluate(`config.root.offsetWidth===${width+50} && config.body.clientHeight>0`),'config reopen lost dimensions');
    checks.push(`Visualize/${side}: collapsed width resize`);
    await cdp.evaluate('config.toggle()');
  }
  await cdp.evaluate('subject.open();other.open();panes.selectPane(subject.root)');
  await healthy('terminals survive resizing Visualize');
  await cdp.evaluate('subject.root.querySelector("textarea").focus()');
  await cdp.send('Input.insertText',{text:'Z'});
  await waitFor(async () => (await snapshot()).text.includes(' Z'));
  checks.push('keyboard input still reaches resized pane');
  }
  await cdp.send('Page.captureScreenshot', {format:'png'}).then(shot => writeFile(join(output,'final.png'),Buffer.from(shot.data,'base64')));
  await writeFile(join(output,'report.json'), JSON.stringify({checks,failures,lastSnapshot},null,2));
  console.log(`Passed ${checks.length} pane resize checks. Artifacts: ${output}`);
  if (caseName === 'all') {
    const child = spawn(process.execPath, [fileURLToPath(import.meta.url), join(output, 'hyperlinks')], {stdio:'inherit',env:{...process.env,PANE_RESIZE_CASE:'hyperlinks'}});
    const code = await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',resolve)});
    if (code !== 0) throw new Error('Hyperlink resize regression failed; see ' + join(output,'hyperlinks','failure.json'));
  }
} catch (error) {
  await writeFile(join(output,'failure.json'),JSON.stringify({error:error.stack,checks,failures,lastSnapshot,logs},null,2));
  if (cdp) await cdp.send('Page.captureScreenshot',{format:'png'}).then(shot=>writeFile(join(output,'failure.png'),Buffer.from(shot.data,'base64'))).catch(()=>{});
  throw error;
} finally {
  socket?.close();
  if(chrome){chrome.kill('SIGTERM');await sleep(500);}
  if(server){server.kill('SIGINT');await sleep(500);}
  await rm(root,{recursive:true,force:true,maxRetries:5,retryDelay:200});
}
