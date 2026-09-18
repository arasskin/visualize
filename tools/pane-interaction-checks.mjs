import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp, mkdir, readFile, writeFile, rm, cp} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve, join} from 'node:path';
import {browser, waitFor, stopProcess} from './browser.mjs';

const repo = resolve(import.meta.dirname, '..');
const engine = process.argv[2] || 'chrome';
assert(['chrome', 'firefox'].includes(engine));
const root = await mkdtemp(join(tmpdir(), 'vz-interactions-'));
const project = join(root, 'project'), logs = [], checks = [];
let server, page;
try {
  await mkdir(project); await mkdir(join(root, 'bin'));
  await writeFile(join(project, 'visualize_config'), 'box notes\n');
  await writeFile(join(project, 'notes.md'), '# Notes\n\nLifecycle document.\n');
  await writeFile(join(root, 'bin', 'open'), '#!/bin/sh\nprintf "%s" "$1" > "$VZ_TEST_URL"\n', {mode: 0o755});
  const startServer = () => {
    server = spawn(join(repo, 'external-src/janet/janet'), [join(repo, 'src.server/core.janet'), project,
      '--no-dev', '--command', 'exec /bin/cat'], {cwd: repo, stdio: ['ignore', 'pipe', 'pipe'],
      env: {...process.env, PATH: join(root, 'bin') + ':' + process.env.PATH,
        VISUALIZE_MAIN_HARNESS_COMMAND: 'exec /bin/cat', VZ_TEST_URL: join(root, 'url'), VISUALIZE_ERROR_LOG_DIR: join(root, 'errors')}});
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
      WebSocket.prototype.send=function(text){window.wire=this;
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

  await page.evaluate(`window.fadePane=panes.get('config');panes.selectPane(panes.get('harness').root);fadePane.setLabel('!note');window.wasShut=fadePane.shut`);
  await check(`getComputedStyle(fadePane.root).opacity==='0.6'`, 'subtitle punctuation does not control opacity');
  const togglePoint = await page.evaluate(`(()=>{const r=fadePane.bar.querySelector('.tab-fade').getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()`);
  await page.drag(togglePoint.x,togglePoint.y);
  await page.evaluate(`panes.selectPane(panes.get('harness').root)`);
  await check(`getComputedStyle(fadePane.root).opacity==='1' && fadePane.shut===wasShut && fadePane.bar.querySelector('.tab-fade').getAttribute('aria-pressed')==='true'`, 'opacity toggle keeps an unfocused pane opaque without opening or closing it');
  await waitFor(async () => (await readFile(join(project,'visualize_config'),'utf8')).includes('unfaded true'));
  await page.navigate(url);await ready();
  await page.evaluate(`window.fadePane=panes.get('config');panes.selectPane(panes.get('harness').root)`);
  await check(`getComputedStyle(fadePane.root).opacity==='1' && fadePane.bar.querySelector('.tab-fade').getAttribute('aria-pressed')==='true'`, 'opacity toggle is restored after reloading');
  await page.evaluate(`fadePane.bar.querySelector('.tab-fade').click()`);
  await check(`getComputedStyle(fadePane.root).opacity==='0.6' && fadePane.bar.querySelector('.tab-fade').getAttribute('aria-pressed')==='false'`, 'disabling the toggle restores fading');
  await waitFor(async () => !(await readFile(join(project,'visualize_config'),'utf8')).includes('unfaded true'));

  for (const id of ['compose', 'find']) {
    await page.evaluate(`document.getElementById('${id}').classList.remove('shut');document.activeElement.blur()`);
    const point = await page.evaluate(`(()=>{const box=document.getElementById('${id}-box').getBoundingClientRect();return {x:box.left+3,y:box.top+3}})()`);
    await page.drag(point.x, point.y);
    await check(`document.activeElement.id==='${id}-input'`, `${id} field border and padding focus its input`);
    await page.evaluate(`document.getElementById('${id}').classList.add('shut')`);
  }

  await page.evaluate(`window.config=panes.get('config');config.open();panes.selectPane(config.root);config.focus()`);
  await waitFor(() => page.evaluate('!!config.body.querySelector("svg .graph-camera")'));
  await settle();
  await page.evaluate(`window.configSvg=config.body.querySelector('svg');window.configFlashes=0;window.configFocuses=0;
    window.observer=new MutationObserver(records=>{
      if(records.some(r=>[...r.addedNodes].some(n=>n.nodeName==='svg'))) configFlashes++;
    });observer.observe(config.body,{childList:true,subtree:true});
    config.root.addEventListener('focusin',()=>configFocuses++);
    window.doc=panes.openFileTerminal({file:'notes.md',name:'notes.md'},'vz',{x:420,y:180});`);
  await waitFor(() => page.evaluate('!!doc.body.querySelector(".markdown-document h1")'));
  await check('config.body.querySelector("svg")===configSvg && !configFlashes && !configFocuses', 'vz Markdown leaves the config editor intact and unfocused');
  await check('!doc.body.querySelector(".config-document") && doc.body.textContent.includes("Lifecycle document")', 'vz opens the requested document in its own pane');
  await page.evaluate('panes.closePanel(doc);window.subject=panes.get("harness");panes.removeFromRail(subject);subject.root.style.width="560px";subject.root.style.height="360px";subject.place(650,100);subject.open();panes.selectPane(subject.root);subject.type("Selectable terminal text\\r")');
  await waitFor(() => page.evaluate('subject.body.textContent.includes("Selectable terminal text")'));
  for (const padding of [false, true]) {
    await page.evaluate(`panes.selectPane(config.root);config.focus();
      const range=document.createRange();range.selectNodeContents(subject.body.querySelector('.term-row'));
      getSelection().removeAllRanges();getSelection().addRange(range);`);
    const point = await page.evaluate(`(()=>{const body=subject.body.getBoundingClientRect(), screen=subject.body.querySelector('.screen').getBoundingClientRect();
      return {x:${padding} ? body.right-2 : screen.right-20,y:${padding} ? screen.top+screen.height/2 : screen.bottom-20}})()`);
    await page.drag(point.x, point.y); await settle();
    await check('panes.pickedPanel()===subject && document.activeElement===subject.body.querySelector("textarea")', padding ? 'clicking terminal padding restores keyboard focus' : 'clicking blank terminal space restores focus despite an old selection');
  }
  await page.evaluate(`window.before=subject.root.getBoundingClientRect().toJSON();panes.selectPane(config.root);panes.packRailNow();panes.selectPane(subject.root);panes.packRailNow()`);
  await check('subject.root.offsetLeft===before.x && subject.root.offsetTop===before.y', 'selecting a floating pane preserves its position');
  await page.evaluate(`panes.addToRail(config,undefined,'bottom');
    window.railTests=[0,1,2].map(i=>{const p=panes.createPane({id:'rail-test-'+i,file:window.CONFIG_FILE,remote:false,width:'470px'});panes.addToRail(p,undefined,'top');return p});
    panes.selectPane(railTests[1].root);panes.packRailNow();window.railBefore=railTests.map(p=>p.root.offsetLeft);
    panes.selectPane(config.root);panes.packRailNow();panes.selectPane(subject.root);panes.packRailNow();`);
  await check('railTests.every((p,i)=>p.root.offsetLeft===railBefore[i])', 'selecting another rail or floating pane leaves the previous rail still');
  await page.evaluate('panes.selectPane(railTests[2].root);panes.selectPane(subject.root);panes.packRailNow()');
  await check('railTests.every((p,i)=>p.root.offsetLeft===railBefore[i])', 'changing selection before the next frame cancels the old reveal');
  await page.evaluate('panes.selectPane(railTests[2].root);panes.packRailNow()');
  await check('railTests[2].root.getBoundingClientRect().right<=innerWidth-5 && railTests[2].root.offsetLeft>=5', 'a partially hidden selected rail pane is revealed');
  await page.evaluate(`railTests[2].root.style.width='1600px';panes.selectPane(railTests[1].root);panes.packRailNow();
    panes.selectPane(railTests[2].root);panes.packRailNow();window.wideLeft=railTests[2].root.offsetLeft;
    for(let i=0;i<8;i++)panes.packRailNow();`);
  await check('railTests[2].root.offsetLeft===wideLeft', 'an oversized selected pane does not bounce between rail edges');
  const resizeConfig = async (dx, dy) => {
    const grip = await page.evaluate('config.grip.getBoundingClientRect().toJSON()');
    await page.drag(grip.x + 5, grip.y + 5, dx, dy);
    await settle();
  };
  for (const side of ['bottom', 'top']) {
    const opposite = side === 'bottom' ? 'top' : 'bottom';
    const direction = side === 'bottom' ? -1 : 1;
    await page.evaluate(`panes.addToRail(config,0,'${side}');config.open();
      config.root.style.width='360px';config.root.style.height=(innerHeight-70)+'px';
      for(const p of railTests){if(!p.shut)p.toggle();p.root.style.width='240px';panes.addToRail(p,undefined,'${opposite}')}
      panes.selectPane(config.root);panes.packRailNow()`);
    await settle();
    await resizeConfig(0, direction * 40);
    await check(`Math.abs(config.root.getBoundingClientRect().height-innerHeight)<1 &&
      Math.abs(railTests[0].root.getBoundingClientRect().left-config.root.getBoundingClientRect().right-6)<1`, `${side} snap reserves its width on the opposite rail`);
    await resizeConfig(80, 0);
    await check('Math.abs(railTests[0].root.getBoundingClientRect().left-config.root.getBoundingClientRect().right-6)<1', `${side} spacer follows horizontal resizing`);
    await page.evaluate('config.toggle();panes.packRailNow()');
    await check('railTests[0].root.offsetLeft===7', `${side} collapse releases opposite rail space`);
    await page.evaluate('config.open();panes.packRailNow()');
    await check('Math.abs(railTests[0].root.getBoundingClientRect().left-config.root.getBoundingClientRect().right-6)<1', `${side} reopening restores opposite rail space`);
    await resizeConfig(0, -direction * 100);
    await check('railTests[0].root.offsetLeft===7', `${side} shrinking away from the edge releases the spacer`);
    await resizeConfig(0, direction * 70);
    await page.evaluate(`panes.addToRail(railTests[0],0,'${side}');panes.packRailNow()`);
    await check(`railTests[1].root.offsetLeft===7 &&
      Math.abs(railTests[2].root.getBoundingClientRect().left-config.root.getBoundingClientRect().right-6)<1`, `${side} interior spacer allows tabs before and after it`);
    await page.evaluate(`railTests[2].open();railTests[2].root.style.height=innerHeight+'px';panes.packRailNow();
      window.spacerPositions=[config,...railTests].map(p=>p.root.offsetLeft);
      for(let i=0;i<20;i++)panes.packRailNow()`);
    await check(`JSON.stringify([config,...railTests].map(p=>p.root.offsetLeft))===JSON.stringify(spacerPositions) &&
      (()=>{const a=config.root.getBoundingClientRect(),b=railTests[2].root.getBoundingClientRect();
        return a.right+5<=b.left || b.right+5<=a.left})()`, `${side} multiple spanning panes pack without overlap or oscillation`);
    await page.evaluate(`railTests[0].root.style.width='1000px';panes.selectPane(railTests[0].root);panes.packRailNow();
      window.scrollBefore=[config,...railTests].map(p=>p.root.offsetLeft);
      window.dispatchEvent(new WheelEvent('wheel',{clientY:1,deltaX:120,cancelable:true}));panes.packRailNow()`);
    await check('[config,...railTests].every((p,i)=>p.root.offsetLeft===scrollBefore[i]-120)', `${side} spanning panes keep both rails aligned while scrolling`);
    await page.evaluate('panes.selectPane(config.root);panes.packRailNow()');
    await check('config.root.getBoundingClientRect().left>=7 && config.root.getBoundingClientRect().right<=innerWidth-6', `${side} selecting a spanning pane reveals it on both rails`);
    await page.evaluate(`railTests[0].root.style.width='240px';railTests[2].toggle();panes.packRailNow()`);
  }
  const spanningBar = await page.evaluate('config.bar.getBoundingClientRect().toJSON()');
  await page.drag(spanningBar.x + 10, spanningBar.y + 10, 40, 150); await settle();
  await check('!panes.onRail(config) && railTests[1].root.offsetLeft===7', 'undocking a spanning pane releases its spacer');
  await page.evaluate(`config.root.style.height='350px';panes.addToRail(config,0,'top');
    railTests[2].open();railTests[2].root.style.height=innerHeight+'px';panes.packRailNow()`);
  await check('config.root.offsetLeft>7', 'opposite spanning pane reserves space before closing');
  await page.evaluate('panes.closePanel(railTests[2]);panes.packRailNow()');
  await check('config.root.offsetLeft===7', 'closing a spanning pane releases its spacer');
  await page.evaluate('for(const p of railTests)panes.closePanel(p);panes.selectPane(subject.root);subject.focus()');
  await waitFor(() => page.evaluate('wire?.readyState===WebSocket.OPEN && !subject.root.querySelector(".state").textContent'));
  await page.evaluate(`window.originalSend=WebSocket.prototype.send;window.originalConsoleError=console.error;
    console.error=function(label,entry,...rest){
      if(label==='Terminal error' && ['synthetic input failure','late old input failure','terminal disconnected; input was not sent','synthetic PTY resize failure'].includes(entry?.message))return;
      return originalConsoleError.call(this,label,entry,...rest)
    };
    WebSocket.prototype.send=function(text){const msg=JSON.parse(text);
      if(msg.op==='input' && msg.body.text==='FAIL'){throw new Error('synthetic input failure')}
      if(msg.op==='input' && msg.body.text==='OLD'){window.oldRequest=msg;return}
      return originalSend.call(this,text)};
    subject.type('FAIL');`);
  await waitFor(() => page.evaluate('subject.root.querySelector(".state").textContent==="synthetic input failure"'));
  await page.evaluate('subject.type("RECOVERED\\r")');
  await waitFor(() => page.evaluate('subject.body.textContent.includes("RECOVERED") && !subject.root.querySelector(".state").textContent'));
  checks.push('successful input clears an earlier input failure');
  await page.evaluate('subject.type("OLD");subject.type("NEW\\r")');
  await waitFor(() => page.evaluate('oldRequest && subject.body.textContent.includes("NEW")'));
  await page.evaluate('wire.onmessage({data:JSON.stringify({type:"reply",id:oldRequest.id,body:{error:"late old input failure"}})})');
  await settle();
  assert.equal(await page.evaluate('subject.root.querySelector(".state").textContent'), '', 'an old failure cannot overwrite a newer successful input');
  checks.push('out-of-order input replies cannot revive stale errors');
  await page.evaluate('window.beforeDisconnect=sent.length;wire.close();subject.type("UNSENT_MARKER");');
  await waitFor(() => page.evaluate('wire.readyState===WebSocket.OPEN && !subject.root.querySelector(".state").textContent'));
  assert(await page.evaluate('!sent.slice(beforeDisconnect).some(m=>m.op==="input" && m.body.text==="UNSENT_MARKER")'), 'disconnected input is not replayed');
  assert(!await page.evaluate('transport.request("harness","capture").then(s=>s.text.includes("UNSENT_MARKER"))'));
  checks.push('reconnection clears disconnected-input status without replaying dropped input');
  await page.evaluate('WebSocket.prototype.send=originalSend;observer.disconnect()');
  await page.evaluate(`window.resizeEvents=[];window.resizeMode='fail';window.heldResize=null;
    WebSocket.prototype.send=function(text){const message=JSON.parse(text);
      if(message.type==='request' && message.op==='resize' && message.pane==='harness'){
        resizeEvents.push({...message,time:performance.now()});
        if(resizeMode==='fail')throw new Error('synthetic PTY resize failure');
        if(resizeMode==='hold'){window.heldResize=message;return}
      }
      return originalSend.call(this,text)
    };
    subject.root.style.width='600px';subject.resized()`);
  const resizeFailed = () => page.evaluate('subject.root.querySelector(".state").textContent==="resize failed after 4 attempts"');
  const resizeSucceeded = () => page.evaluate(`resizeEvents.length && replies.some(r=>r.id===resizeEvents.at(-1).id && !r.body.error) && !subject.root.querySelector('.state').textContent`);
  const pause = ms => page.evaluate(`new Promise(resolve=>setTimeout(resolve,${ms}))`);
  await waitFor(resizeFailed);
  await check(`resizeEvents.length===4 && resizeEvents.slice(1).every((event,i)=>event.time-resizeEvents[i].time>=[280,580,1180][i])`, 'resize failures retry three times with increasing delays');
  await check(`subject.root.querySelector('.state').title==='synthetic PTY resize failure'`, 'exhausted resize shows the failure and its underlying cause');
  await page.evaluate(`subject.type('RESIZE_STILL_ALIVE\\r');for(let i=0;i<5;i++)subject.resized()`);
  await waitFor(() => page.evaluate('subject.body.textContent.includes("RESIZE_STILL_ALIVE")'));
  await pause(1500);
  await check(`resizeEvents.length===4 && subject.root.querySelector('.state').textContent==='resize failed after 4 attempts'`, 'normal output, input and unchanged geometry do not reset an exhausted retry budget');
  await waitFor(async () => (await readFile(join(root,'errors','terminal-errors.jsonl'),'utf8')).includes('synthetic PTY resize failure'));
  const resizeErrors = (await readFile(join(root,'errors','terminal-errors.jsonl'),'utf8')).trim().split('\n').map(JSON.parse)
    .filter(entry=>entry.phase==='resize-delivery' && entry.message==='synthetic PTY resize failure');
  assert.equal(resizeErrors.length,1);
  assert.equal(resizeErrors[0].attempts,'4');
  checks.push('exhausted resize is logged once with the attempt count');
  await page.evaluate('resizeMode="pass";wire.close()');
  await waitFor(resizeSucceeded);
  await check('resizeEvents.length===5', 'reconnection retries the requested size and clears the failure on success');

  await page.evaluate('resizeEvents=[];resizeMode="fail";subject.root.style.width="640px";subject.resized()');
  await waitFor(resizeFailed);
  await page.evaluate('resizeMode="pass";subject.root.style.width="680px";subject.resized()');
  await waitFor(resizeSucceeded);
  await check('resizeEvents.length===5', 'a new requested size can recover after the previous size exhausted its retries');

  for (const late of ['failure','success']) {
    await page.evaluate('resizeEvents=[];resizeMode="hold";heldResize=null;subject.root.style.width="720px";subject.resized()');
    await waitFor(() => page.evaluate('!!heldResize'));
    await page.evaluate('resizeMode="pass";subject.root.style.width="760px";subject.resized()');
    await waitFor(resizeSucceeded);
    await page.evaluate(`wire.onmessage({data:JSON.stringify({type:'reply',id:heldResize.id,body:${late==='failure'?'{error:"late resize failure"}':'{ok:true}'}})});subject.resized()`);
    await pause(800);
    await check(`resizeEvents.length===2 && !subject.root.querySelector('.state').textContent`, `an old resize ${late} cannot overwrite a newer size or restart retries`);
  }

  await page.evaluate('resizeEvents=[];resizeMode="fail";subject.root.style.width="800px";subject.resized()');
  await waitFor(() => page.evaluate('resizeEvents.length===1'));
  await page.evaluate('subject.toggle()');
  await pause(1500);
  await check('resizeEvents.length===1', 'closing a pane cancels pending resize retries');
  await page.evaluate('resizeMode="pass";subject.open();subject.focus()');
  await waitFor(resizeSucceeded);
  await check('resizeEvents.length===2', 'reopening a pane resynchronizes its terminal size');
  await page.evaluate('WebSocket.prototype.send=originalSend;console.error=originalConsoleError');
  console.log(`Passed ${checks.length} ${engine} pane interaction checks.`);
} catch (error) {
  if (process.env.VZ_TEST_ARTIFACTS) {
    const artifacts = join(process.env.VZ_TEST_ARTIFACTS, engine);
    await mkdir(artifacts, {recursive: true});
    await writeFile(join(artifacts, 'failure.json'), JSON.stringify({error: error.stack, checks, logs, browserErrors: page?.errors}, null, 2));
    await cp(join(root, 'errors'), join(artifacts, 'terminal-errors'), {recursive: true}).catch(() => {});
    if (page) await page.screenshot().then(bytes => writeFile(join(artifacts, 'failure.png'), bytes)).catch(() => {});
  }
  if(page) console.error(await page.evaluate('({focus:document.activeElement?.tagName,picked:panes?.pickedPanel()?.id,panels:panes.all.map(p=>({id:p.id,box:p.root.getBoundingClientRect().toJSON(),state:p.root.querySelector(".state").textContent}))})').catch(()=>null));
  console.error(logs.join('').slice(-3000));
  throw error;
} finally {
  await page?.close();
  await stopProcess(server, 'SIGINT');
  await rm(root, {recursive: true, force: true, maxRetries: 5, retryDelay: 200});
}
