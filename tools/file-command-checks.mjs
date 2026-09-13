import { spawn } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, readFile, rm, cp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const output = resolve(process.argv[2] || '/tmp/visualize-file-command.png');
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
  const config = 'only sample\nonly group\nonly ?\nfold group\nprefix short sample\n';
  await mkdir(join(root,'project','group'));
  await writeFile(join(root,'project','sample.py'),'import missing_dependency\n');
  await writeFile(join(root,'project','sample.md'),'# Reading test\n\nA **bold** word and an [unsafe link](javascript:alert(1)).\n\n<script>window.markdownUnsafe=true</script>\n\n' + '| Bug | Retailer | Status / cause | Evidence | Fix / verification |\n| --- | --- | --- | --- | --- |\n| Premature payment handoff | iHerb | Open; confirmed: checkout matches the cart hostname. | Latest run reached the cart. | Verify locale redirects reach the cart on the affected configuration. |\n\n' + 'A long paragraph with words that wrap naturally. '.repeat(2000));
  await writeFile(join(root,'project',"sample ' $` ü.txt"),'file payload');
  await writeFile(join(root,'project','group','a.py'),'a=1');
  await writeFile(join(root,'project','group','b.py'),'b=1');
  await writeFile(join(root, 'project', 'visualize_config'), config);
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
  const failures=[];
  socket.addEventListener('message',event=>{const m=JSON.parse(event.data);if(m.method==='Runtime.exceptionThrown')failures.push(m.params)});
  await cdp.evaluate(`(async()=>{window.graph=await import('/graph.js');window.panes=await import('/panes.js');for(const p of panes.rail)if(!p.shut)p.toggle();graph.fit()})()`);
  await sleep(200);
  const checks=[];
  function assert(value,name){if(!value)throw new Error(name);checks.push(name)}
  async function target(part){
    return cdp.evaluate(`(()=>{const node=[...document.querySelectorAll('g.node')].find(n=>n.querySelector('title')?.textContent.includes(${JSON.stringify(part)}));if(!node)throw new Error('missing node');return graph.screenBounds(node.querySelector('text'))})()`);
  }
  async function click(box){
    const x=box.left+box.width/2,y=box.top+box.height/2;
    await cdp.send('Input.dispatchMouseEvent',{type:'mousePressed',x,y,button:'left',buttons:1,clickCount:1});
    await cdp.send('Input.dispatchMouseEvent',{type:'mouseReleased',x,y,button:'left',buttons:0,clickCount:1});
    return {x,y};
  }
  let box=await target('sample.py');
  const position=await click(box);
  await waitFor(()=>cdp.evaluate('document.activeElement===document.querySelector("#file-command input")'));
  assert(await cdp.evaluate('document.querySelector("#file-command label").textContent.includes("sample.py")'),'aliased file label opens the correct file prompt');
  const prompt=await cdp.evaluate('document.querySelector("#file-command").getBoundingClientRect().toJSON()');
  assert(Math.abs(prompt.x-position.x)<2 && Math.abs(prompt.y-position.y)<2,'prompt appears at click');
  await cdp.send('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape'});
  assert(!await cdp.evaluate('!!document.querySelector("#file-command")'),'Escape cancels');
  await click(await target('group'));
  assert(!await cdp.evaluate('!!document.querySelector("#file-command")'),'folded node does not launch a command');
  await click(await target('?.missing_dependency'));
  assert(!await cdp.evaluate('!!document.querySelector("#file-command")'),'external node does not launch a command');
  box=await target('sample.py');
  const x=box.left+box.width/2,y=box.top+box.height/2;
  await cdp.send('Input.dispatchMouseEvent',{type:'mousePressed',x,y,button:'left',buttons:1,clickCount:1});
  await cdp.send('Input.dispatchMouseEvent',{type:'mouseMoved',x:x+40,y:y+25,button:'left',buttons:1});
  await cdp.send('Input.dispatchMouseEvent',{type:'mouseReleased',x:x+40,y:y+25,button:'left',buttons:0});
  assert(!await cdp.evaluate('!!document.querySelector("#file-command")'),'dragging a file label pans without a prompt');
  const zoomBox=await target('sample.txt');
  await cdp.evaluate(`graph.zoomAt(1.4,${zoomBox.left+zoomBox.width/2},${zoomBox.top+zoomBox.height/2})`);
  await sleep(100);
  const launchPoint=await click(await target("sample.txt"));
  await waitFor(()=>cdp.evaluate('!!document.querySelector("#file-command input")'));
  const shellQuote = value => "'" + value.replaceAll("'", "'\\''") + "'";
  const expression = '(do (print "ARGC=" (length $&)) (print (string/join (seq [byte :in (first $&)] (string/format "%02x" byte)))))';
  const command = shellQuote(join(repo, 'external-src/janet/janet')) + ' -E ' + shellQuote(expression);
  await cdp.send('Input.insertText',{text:command});
  await cdp.send('Input.dispatchKeyEvent',{type:'keyDown',key:'Enter',code:'Enter',text:'\r'});
  const path=join(root,'project',"sample ' $` ü.txt");
  const hex=Buffer.from(path).toString('hex');
  await waitFor(()=>cdp.evaluate(`document.querySelector('[id^="pane-"] .screen')?.textContent.replace(/\\s/g,'').includes(${JSON.stringify(hex)})`));
  const terminal=await cdp.evaluate(`(()=>{const p=document.querySelector('[id^="pane-"]');return {text:p.querySelector('.screen').textContent,box:p.getBoundingClientRect().toJSON(),rail:p.dataset.rail}})()`);
  assert(terminal.text.includes('ARGC=1'),'absolute path is passed as exactly one argument');
  assert(!terminal.rail && Math.abs(terminal.box.x-Math.max(6,Math.min(launchPoint.x,1440-terminal.box.width-6)))<2 && Math.abs(terminal.box.y-Math.max(6,Math.min(launchPoint.y,1000-terminal.box.height-6)))<2,'command opens a floating terminal at the click, clamped inside the viewport');
  assert(!await cdp.evaluate('!!document.querySelector("#file-command")'),'submitting dismisses the prompt');
  await cdp.evaluate("document.querySelector('[id^=\"pane-\"] .tab-close').click()");
  const markdownPoint = await click(await target('sample.md'));
  await waitFor(()=>cdp.evaluate('!!document.querySelector("#file-command input")'));
  await cdp.send('Input.insertText',{text:'vz'});
  await cdp.send('Input.dispatchKeyEvent',{type:'keyDown',key:'Enter',code:'Enter',text:'\r'});
  await waitFor(()=>cdp.evaluate('document.querySelector(".markdown-document h1")?.textContent === "Reading test"'));
  await cdp.evaluate('window.readingHeading=document.querySelector(".markdown-document h1")');
  await sleep(2500);
  assert(await cdp.evaluate('document.querySelector(".markdown-status").textContent==="" && document.querySelector(".markdown-document h1")===window.readingHeading'),'unchanged refreshes preserve the rendered document without a parser error');
  const reader = await cdp.evaluate(`(()=>{const p=document.querySelector('.markdown-pane');return {id:p.id,box:p.getBoundingClientRect().toJSON(),rail:p.dataset.rail}})()`);
  assert(!reader.rail && Math.abs(reader.box.x-Math.max(6,Math.min(markdownPoint.x,1440-reader.box.width-6)))<2,'vz turns the file command pane into a floating Markdown reader in place');
  assert(await cdp.evaluate('document.querySelector(".markdown-document strong").textContent==="bold" && !window.markdownUnsafe && !document.querySelector(".markdown-document script, .markdown-document a[href^=javascript]")'),'Markdown formatting renders without executing embedded HTML or unsafe links');
  assert(await cdp.evaluate(`(()=>{const v=document.querySelector('.markdown-viewport');v.scrollTop=13;return v.scrollTop===13 && v.scrollHeight>v.clientHeight})()`),'reader scrolls by pixels through browser content');
  assert(await cdp.evaluate(`(()=>{const wrapper=document.querySelector('.markdown-table');return wrapper.scrollWidth<=wrapper.clientWidth+1})()`),'automatic table columns fit the available reading width');
  await cdp.evaluate(`document.querySelector('.markdown-pane').style.width='400px'`);
  assert(await cdp.evaluate(`(()=>{const v=document.querySelector('.markdown-viewport');return v.scrollWidth<=v.clientWidth+1})()`),'Markdown reflows to a narrow pane without horizontal paragraph overflow');
  assert(await cdp.evaluate(`(()=>{const wrapper=document.querySelector('.markdown-table');const table=wrapper.querySelector('table');return wrapper.scrollWidth>wrapper.clientWidth && getComputedStyle(table).overflowWrap==='normal' && getComputedStyle(table.querySelector('td')).verticalAlign==='top'})()`),'wide tables scroll independently and preserve whole words');
  await cdp.evaluate("document.querySelector('.markdown-column-resize').scrollIntoView({block:'center',inline:'center'})");
  const column = await cdp.evaluate("(()=>{const h=document.querySelector('.markdown-column-resize');return {handle:h.getBoundingClientRect().toJSON(),width:h.parentElement.getBoundingClientRect().width}})()");
  const resizeX=column.handle.x+column.handle.width/2, resizeY=column.handle.y+column.handle.height/2;
  await cdp.send('Input.dispatchMouseEvent',{type:'mousePressed',x:resizeX,y:resizeY,button:'left',buttons:1,clickCount:1});
  await cdp.send('Input.dispatchMouseEvent',{type:'mouseMoved',x:resizeX+70,y:resizeY,button:'left',buttons:1});
  await cdp.send('Input.dispatchMouseEvent',{type:'mouseReleased',x:resizeX+70,y:resizeY,button:'left',buttons:0,clickCount:1});
  const resizedWidth=await cdp.evaluate("document.querySelector('.markdown-document th').getBoundingClientRect().width");
  assert(Math.abs(resizedWidth-column.width-70)<2,'dragging a table boundary changes its column width');
  await cdp.send('Page.reload');
  await waitFor(()=>cdp.evaluate('!!document.querySelector(".markdown-column-resize")'));
  assert(await cdp.evaluate(`Math.abs(document.querySelector('.markdown-document th').getBoundingClientRect().width-${resizedWidth})<2`),'column width survives browser reload');
  await cdp.evaluate("document.querySelector('.markdown-column-resize').dispatchEvent(new MouseEvent('dblclick',{bubbles:true}))");
  assert(await cdp.evaluate("!document.querySelector('.markdown-document table').classList.contains('sized-columns')"),'double-click restores automatic column sizing');
  await writeFile(join(root,'project','sample.md'),'# Updated reading test\n\nUpdated on disk.');
  await waitFor(()=>cdp.evaluate('document.querySelector(".markdown-document h1")?.textContent === "Updated reading test"'));
  assert(true,'reader refreshes after file edits');
  await cdp.send('Page.reload');
  await waitFor(()=>cdp.evaluate('!!document.querySelector(".markdown-document h1")'));
  assert(await cdp.evaluate(`document.querySelector('.markdown-pane').id===${JSON.stringify(reader.id)}`),'browser reload recovers the Markdown reader in its original pane');
  await cdp.send('Page.navigate',{url:'about:blank'});
  const stopped = new Promise(resolve=>server.once('exit',resolve));
  server.kill('SIGTERM');
  await stopped;
  await rm(join(root,'url'));
  startServer();
  const recoveredUrl = await waitFor(()=>readFile(join(root,'url'),'utf8'));
  await cdp.send('Page.navigate',{url:recoveredUrl});
  await waitFor(()=>cdp.evaluate('document.querySelector(".markdown-document h1")?.textContent === "Updated reading test"'));
  assert(await cdp.evaluate(`document.querySelector('.markdown-pane').id===${JSON.stringify(reader.id)}`),'server restart recovers the Markdown file association');
  assert(!failures.length,'no browser exceptions');
  console.log(JSON.stringify(checks,null,2));
  const shot=await cdp.send('Page.captureScreenshot',{format:'png'});
  await writeFile(output,Buffer.from(shot.data,'base64'));
} finally {
  socket?.close();
  if(chrome){chrome.kill('SIGTERM');await sleep(500);}
  if(server){server.kill('SIGINT');await sleep(500);}
  await rm(root,{recursive:true,force:true,maxRetries:5,retryDelay:200});
}
