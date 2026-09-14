import { spawn } from 'node:child_process';
import { mkdtemp, mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';
import assert from 'node:assert/strict';
import { configCompletions } from '../src/web/config/completion.js';
import { matchConfigNodes, configSearchCompletions } from '../src/web/config/search.js';

const options = {docs: [{name: 'box', args: ['name', 'color?']}, {name: 'fold', args: ['name']}],
  colours: ['blue', 'red'], prefixes: ['src.web.app'], lines: ['fold src.web', 'box src red']};
assert.deepEqual(configCompletions('fo', 2, options).items, ['fold', 'unfold']);
assert.deepEqual(configCompletions('unf', 3, options).items, ['unfold src.web']);
assert.deepEqual(configCompletions('unfold src.', 11, options).items, ['unfold src.web']);
assert.deepEqual(configCompletions('unbox src re', 12, options).items, ['unbox src red']);
assert.deepEqual(configCompletions('unbox src blue', 14, options).items, []);
assert.deepEqual(configCompletions('unfold src.web.app', 18, options).items, []);
assert.deepEqual(configCompletions('un', 2, {...options, lines: []}).items, []);
const undoOptions = {...options, docs: [...options.docs, {name: 'lines', args: []}], lines: [
  '#fold disabled', '  #box disabled red', '@visualize terminal 1 socket /tmp/a',
  'fold "outside graph" # note', 'fold   "outside graph"', 'box "src#name" blue',
  'lines', 'fold', 'fold too many', 'unknown src', 'box "unfinished',
]};
assert.deepEqual(configCompletions('un', 2, undoOptions).items,
  ['unlines', 'unbox "src#name" blue', 'unfold "outside graph"']);
assert.deepEqual(configCompletions('unfold "out', 11, undoOptions),
  {start: 0, end: 11, items: ['unfold "outside graph"'], wholeLine: true});
assert.equal(configCompletions('unfold old tail', 8, undoOptions).end, 15);
assert(configCompletions('fold src.', 9, options).items.includes('src.web.app'));
assert.deepEqual(configCompletions('box src red', 11, options).items, ['red']);
assert(!configCompletions('box src red extra', 17, options).items.length);
const searchModel = {nodes: [
  {id: 'fold-a', label: 'fold', kind: 'command', text: 'unrelated source text'},
  {id: 'fold-b', label: 'fold', kind: 'command'},
  {id: 'box-a', label: 'box', kind: 'command', text: 'fold b'},
  {id: 'a', label: 'a', kind: 'prefix'}, {id: 'b', label: 'b', kind: 'prefix'},
  {id: 'a-child', label: 'a.child', kind: 'prefix'},
  {id: 'deep', label: 'hide', kind: 'command'},
], edges: [['a', 'fold-a'], ['b', 'fold-b'], ['a', 'box-a'], ['a-child', 'deep'], ['a', 'a-child']]};
assert.deepEqual(matchConfigNodes(searchModel, 'fold a').map(hit => hit.node.id), ['fold-a']);
assert.deepEqual(matchConfigNodes(searchModel, 'fold b').map(hit => hit.node.id), ['fold-b']);
assert.deepEqual(matchConfigNodes(searchModel, 'box b'), []);
assert.deepEqual(matchConfigNodes(searchModel, 'hide a').map(hit => hit.node.id), ['deep']);
assert.deepEqual(matchConfigNodes(searchModel, 'unrelated source'), []);
assert.deepEqual(matchConfigNodes(searchModel, 'fld a'), []);
assert.deepEqual(matchConfigNodes(searchModel, 'hide achild'), []);
assert.deepEqual(matchConfigNodes(searchModel, 'FOLD A').map(hit => hit.node.id), ['fold-a']);
assert.deepEqual(configSearchCompletions(searchModel, 'fo').items, ['fold']);
assert.deepEqual(configSearchCompletions(searchModel, 'fld').items, []);
assert.deepEqual(configSearchCompletions(searchModel, 'hide achild').items, []);
assert.deepEqual(configSearchCompletions(searchModel, 'fold ').items, ['a', 'b']);
assert.deepEqual(configSearchCompletions(searchModel, 'box ').items, ['a']);
assert.deepEqual(configSearchCompletions(searchModel, 'hide ').items, ['a', 'a.child']);
assert.deepEqual(configSearchCompletions(searchModel, 'fold a ').items, ['a']);
assert.deepEqual(configSearchCompletions(searchModel, 'fold z').items, []);
assert.deepEqual(configSearchCompletions(searchModel, 'fold bee', 6), {start: 5, end: 8, items: ['b']});
assert.deepEqual(configSearchCompletions({nodes: [{id: 'x', label: 'box blue'}], edges: []}, '"box b').items, ['box blue']);

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const root = await mkdtemp(join(tmpdir(), 'vz-config-editor-'));
const file = join(root, 'project', 'visualize_config');
const output = resolve(process.argv[2] || '/tmp/visualize-config-editor.png');
const logs = [], failures = [];
let server, chrome, socket, cdp;
async function waitFor(fn, ms = 20000) {
  const end = Date.now() + ms;
  while (Date.now() < end) { try { const value = await fn(); if (value) return value; } catch {} await sleep(50); }
  throw new Error('Timed out: ' + fn.toString() + '\n' + logs.join('').slice(-2500) + '\n' + JSON.stringify(failures));
}
class CDP {
  constructor(ws) {
    this.ws = ws; this.id = 0; this.pending = new Map();
    ws.addEventListener('message', event => {
      const message = JSON.parse(event.data);
      if (message.method === 'Runtime.exceptionThrown') failures.push(message.params);
      const pending = this.pending.get(message.id); if (!pending) return;
      this.pending.delete(message.id);
      message.error ? pending.reject(new Error(JSON.stringify(message.error))) : pending.resolve(message.result);
    });
  }
  send(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = ++this.id; this.pending.set(id, {resolve, reject}); this.ws.send(JSON.stringify({id, method, params}));
    });
  }
  async evaluate(expression) {
    const result = await this.send('Runtime.evaluate', {expression, awaitPromise: true, returnByValue: true});
    if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
    return result.result.value;
  }
}
try {
  await mkdir(join(root, 'project', 'b', 'a'), {recursive: true});
  await mkdir(join(root, 'bin'));
  await writeFile(join(root, 'project', 'b', 'a', 'file.txt'), 'sample\n');
  await writeFile(file, 'box b\nbox b.a\nfold b\nlines\n');
  await writeFile(join(root, 'bin', 'open'), '#!/bin/sh\nprintf "%s" "$1" > "$VZ_TEST_URL"\n', {mode: 0o755});
  server = spawn(join(repo, 'external-src/janet/janet'), [join(repo, 'src.server/core.janet'), join(root, 'project'), '--no-dev', '--command', 'exec /bin/cat'], {
    cwd: repo, stdio: ['ignore', 'pipe', 'pipe'], env: {...process.env,
      PATH: join(root, 'bin') + ':' + process.env.PATH, VZ_TEST_URL: join(root, 'url'),
},
  });
  for (const stream of [server.stdout, server.stderr]) stream.on('data', data => logs.push(String(data)));
  const url = await waitFor(() => readFile(join(root, 'url'), 'utf8'));
  chrome = spawn(process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
    '--headless=new', '--no-first-run', '--no-default-browser-check', '--remote-debugging-port=0',
    '--user-data-dir=' + join(root, 'chrome'), 'about:blank'], {stdio: 'ignore'});
  const port = (await waitFor(() => readFile(join(root, 'chrome', 'DevToolsActivePort'), 'utf8'))).split('\n')[0];
  const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  socket = new WebSocket(targets.find(target => target.type === 'page').webSocketDebuggerUrl);
  await new Promise(resolve => socket.addEventListener('open', resolve));
  cdp = new CDP(socket);
  await cdp.send('Runtime.enable'); await cdp.send('Page.enable');
  await cdp.send('Emulation.setDeviceMetricsOverride', {width: 1280, height: 900, deviceScaleFactor: 1, mobile: false});
  await cdp.send('Page.navigate', {url});
  await waitFor(() => cdp.evaluate('!!document.querySelector("#config .config-command input")'));
  await cdp.evaluate('(async()=>{const {workspace}=await import("/app.js"); const configPanel=workspace.get("config"); configPanel.open();configPanel.root.style.width="780px";configPanel.root.style.height="620px";})()');
  await waitFor(() => cdp.evaluate('document.querySelectorAll("#config .config-diagram .node").length===6'));
  assert(await cdp.evaluate('document.activeElement===document.querySelector("#config .config-command input") && document.querySelector("#config .config-completions").hidden'));
  assert(await cdp.evaluate(`(()=>{
    const pane=document.querySelector('#config .config-document').getBoundingClientRect();
    const add=document.querySelector('#config .config-command input').getBoundingClientRect();
    const find=document.querySelector('#config .config-search input').getBoundingClientRect();
    return [add.left-pane.left, find.left-add.right, pane.right-find.right, add.top-pane.top].every(gap=>Math.abs(gap-6)<.1);
  })()`));
  await cdp.evaluate('document.fonts.ready');
  assert(await cdp.evaluate(`(()=>{
    const nodes=[...document.querySelectorAll('#config .node')];
    return nodes.every(node=>{
      const oval=node.querySelector('ellipse'), label=node.querySelector(':scope > text'), box=label.getBBox();
      return Math.abs(box.x+box.width/2-oval.cx.baseVal.value)<1 && Math.abs(box.y+box.height/2-oval.cy.baseVal.value)<2;
    });
  })()`));
  assert(await cdp.evaluate(`(()=>{
    const boxes=[...document.querySelectorAll('#config .node ellipse')].map(node=>node.getBBox());
    return boxes.every((box,i)=>boxes.slice(i+1).every(other=>
      box.x+box.width<=other.x || other.x+other.width<=box.x || box.y+box.height<=other.y || other.y+other.height<=box.y))
      && document.querySelectorAll('#config .edge polygon').length===4;
  })()`));
  assert(await cdp.evaluate(`(()=>{
    const centers=new Map([...document.querySelectorAll('#config .node')].map(node=>
      [node.querySelector('title').textContent, node.querySelector('ellipse').cy.baseVal.value]));
    return [...document.querySelectorAll('#config .edge')].every(edge=>{
      const [from,to]=edge.querySelector('title').textContent.split('->');
      return centers.get(from)<centers.get(to);
    });
  })()`));
  assert.equal(await cdp.evaluate('document.querySelectorAll("#config .config-node-action").length'), 12);
  const camera = () => cdp.evaluate(`(()=>{const m=document.querySelector('#config .graph-camera').transform.baseVal.consolidate().matrix;return {scale:m.a,x:m.e,y:m.f}})()`);
  await waitFor(() => cdp.evaluate(`!!document.querySelector('#config .graph-camera')?.transform.baseVal.consolidate()`));
  const initialCamera = await camera();
  const mainCamera = await cdp.evaluate('(async()=>({...((await import("/app.js")).graph.view())}))()');
  const graphBox = await cdp.evaluate('document.querySelector("#config .config-diagram").getBoundingClientRect().toJSON()');
  const inputBox = await cdp.evaluate('document.querySelector("#config .config-command").getBoundingClientRect().toJSON()');
  async function drag(dx, dy) {
    const point = {x: graphBox.right - 32, y: graphBox.bottom - 32};
    await cdp.send('Input.dispatchMouseEvent', {type: 'mousePressed', ...point, button: 'left', buttons: 1, clickCount: 1});
    await cdp.send('Input.dispatchMouseEvent', {type: 'mouseMoved', x: point.x + dx, y: point.y + dy, button: 'left', buttons: 1});
    await cdp.send('Input.dispatchMouseEvent', {type: 'mouseReleased', x: point.x + dx, y: point.y + dy, button: 'left', buttons: 0, clickCount: 1});
    await cdp.evaluate('new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))');
  }
  await drag(-50, -35);
  const panned = await camera();
  assert(Math.abs(panned.x - initialCamera.x + 50) < .1 && Math.abs(panned.y - initialCamera.y + 35) < .1);
  assert.equal(panned.scale, initialCamera.scale);
  assert(!await cdp.evaluate('document.querySelector("#config .config-diagram").classList.contains("panning")'));
  const pointer = {x: Math.round(graphBox.x + graphBox.width * .4), y: Math.round(graphBox.y + graphBox.height * .3)};
  await cdp.send('Input.dispatchMouseEvent', {type: 'mouseWheel', ...pointer, deltaX: 0, deltaY: -80});
  await waitFor(async () => (await camera()).scale > panned.scale);
  const zoomed = await camera();
  assert(Math.abs(zoomed.scale / panned.scale - Math.exp(.16)) < .001);
  assert(Math.abs((pointer.x - graphBox.x - zoomed.x) / zoomed.scale - (pointer.x - graphBox.x - panned.x) / panned.scale) < .1);
  assert(Math.abs((pointer.y - graphBox.y - zoomed.y) / zoomed.scale - (pointer.y - graphBox.y - panned.y) / panned.scale) < .1);
  await cdp.send('Input.dispatchMouseEvent', {type: 'mouseWheel', ...pointer, deltaX: 0, deltaY: -10, modifiers: 2});
  await waitFor(async () => (await camera()).scale > zoomed.scale);
  assert(Math.abs((await camera()).scale / zoomed.scale - Math.exp(.1)) < .001);
  assert.deepEqual(await cdp.evaluate('(async()=>({...((await import("/app.js")).graph.view())}))()'), mainCamera);
  assert.deepEqual(await cdp.evaluate('document.querySelector("#config .config-command").getBoundingClientRect().toJSON()'), inputBox);
  await cdp.send('Input.dispatchKeyEvent', {type: 'keyDown', key: '0', code: 'Digit0', windowsVirtualKeyCode: 48, modifiers: 2});
  await cdp.send('Input.dispatchKeyEvent', {type: 'keyUp', key: '0', code: 'Digit0', windowsVirtualKeyCode: 48});
  await waitFor(async () => Math.abs((await camera()).scale - initialCamera.scale) < .001);
  assert.deepEqual(await cdp.evaluate('(async()=>({...((await import("/app.js")).graph.view())}))()'), mainCamera);
  await drag(-20, -10);
  const keptCamera = await camera();
  await cdp.evaluate('window.firstGraph=document.querySelector("#config .config-diagram svg");document.querySelector("#config .config-command input").focus()');
  await cdp.send('Input.insertText', {text: 'fold b.a'});
  await sleep(2200);
  assert(await cdp.evaluate('document.activeElement===document.querySelector("#config .config-command input") && document.activeElement.value==="fold b.a" && window.firstGraph===document.querySelector("#config .config-diagram svg")'));
  assert(await cdp.evaluate('document.querySelector("#config .config-completions").textContent.includes("b.a")'));
  await cdp.send('Input.dispatchKeyEvent', {type: 'keyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, text: '\r'});
  await cdp.send('Input.dispatchKeyEvent', {type: 'keyUp', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13});
  await waitFor(async () => (await readFile(file, 'utf8')).includes('\nfold b.a\n'));
  await waitFor(() => cdp.evaluate('document.querySelectorAll("#config .config-diagram .node").length===7'));
  await cdp.evaluate('new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))');
  assert.deepEqual(await camera(), keptCamera);
  await cdp.evaluate(`(async()=>{const {configReader}=await import('/config/editor.js');const body=document.createElement('div');body.id='second-reader';document.body.append(body);window.secondReader=configReader({body,shut:false},'second',${JSON.stringify(file)});})()`);
  await waitFor(() => cdp.evaluate('document.querySelectorAll("#second-reader .node").length===7'));
  await cdp.evaluate('window.secondReader.focus()');
  assert(await cdp.evaluate('document.activeElement===document.querySelector("#second-reader .config-command input") && document.querySelector("#second-reader .config-completions").hidden'));
  async function click(node, action) {
    await waitFor(() => cdp.evaluate('!document.querySelector("#config .config-document.saving")'));
    await cdp.evaluate('new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))');
    const selector = `#config [data-node=${JSON.stringify(node)}] [data-action=${JSON.stringify(action)}]`;
    const point = await cdp.evaluate(`(()=>{const element=document.querySelector(${JSON.stringify(selector)});element.scrollIntoView({block:'nearest'});const box=element.getBoundingClientRect();return {x:box.x+box.width/2,y:box.y+box.height/2}})()`);
    await cdp.send('Input.dispatchMouseEvent', {type: 'mousePressed', ...point, button: 'left', clickCount: 1});
    await cdp.send('Input.dispatchMouseEvent', {type: 'mouseReleased', ...point, button: 'left', clickCount: 1});
  }
  await click('p:b', 'subtree-comment');
  await waitFor(async () => (await readFile(file, 'utf8')).includes('#box b.a'));
  await waitFor(() => cdp.evaluate('document.querySelectorAll("#second-reader .commented").length===6'));
  assert((await readFile(file, 'utf8')).includes('#fold b.a'));
  await click('p:b', 'subtree-comment');
  await waitFor(async () => !(await readFile(file, 'utf8')).includes('#box b.a'));
  await click('p:b.a', 'subtree-delete');
  await waitFor(async () => !(await readFile(file, 'utf8')).includes('b.a'));
  assert((await readFile(file, 'utf8')).includes('box b\n'));
  await waitFor(() => cdp.evaluate('document.querySelectorAll("#second-reader .node").length===4'));
  await cdp.evaluate('window.secondReader.stop();document.querySelector("#second-reader").remove()');
  await cdp.evaluate('document.querySelector("#config .config-command input").focus()');
  await cdp.send('Input.insertText', {text: 'lines extra'});
  await cdp.evaluate('document.querySelector("#config .config-command").requestSubmit()');
  await waitFor(() => cdp.evaluate('document.querySelector("#config .config-document-status").textContent.length>0'));
  await sleep(1300);
  assert(await cdp.evaluate('document.querySelector("#config .config-document-status").textContent.length>0'));
  assert(!(await readFile(file, 'utf8')).includes('lines extra'));
  await cdp.evaluate('const input=document.querySelector("#config .config-command input");input.value="";input.dispatchEvent(new Event("input"));input.blur();document.querySelector("#compose").classList.remove("shut");document.querySelector("#compose-input").focus()');
  await cdp.send('Input.insertText', {text: 'box c'});
  await cdp.send('Input.dispatchKeyEvent', {type: 'keyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, text: '\r'});
  await cdp.send('Input.dispatchKeyEvent', {type: 'keyUp', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13});
  await waitFor(async () => (await readFile(file, 'utf8')).includes('box c'));
  await waitFor(() => cdp.evaluate(`!!document.querySelector('#config [data-node="p:c"]')`));
  const beforeDuplicate = await readFile(file, 'utf8');
  await cdp.evaluate(`(()=>{const input=document.querySelector('#config .config-command input');input.value='box c';input.dispatchEvent(new Event('input'));document.querySelector('#config .config-command').requestSubmit();})()`);
  await waitFor(() => cdp.evaluate(`!document.querySelector('#config .config-document.saving') && document.querySelector('#config .config-command input').value===''`));
  assert.equal(await readFile(file, 'utf8'), beforeDuplicate);
  assert.equal(await cdp.evaluate(`document.querySelectorAll('#config .node').length`), 6);
  await cdp.evaluate('document.querySelector("#config").style.width="340px"');
  await sleep(300);
  assert(await cdp.evaluate('(()=>{const p=document.querySelector("#config .panel-body").getBoundingClientRect();const v=document.querySelector("#config .config-document").getBoundingClientRect();return v.top>=p.top && v.bottom<=p.bottom+1})()'));
  await cdp.evaluate('document.querySelector("#config").style.width="780px"');
  await sleep(100);
  assert(await cdp.evaluate(`(()=>{
    const command=document.querySelector('#config .config-command').getBoundingClientRect();
    const search=document.querySelector('#config .config-search').getBoundingClientRect();
    return Math.abs(command.width-search.width)<1 && search.left>command.right && Math.abs(command.top-search.top)<1;
  })()`));
  await waitFor(async () => (await readFile(file, 'utf8')).includes('placement bottom 0 780 620'));
  const beforeSearch = await readFile(file, 'utf8');
  async function search(query) {
    await cdp.evaluate(`(()=>{const input=document.querySelector('#config .config-search input');input.focus();input.value=${JSON.stringify(query)};input.dispatchEvent(new Event('input'));})()`);
    await cdp.evaluate('new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))');
  }
  const selectedNode = () => cdp.evaluate(`document.querySelector('#config .node.search-hit')?.dataset.node`);
  const suggestions = () => cdp.evaluate(`Array.from(document.querySelectorAll('#config .config-search-completions li'), item=>item.textContent)`);
  async function key(key, modifiers = 0) {
    await cdp.send('Input.dispatchKeyEvent', {type: 'keyDown', key, modifiers,
      ...(key === 'Enter' ? {code: 'Enter', windowsVirtualKeyCode: 13, text: '\r'} : {})});
    await cdp.send('Input.dispatchKeyEvent', {type: 'keyUp', key, modifiers});
  }
  await search('fo');
  assert.deepEqual(await suggestions(), ['fold']);
  await key('Tab');
  assert.equal(await cdp.evaluate(`document.querySelector('#config .config-search input').value`), 'fold');
  assert(await cdp.evaluate(`document.querySelector('#config .config-search-completions').hidden`));
  await search('fold ');
  assert.deepEqual(await suggestions(), ['b']);
  await key('ArrowDown');
  assert(await cdp.evaluate(`!!document.querySelector('#config .config-search-completions [aria-selected="true"]')`));
  await key('Enter');
  assert.equal(await cdp.evaluate(`document.querySelector('#config .config-search input').value`), 'fold b');
  assert.equal(await selectedNode(), 'c1');
  await search('box ');
  assert.deepEqual(await suggestions(), ['b', 'c']);
  await key('n', 2);
  assert.equal(await cdp.evaluate(`document.querySelector('#config .config-search-completions [aria-selected="true"]').textContent`), 'b');
  await key('n', 2);
  assert.equal(await cdp.evaluate(`document.querySelector('#config .config-search-completions [aria-selected="true"]').textContent`), 'c');
  await key('p', 2);
  assert.equal(await cdp.evaluate(`document.querySelector('#config .config-search-completions [aria-selected="true"]').textContent`), 'b');
  const suggestionPoint = await cdp.evaluate(`(()=>{const r=document.querySelector('#config .config-search-completions li:last-child').getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()`);
  await cdp.send('Input.dispatchMouseEvent', {type: 'mousePressed', ...suggestionPoint, button: 'left', clickCount: 1});
  await cdp.send('Input.dispatchMouseEvent', {type: 'mouseReleased', ...suggestionPoint, button: 'left', clickCount: 1});
  assert.equal(await cdp.evaluate(`document.querySelector('#config .config-search input').value`), 'box c');
  assert.equal(await selectedNode(), 'c3');
  await search('fold ');
  await key('Escape');
  assert.equal(await cdp.evaluate(`document.querySelector('#config .config-search input').value`), 'fold ');
  assert(await cdp.evaluate(`document.querySelector('#config .config-search-completions').hidden`));
  await key('Escape');
  assert.equal(await cdp.evaluate(`document.querySelector('#config .config-search input').value`), '');
  await search('fold z');
  assert(await cdp.evaluate(`document.querySelector('#config .config-search-completions').hidden`));
  await search('fold b');
  assert.equal(await selectedNode(), 'c1');
  assert(await cdp.evaluate(`(()=>{
    const node=document.querySelector('#config .node.search-hit ellipse').getBoundingClientRect();
    const graph=document.querySelector('#config .config-diagram').getBoundingClientRect();
    const arrow=document.querySelector('#config .config-find-arrow');
    const tip=new DOMPoint(0,0).matrixTransform(arrow.getScreenCTM());
    return arrow.dataset.node==='c1' && Math.abs(node.x+node.width/2-graph.x-graph.width/2)<1
      && Math.abs(node.y+node.height/2-graph.y-graph.height/2)<1
      && Math.min(Math.abs(tip.x-node.left),Math.abs(tip.x-node.right),Math.abs(tip.y-node.top),Math.abs(tip.y-node.bottom))<1;
  })()`));
  const arrowBox = await cdp.evaluate(`document.querySelector('#config .config-find-arrow').getBoundingClientRect().toJSON()`);
  await cdp.send('Input.dispatchMouseEvent', {type: 'mouseWheel', ...pointer, deltaX: 0, deltaY: -20});
  await sleep(100);
  const arrowAfterZoom = await cdp.evaluate(`document.querySelector('#config .config-find-arrow').getBoundingClientRect().toJSON()`);
  assert(Math.abs(arrowBox.width-arrowAfterZoom.width)<1 && Math.abs(arrowBox.height-arrowAfterZoom.height)<1);
  await search('box c');
  assert.equal(await cdp.evaluate(`document.querySelector('#config .node.search-hit > text').textContent`), 'box');
  assert.equal(await selectedNode(), 'c3');
  await search('fold c');
  assert.equal(await cdp.evaluate(`document.querySelector('#config .config-search-count').textContent`), 'no match');
  assert(!await cdp.evaluate(`!!document.querySelector('#config .config-find-arrow')`));
  await search('box');
  const firstBox = await selectedNode();
  await cdp.send('Input.dispatchKeyEvent', {type: 'keyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13});
  await cdp.send('Input.dispatchKeyEvent', {type: 'keyUp', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13});
  assert.notEqual(await selectedNode(), firstBox);
  assert.equal(await readFile(file, 'utf8'), beforeSearch);
  await search('fold b');
  await drag(-20, -10);
  const anchor = await cdp.evaluate(`document.querySelector('#config .node.search-hit ellipse').getBoundingClientRect().toJSON()`);
  await cdp.evaluate(`document.querySelector('#config [data-node="c0"] [data-action="subtree-delete"]').dispatchEvent(new MouseEvent('click',{bubbles:true}))`);
  await waitFor(async () => await selectedNode() === 'c0');
  await cdp.evaluate('new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))');
  const anchored = await cdp.evaluate(`document.querySelector('#config .node.search-hit ellipse').getBoundingClientRect().toJSON()`);
  assert(Math.abs(anchor.x-anchored.x)<1 && Math.abs(anchor.y-anchored.y)<1);
  await search('');
  assert(!await cdp.evaluate(`!!document.querySelector('#config .config-find-arrow, #config .node.search-hit')`));
  await search('fold b');
  const metadata = (await readFile(file, 'utf8')).split('\n').filter(line => line.startsWith('@visualize '));
  await writeFile(file, ['box b', 'fold b.a', '#hide b.a.deep', 'box c', 'fold c.a', 'hide bee', ...metadata, ''].join('\n'));
  await waitFor(() => cdp.evaluate(`!!document.querySelector('#config [data-node="p:b.a.deep"]')`));
  await cdp.evaluate(`(async()=>{const {configReader}=await import('/config/editor.js');const body=document.createElement('div');body.id='rename-peer';document.body.append(body);window.renamePeer=configReader({body,shut:false},'rename-peer',${JSON.stringify(file)});})()`);
  await waitFor(() => cdp.evaluate(`!!document.querySelector('#rename-peer [data-node="p:b.a.deep"]')`));
  async function beginRename(prefix) {
    await search(prefix);
    for (let i = 0; await selectedNode() !== `p:${prefix}` && i < 20; i++) await key('Enter');
    assert.equal(await selectedNode(), `p:${prefix}`);
    await cdp.evaluate('new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))');
    await cdp.evaluate(`document.querySelector('#config .config-search input').blur()`);
    const point = await cdp.evaluate(`(()=>{const r=document.querySelector('#config [data-node="p:${prefix}"] .config-node-label').getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()`);
    await cdp.send('Input.dispatchMouseEvent', {type: 'mousePressed', ...point, button: 'left', clickCount: 1});
    await cdp.send('Input.dispatchMouseEvent', {type: 'mouseReleased', ...point, button: 'left', clickCount: 1});
    assert(await cdp.evaluate(`document.activeElement===document.querySelector('#config .config-rename') && !!document.activeElement`));
    assert.equal(await cdp.evaluate(`document.activeElement.value`), prefix.split('.').at(-1));
  }
  await beginRename('b');
  const beforeCancel = await readFile(file, 'utf8');
  await cdp.send('Input.insertText', {text: 'cancelled'});
  await key('Escape');
  assert(!await cdp.evaluate(`!!document.querySelector('#config .config-rename')`));
  assert.equal(await readFile(file, 'utf8'), beforeCancel);
  await beginRename('b');
  await cdp.send('Input.insertText', {text: 'c'});
  await sleep(1400);
  assert(await cdp.evaluate(`document.activeElement===document.querySelector('#config .config-rename') && document.activeElement.value==='c'`));
  await key('Enter');
  await waitFor(async () => !(await readFile(file, 'utf8')).includes('box b\n'));
  await waitFor(() => cdp.evaluate(`!!document.querySelector('#rename-peer [data-node="p:c.a.deep"]') && !document.querySelector('#rename-peer [data-node="p:b"]')`));
  const merged = (await readFile(file, 'utf8')).split('\n').filter(line => line && !line.startsWith('@visualize '));
  assert.deepEqual(merged, ['box c', 'fold c.a', '#hide c.a.deep', 'hide bee']);
  await beginRename('c.a');
  await cdp.send('Input.insertText', {text: 'folder.child'});
  await key('Enter');
  await waitFor(() => cdp.evaluate(`!!document.querySelector('#config [data-node="p:c.folder.child.deep"]')`));
  assert((await readFile(file, 'utf8')).includes('#hide c.folder.child.deep'));
  await beginRename('c.folder.child');
  await cdp.send('Input.insertText', {text: 'lost'});
  const beforeConflict = await readFile(file, 'utf8');
  await writeFile(file, beforeConflict + 'animate\n');
  await key('Enter');
  await waitFor(() => cdp.evaluate(`document.querySelector('#config .config-document-status').textContent.includes('Configuration changed')`));
  assert.equal(await readFile(file, 'utf8'), beforeConflict + 'animate\n');
  await cdp.evaluate(`window.renamePeer.stop();document.querySelector('#rename-peer').remove()`);
  await cdp.evaluate(`(()=>{document.querySelector('#compose').classList.remove('shut');const input=document.querySelector('#compose-input');input.focus();input.value='unfold c.folder.child';input.dispatchEvent(new Event('input'));})()`);
  await cdp.send('Input.dispatchKeyEvent', {type: 'keyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, text: '\r'});
  await cdp.send('Input.dispatchKeyEvent', {type: 'keyUp', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13});
  await waitFor(async () => (await readFile(file, 'utf8')).split('\n').includes('#fold c.folder.child'));
  const disabled = await readFile(file, 'utf8');
  assert(!disabled.split('\n').includes('fold c.folder.child'));
  assert(!disabled.includes('unfold'));
  async function submitConfig(command) {
    await cdp.evaluate(`(()=>{const input=document.querySelector('#config .config-command input');input.focus();input.value=${JSON.stringify(command)};input.dispatchEvent(new Event('input'));document.querySelector('#config .config-command').requestSubmit();})()`);
    await waitFor(() => cdp.evaluate(`!document.querySelector('#config .config-document.saving') && document.querySelector('#config .config-command input').value===''`));
  }
  await submitConfig('unfold c.folder.child');
  assert.equal(await readFile(file, 'utf8'), disabled);
  await submitConfig('fold c.folder.child');
  const restored = disabled.replace('#fold c.folder.child\n', 'fold c.folder.child\n');
  assert.equal(await readFile(file, 'utf8'), restored);
  await submitConfig('fold c.folder.child');
  assert.equal(await readFile(file, 'utf8'), restored);
  await submitConfig('unfold c.folder.child');
  assert.equal(await readFile(file, 'utf8'), disabled);
  await submitConfig('fold c.folder.child');
  async function commandSuggestions(selector, text) {
    await cdp.evaluate(`(()=>{const input=document.querySelector(${JSON.stringify(selector)});input.focus();input.value=${JSON.stringify(text)};input.dispatchEvent(new Event('input'));})()`);
  }
  const undoItems = selector => cdp.evaluate(`[...document.querySelectorAll(${JSON.stringify(selector)})].map(item=>item.textContent)`);
  await waitFor(() => cdp.evaluate(`!!document.querySelector('#config [data-node="p:c.folder.child"]')`));
  await commandSuggestions('#config .config-command input', 'unfold c.folder');
  await waitFor(async () => (await undoItems('#config .config-completions li')).includes('unfold c.folder.child'));
  await key('Tab');
  assert.equal(await cdp.evaluate(`document.querySelector('#config .config-command input').value`), 'unfold c.folder.child');
  await key('Enter');
  await waitFor(async () => (await readFile(file, 'utf8')).includes('#fold c.folder.child'));
  await waitFor(() => cdp.evaluate(`!document.querySelector('#config .config-document.saving')`));
  await commandSuggestions('#config .config-command input', 'unfold c.folder');
  assert.deepEqual(await undoItems('#config .config-completions li'), []);
  await cdp.evaluate(`document.querySelector('#compose').classList.remove('shut')`);
  await commandSuggestions('#compose-input', 'unfold c.folder');
  await waitFor(async () => !(await undoItems('#compose-list li')).includes('unfold c.folder.child'));
  await submitConfig('fold c.folder.child');
  await commandSuggestions('#compose-input', 'unfold c.folder');
  await waitFor(async () => (await undoItems('#compose-list li')).includes('unfold c.folder.child'));
  await key('Tab');
  assert.equal(await cdp.evaluate(`document.querySelector('#compose-input').value`), 'unfold c.folder.child');
  await key('Escape');
  await key('Escape');
  const nested = join(root, 'project', 'nested'); await mkdir(nested);
  const nestedFile = join(nested, 'visualize_config'); await writeFile(nestedFile, 'fold "only here" # note\n#fold disabled\n');
  await cdp.evaluate(`(async()=>{const {configReader}=await import('/config/editor.js');const body=document.createElement('div');body.id='undo-reader';document.body.append(body);window.undoReader=configReader({body,shut:false},'undo',${JSON.stringify(nestedFile)},{docs:window.CONFIG_DOCS});})()`);
  await waitFor(() => cdp.evaluate(`!!document.querySelector('#undo-reader .config-diagram svg')`));
  await commandSuggestions('#undo-reader .config-command input', 'un');
  assert.deepEqual(await undoItems('#undo-reader .config-completions li'), ['unfold "only here"']);
  await key('Tab');
  assert.equal(await cdp.evaluate(`document.querySelector('#undo-reader .config-command input').value`), 'unfold "only here"');
  await key('Enter');
  await waitFor(async () => (await readFile(nestedFile, 'utf8')).startsWith('#fold "only here"'));
  await cdp.evaluate('window.undoReader.stop()');
  await commandSuggestions('#config .config-command input', '');
  await search('fold c.folder.child');
  const shot = await cdp.send('Page.captureScreenshot', {format: 'png'}); await writeFile(output, Buffer.from(shot.data, 'base64'));
  assert.deepEqual(failures, []);
  console.log('Config graph navigation, search, autocomplete, label renaming, branch merges, stale edits, subtree actions, and synchronized views passed.');
  console.log(output);
} catch (error) {
  console.error(await readFile(file, 'utf8').catch(() => ''));
  if (cdp) {
    console.error(await cdp.evaluate('JSON.stringify([...document.querySelectorAll(".config-document")].map(v=>({status:v.querySelector(".config-document-status").textContent,nodes:[...v.querySelectorAll(".node")].map(n=>({id:n.dataset.node,classes:n.getAttribute("class")}))})))'));
    const shot = await cdp.send('Page.captureScreenshot', {format: 'png'});
    await writeFile(output, Buffer.from(shot.data, 'base64'));
  }
  throw error;
} finally {
  socket?.close();
  if (chrome) { chrome.kill('SIGTERM'); await sleep(300); }
  if (server) { server.kill('SIGINT'); await sleep(500); }
  await rm(root, {recursive: true, force: true, maxRetries: 5, retryDelay: 200});
}
