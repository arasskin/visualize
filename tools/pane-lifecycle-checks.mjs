import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp, mkdir, readFile, writeFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve, join} from 'node:path';
import {browser, waitFor, stopProcess} from './browser.mjs';

const repo = resolve(import.meta.dirname, '..');
const engine = process.argv[2] || 'chrome';
const cycles = Number(process.env.LIFECYCLE_CYCLES || 6);
assert(['chrome', 'firefox'].includes(engine));
const root = await mkdtemp(join(tmpdir(), 'vz-lifecycle-'));
const project = join(root, 'project'), logs = [], checks = [];
let server, page;
const quote = text => "'" + text.replaceAll("'", "'\\''") + "'";
try {
  await mkdir(project); await mkdir(join(root, 'bin'));
  await writeFile(join(project, 'visualize_config'), 'box notes\n');
  await writeFile(join(project, 'notes.md'), '# Notes\n\nLifecycle document.\n');
  await writeFile(join(root, 'bin', 'open'), '#!/bin/sh\nprintf "%s" "$1" > "$VZ_TEST_URL"\n', {mode: 0o755});
  const startServer = () => {
    server = spawn(join(repo, 'external-src/janet/janet'), [join(repo, 'src.server/core.janet'), project,
      '--no-dev', '--command', 'exec /bin/cat'], {cwd: repo, stdio: ['ignore', 'pipe', 'pipe'],
      env: {...process.env, PATH: join(root, 'bin') + ':' + process.env.PATH,
        VZ_TEST_URL: join(root, 'url'), VISUALIZE_ERROR_LOG_DIR: join(root, 'errors')}});
    server.stdout.on('data', data => logs.push(String(data)));
    server.stderr.on('data', data => logs.push(String(data)));
  };
  startServer();
  const url = await waitFor(() => readFile(join(root, 'url'), 'utf8'));
  page = await browser(engine, root);
  await page.viewport(1280, 900); await page.navigate(url);
  const ready = async () => {
    await waitFor(() => page.evaluate('!!document.querySelector("#harness textarea") && !!document.querySelector("#config .config-command")'));
    await page.evaluate(`(async()=>{
      window.panes=(await import('/app.js')).workspace;window.transport=await import('/shared/transport.js');
      window.sent=[];window.replies=[];const send=WebSocket.prototype.send;const observed=new WeakSet();
      WebSocket.prototype.send=function(text){
        if(!observed.has(this)){observed.add(this);this.addEventListener('message',event=>{
          const message=JSON.parse(typeof event.data==='string'?event.data:new TextDecoder().decode(event.data));
          if(message.type==='reply')replies.push(message);
        })}sent.push(JSON.parse(text));return send.call(this,text)};
    })()`);
  };
  await ready();
  const check = async (expression, name) => {
    assert(await page.evaluate(`(async()=>(${expression}))()`), name);
    assert.deepEqual(page.errors, [], 'browser errors');
    checks.push(name); console.log('PASS', engine, name);
  };
  const settle = () => page.evaluate('new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))');
  const click = async expression => {
    const point = await page.evaluate(`(()=>{const r=(${expression}).getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()`);
    await page.drag(point.x, point.y); await settle();
  };
  await page.evaluate('window.subject=panes.openTerminal();subject.root.style.width="560px";subject.root.style.height="360px";subject.resized()');
  const id = await page.evaluate('subject.root.id.slice(5)');
  await waitFor(() => page.evaluate(`transport.request(${JSON.stringify(id)},'capture').then(s=>s.running)`));
  const fixture = `exec ${quote(join(repo, 'external-src/janet/janet'))} ${quote(join(repo, 'tools/fixtures/pane-terminal.janet'))}\r`;
  await page.evaluate(`subject.type(${JSON.stringify(fixture)})`);
  const healthy = () => waitFor(() => page.evaluate(`(async()=>{
    const state=await transport.request(${JSON.stringify(id)},'capture');
    const screen=subject.root.querySelector('.screen');
    return state.running && screen.textContent.includes('BOTTOM-') && !subject.root.querySelector('.state').textContent;
  })()`));
  await healthy();
  for (let cycle = 0; cycle < cycles; cycle++) {
    const side = cycle % 2 ? 'bottom' : 'top';
    await page.evaluate(`panes.addToRail(subject,0,${JSON.stringify(side)});panes.selectPane(subject.root);panes.packRailNow()`);
    await settle();
    await click('subject.bar');
    await check('subject.shut', `${cycle}: collapse ${side}`);
    const beforeWidth = await page.evaluate('subject.root.offsetWidth');
    const grip = await page.evaluate('subject.grip.getBoundingClientRect().toJSON()');
    await page.drag(grip.x + grip.width / 2, grip.y + grip.height / 2, cycle % 2 ? -30 : 30, 0);
    await check(`subject.root.offsetWidth===${beforeWidth + (cycle % 2 ? -30 : 30)}`, `${cycle}: collapsed width resizes`);
    await click('subject.bar'); await healthy();
    await check(`!subject.shut && subject.root.offsetHeight===360 && subject.body.clientHeight>250
      && subject.root.querySelectorAll('textarea').length===1`, `${cycle}: reopening keeps dimensions and one terminal`);
    const corner = await page.evaluate('subject.grip.getBoundingClientRect().toJSON()');
    await page.drag(corner.x + 4, corner.y + 4, 20, side === 'bottom' ? -20 : 20);
    await check('subject.root.offsetHeight===380', `${cycle}: corner resizes vertically`);
    await page.evaluate('subject.root.style.height="360px";subject.resized()');
    await healthy();
  }
  await page.evaluate('subject.toggle();panes.get("config").open();panes.get("config").toggle()');
  await waitFor(async () => /placement bottom \d+ \d+ 360/.test(await readFile(join(project, 'visualize_config'), 'utf8')));
  await check('subject.shut', 'collapsed pane persists its expanded height');
  const generation = await page.evaluate(`transport.request(${JSON.stringify(id)},'capture').then(s=>s.generation)`);
  await page.navigate(url); await ready();
  await page.evaluate(`window.subject=panes.all.find(p=>p.root.id===${JSON.stringify('pane-' + id)});subject.open()`);
  await healthy();
  await check(`subject.root.offsetHeight===360 && subject.root.dataset.rail==='bottom'
    && (await transport.request(${JSON.stringify(id)},'capture')).generation===${generation}`, 'reload restores dimensions, rail, and the running session');
  for (let cycle = 0; cycle < cycles; cycle++) {
    await page.evaluate(`(async()=>{
      window.retired=panes.openTerminal();window.retiredId=retired.root.id.slice(5);
      if (${cycle} % 2) await retired.boot();
      retired.root.querySelector('.tab-close').click();await retired.boot();
      await new Promise(resolve=>setTimeout(resolve,100));
    })()`);
    await waitFor(() => page.evaluate(`transport.request(retiredId,'capture').then(s=>s.absent)`));
    await page.evaluate(`sent.length=0;window.dispatchEvent(new Event('focus'));window.dispatchEvent(new Event('online'));
      window.dispatchEvent(new Event('resize'));retired.open();`);
    await page.evaluate('new Promise(resolve=>setTimeout(resolve,200))');
    await check(`!retired.root.isConnected && !sent.some(m=>m.pane===retiredId)
      && !document.getElementById('pane-'+retiredId)`, `${cycle}: close during startup cannot resurrect a pane`);
  }
  await page.evaluate(`window.doc=panes.openFileTerminal({name:'notes.md',file:'notes.md'},'vz',{x:120,y:180})`);
  await waitFor(() => page.evaluate('doc.body.textContent.includes("Lifecycle document")'));
  await check('doc.body.textContent.includes("Lifecycle document")', 'document uses the pane lifecycle');
  await page.evaluate('doc.root.style.width="620px";doc.root.style.height="420px";doc.resized();doc.place(120,180)');
  const docId = await page.evaluate('doc.root.id.slice(5)');
  await waitFor(async () => (await readFile(join(project, 'visualize_config'), 'utf8')).includes('floating 120 180 620 420'));
  await page.navigate(url); await ready();
  await waitFor(() => page.evaluate(`!!document.querySelector('#pane-${docId} .markdown-document')`));
  await check(`(()=>{const p=document.getElementById('pane-${docId}');return p.offsetLeft===120 && p.offsetTop===180
    && p.offsetWidth===620 && p.offsetHeight===420})()`, 'floating document restores coordinates and dimensions');
  await stopProcess(server);
  await rm(join(root, 'url')); startServer();
  assert.equal(await waitFor(() => readFile(join(root, 'url'), 'utf8')), url);
  await page.evaluate(`window.subject=panes.all.find(p=>p.root.id==='pane-${id}');subject.open()`);
  await healthy();
  await check(`(await transport.request('${id}','capture')).generation===${generation}`, 'server restart reconnects the existing terminal');
  await click(`document.querySelector('#pane-${docId} .tab-close')`);
  await waitFor(() => page.evaluate(`!document.getElementById('pane-${docId}')`));
  await check('true', 'document closes after server recovery');
  await page.evaluate(`(()=>{
    const observer=new MutationObserver(()=>{});observer.observe(document.body,{childList:true,subtree:true});
    window.direct=panes.createPane({file:window.CONFIG_FILE,remote:false});
    window.emulatorCreated=observer.takeRecords().some(record=>[...record.addedNodes].some(node=>node.nodeType===1&&node.matches('.screen,.term-grid,textarea')));
    observer.disconnect();panes.addToRail(direct,0,'bottom');panes.selectPane(direct.root);direct.open();
  })()`);
  await waitFor(()=>page.evaluate('!!direct.body.querySelector(".config-diagram svg")'));
  await check('!emulatorCreated && direct.body.clientHeight>100 && direct.root.querySelectorAll(".side-grip").length===1', 'direct document creation uses the common frame without a terminal');
  await click('direct.root.querySelector(".tab-close")');
  await check('!panes.all.includes(direct) && !direct.root.isConnected', 'a directly created document closes through the common lifecycle');
  await page.evaluate(`(async()=>{
    await Promise.all(panes.all.map(panel=>panes.closePanel(panel)));
    for(const type of ['keydown','keyup']) document.dispatchEvent(new KeyboardEvent(type,{key:'Alt',bubbles:true}));
  })()`);
  await check('panes.all.length===0 && panes.pickedPanel()===null', 'an empty workspace has no special pane fallback and accepts Alt');
  console.log(`Passed ${checks.length} ${engine} lifecycle checks.`);
} catch (error) {
  if (page) console.error(await page.evaluate(`JSON.stringify([...document.querySelectorAll('.panel')].map(p=>({id:p.id,
    box:p.getBoundingClientRect().toJSON(),classes:p.className,text:p.innerText.slice(-1200)})))`).catch(()=>''));
  if (page) console.error(await page.evaluate(`(async()=>window.doc && ({connected:doc.root.isConnected,
    state:await transport.request(doc.root.id.slice(5),'screen',{at:0}),messages:sent.filter(m=>m.pane===doc.root.id.slice(5) && m.op!=='resize')
      .map(m=>({...m,reply:replies.find(r=>r.id===m.id)}))}))()`).then(value=>JSON.stringify(value)).catch(()=>''));
  console.error(logs.join('').slice(-6000));
  throw error;
} finally {
  await page?.close();
  await stopProcess(server, 'SIGINT');
  await rm(root, {recursive: true, force: true, maxRetries: 5, retryDelay: 200});
}
