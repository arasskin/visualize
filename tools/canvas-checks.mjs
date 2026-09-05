import { spawn } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, readFile, rm, cp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const output = resolve(process.argv[2] || '/tmp/visualize-canvas.png');
const root = await mkdtemp(join(tmpdir(), 'vz-canvas-'));
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
  await cdp.send('Page.enable');
  await cdp.send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false });
  await cdp.send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'light' }] });
  await cdp.send('Page.navigate', { url: url + '/?trace=1' });
  await waitFor(() => cdp.evaluate('!!window.__latency && !!document.querySelector("#harness textarea")'));
  await cdp.evaluate('document.querySelectorAll(".panel").forEach(p => p.style.display = "none")');
  await sleep(1500);




  await cdp.send('Runtime.enable');
  const failures = [];
  socket.addEventListener('message', e => { const m=JSON.parse(e.data); if(m.method==='Runtime.exceptionThrown') failures.push(m.params); });
  await sleep(1000);
  const checks = await cdp.evaluate(`(async () => {
    const g = await import('/graph.js');
    const f = await import('/find.js');
    const h = await import('/hover.js');
    const passed = [];
    const check = (ok,name) => { if(!ok) throw new Error(name); passed.push(name); };
    const settle = () => new Promise(r=>setTimeout(r,250));
    const near = (a,b) => Math.abs(a-b)<.2;
    await document.fonts.ready;
    g.fit(); await settle();
    let d=g.drawing();
    check(d.canvas.width>0 && d.canvas.height>0,'canvas has backing pixels');
    check(getComputedStyle(d.svg).visibility==='hidden','SVG is only a hidden geometry source');
    const node=d.svg.querySelector('g.node');
    const before=g.screenBounds(node);
    const oldSVG=d.svg.outerHTML;
    let textDraws=0, geometryReads=0;
    const fillText=CanvasRenderingContext2D.prototype.fillText;
    const getBBox=SVGGraphicsElement.prototype.getBBox;
    CanvasRenderingContext2D.prototype.fillText=function(...args){textDraws++;return fillText.apply(this,args);};
    SVGGraphicsElement.prototype.getBBox=function(...args){geometryReads++;return getBBox.apply(this,args);};
    g.panBy(50,30);
    const after=g.screenBounds(node);
    check(near(after.left,before.left+50)&&near(after.top,before.top+30),'canvas coordinate model pans in screen pixels');
    g.zoomAt(1.5,720,500);g.repaint();
    const zoomed=g.screenBounds(node);
    check(near(zoomed.left,720+(after.left-720)*1.5),'zoom preserves pointer anchor');
    check(d.svg.outerHTML===oldSVG,'pan and zoom do not mutate SVG');
    CanvasRenderingContext2D.prototype.fillText=fillText;
    SVGGraphicsElement.prototype.getBBox=getBBox;
    check(textDraws===0,'cached gestures do not redraw labels');
    check(geometryReads===0,'cached gestures do not query SVG geometry');
    await settle();
    const pixels=d.canvas.getContext('2d').getImageData(0,0,d.canvas.width,d.canvas.height).data;
    let ink=0;
    for(let i=0;i<pixels.length;i+=4)if(pixels[i+3]>100 && pixels[i]+pixels[i+1]+pixels[i+2]<650)ink++;
    check(ink>100,'canvas contains visible graph pixels');
    const input=document.getElementById('find-input');
    input.value='graph';input.dispatchEvent(new Event('input',{bubbles:true}));
    await settle();
    const arrow=d.svg.querySelector('#find-arrow');
    check(!!arrow,'search creates arrow geometry');
    const a=g.screenBounds(arrow);
    g.zoomAt(1.2,720,500);g.repaint();await settle();
    const b=g.screenBounds(arrow);
    check(near(a.width,b.width)&&near(a.height,b.height),'search arrow retains screen size after zoom');
    const edge=d.svg.querySelector('g.edge');
    const line=edge.querySelector('path');
    const pt=line.getPointAtLength(line.getTotalLength()/2).matrixTransform(line.getCTM());
    const v=g.view();
    check(!!g.edgeAt(v.tx+pt.x*v.scale,v.ty+pt.y*v.scale),'edge hit testing uses canvas coordinates');
    g.hoverGraphEdge(edge);g.repaint();g.hoverGraphEdge(null);
    const fresh=new DOMParser().parseFromString(await(await fetch('/')).text(),'text/html').querySelector('#graph svg');
    g.pane.replaceChildren(document.importNode(fresh,true));h.keepEdgeLabel();h.wireEdges();g.hatchFolded();f.forgetUnit();f.redrawFind();g.fit();await settle();
    check(document.querySelectorAll('#graph canvas').length===1,'redraw replaces the canvas');
    check(g.drawing()!==d,'redraw replaces cached geometry');
    return passed;
  })()`);
  console.log(JSON.stringify(checks,null,2));
  await cdp.send('Emulation.setDeviceMetricsOverride',{width:1000,height:700,deviceScaleFactor:2,mobile:false});
  await sleep(500);
  const retina=await cdp.evaluate('({width:document.querySelector("#graph canvas").width,height:document.querySelector("#graph canvas").height})');
  if(retina.width!==2000 || retina.height!==1400)throw new Error('Incorrect Retina backing size');
  await cdp.send('Emulation.setEmulatedMedia',{features:[{name:'prefers-color-scheme',value:'dark'}]});
  await sleep(300);
  const dark=await cdp.evaluate('getComputedStyle(document.querySelector("#graph canvas")).filter');
  if(!dark.includes('invert'))throw new Error('Dark palette was not applied');
  await cdp.send('Emulation.setEmulatedMedia',{features:[{name:'prefers-color-scheme',value:'light'}]});
  await sleep(300);
  await cdp.send('Input.dispatchMouseEvent',{type:'mousePressed',x:600,y:450,button:'left',buttons:1,clickCount:1});
  await cdp.send('Input.dispatchMouseEvent',{type:'mouseMoved',x:650,y:480,button:'left',buttons:1});
  await sleep(200);
  const dragging=await cdp.evaluate('(async()=>{const g=await import("/graph.js");return g.navigating&&!!g.dragging;})()');
  if(!dragging)throw new Error('Native canvas drag failed');
  await cdp.send('Input.dispatchMouseEvent',{type:'mouseReleased',x:650,y:480,button:'left',buttons:0,clickCount:1});
  const released=await cdp.evaluate('(async()=>{const g=await import("/graph.js");return !g.navigating&&!g.dragging;})()');
  if(!released)throw new Error('Native canvas drag did not end');
  console.log('Retina rendering, theme changes, and native canvas dragging passed.');
  const shot=await cdp.send('Page.captureScreenshot',{format:'png'});
  await writeFile(output,Buffer.from(shot.data,'base64'));
  if(failures.length)throw new Error(JSON.stringify(failures));
} finally {
  socket?.close();
  if(chrome){chrome.kill('SIGTERM');await sleep(500);}
  if(server){server.kill('SIGINT');await sleep(500);}
  await rm(root,{recursive:true,force:true,maxRetries:5,retryDelay:200});
}
