import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, readFile, stat, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { once } from 'node:events';

const repo = resolve(import.meta.dirname, '..');
const root = await mkdtemp(join(tmpdir(), 'visualize-mcp-checks-'));
let server, mcp, chrome, ws;
let log = '', count = 0;
const check = (value, message) => { assert.ok(value, message); count++; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function until(fn) {
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    try { const value = await fn(); if (value) return value; } catch (_) {}
    await sleep(50);
  }
  throw new Error('timeout\n' + log);
}
try {
  await mkdir(join(root, 'bin'));
  await mkdir(join(root, 'project'));
  await writeFile(join(root, 'project', 'a.janet'), '(def a 1)\n');
  await writeFile(join(root, 'bin', 'open'), '#!/bin/sh\nprintf "%s" "$1" > "$VZ_TEST_URL"\n', { mode: 0o755 });
  await writeFile(join(root, 'bin', 'worker'), `#!/bin/sh
printf 'READY\\n'
IFS= read -r task
case "$task" in
  *' conversation'|conversation) printf 'READY\\n'; IFS= read -r line; printf 'GOT:%s\\n' "$line"; sleep 30 ;;
  *' environment') printf '%s\\n' "$VISUALIZE_SOCKET"; command -v vz ;;
  *' final') printf 'FINAL-SCREEN\\n' ;;
  *) exec /bin/cat ;;
esac
`, { mode: 0o755 });
  await writeFile(join(root, 'bin', 'login-shell'), '#!/bin/sh\n[ "$1" = -l ] && [ "$2" = -i ] || exit 90\nshift 2\nexec /bin/bash "$@"\n', { mode: 0o755 });
  function startServer() {
    server = spawn(join(repo, 'external-src/janet/janet'), [join(repo, 'src.server/core.janet'), join(root, 'project'), '--no-dev', '--default-harness', 'worker', '--command', 'printf "start\\n" >> "$VZ_STARTS"; exec /bin/cat'], {
      cwd: repo, stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...process.env, SHELL: join(root, 'bin', 'login-shell'), PATH: join(root, 'bin') + ':' + process.env.PATH, VZ_TEST_URL: join(root, 'url'), VZ_STARTS: join(root, 'starts') },
    });
    for (const stream of [server.stdout, server.stderr]) stream.on('data', b => { log += b; });
  }
  startServer();
  const starts = async () => (await readFile(join(root, 'starts'), 'utf8')).trim().split('\n').length;
  const url = await until(() => readFile(join(root, 'url'), 'utf8'));
  check(await until(async () => await starts() === 1), 'cold start invokes once before browser attachment');
  const endpoint = await until(() => log.match(/^mcp: .*?visualize-mcp (.+)$/m)?.[1]);
  check(((await stat(endpoint)).mode & 0o077) === 0, 'control socket is private');
  mcp = spawn(join(repo, 'visualize-mcp'), [endpoint], { cwd: root, stdio: ['pipe', 'pipe', 'pipe'] });
  mcp.stderr.on('data', b => { log += b; });
  let serial = 0, pending = '', orphan;
  const requests = new Map();
  mcp.stdout.on('data', b => {
    pending += b;
    while (pending.includes('\n')) {
      const at = pending.indexOf('\n'), line = pending.slice(0, at); pending = pending.slice(at + 1);
      try {
        const reply = JSON.parse(line);
        const resolve = requests.get(reply.id);
        if (resolve) { requests.delete(reply.id); resolve(reply); } else orphan?.(reply);
      } catch (error) { log += '\nInvalid MCP output: ' + line; }
    }
  });
  const rpc = (method, params) => {
    const id = ++serial;
    return Promise.race([new Promise(resolve => {
      requests.set(id, resolve);
      mcp.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
    }), new Promise((_, reject) => { const timer = setTimeout(() => reject(new Error('MCP timeout: ' + method + '\n' + log)), 30000); timer.unref(); })]);
  };
  const invoke = (name, args = {}) => rpc('tools/call', { name, arguments: args });
  const tool = async (name, args = {}) => {
    const reply = await invoke(name, args);
    assert.equal(reply.error, undefined, JSON.stringify(reply));
    assert.equal(reply.result.isError, false, JSON.stringify(reply));
    return reply.result.structuredContent;
  };
  check((await rpc('tools/list')).error.code === -32000, 'requires initialization');
  check((await rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'checks', version: '1' } })).result.protocolVersion === '2025-06-18', 'initialize');
  mcp.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n');
  check((await rpc('tools/list')).result.tools.length === 5, 'five tools');
  for (const name of ['worker_open', 'pane_list', 'pane_read', 'pane_send', 'pane_close', 'pane_capture', 'pane_wait', 'pane_prompt', 'pane_type', 'pane_submit', 'pane_interrupt', 'pane_title']) {
    check((await invoke(name)).error.code === -32602, name + ' removed');
  }
  check((await rpc('ping')).result, 'ping');
  check((await rpc('unknown')).error.code === -32601, 'unknown method');
  check((await invoke('unknown')).error.code === -32602, 'unknown tool');
  check((await invoke('send_message', { id: 'x' })).error.code === -32602, 'missing arguments');
  for (const line of ['{broken}', '{"jsonrpc":"2.0","id":99,"method":"ping"} trailing', '"unfinished']) {
    const reply = new Promise(resolve => { orphan = resolve; });
    mcp.stdin.write(line + '\n');
    check((await reply).error.code === -32700, 'malformed JSON rejected');
  }
  check((await tool('list_agents')).project === await import('node:fs').then(m => m.realpathSync(join(root, 'project'))), 'attached project');
  check((await invoke('read_agent', { id: 'missing' })).result.isError, 'unknown pane does not create a supervisor');
  check((await invoke('pane_open', { argv: ['/bin/cat'] })).error.code === -32602, 'arbitrary terminal tool removed');
  check((await invoke('spawn_agent', { message: 'task', title: 'Task', argv: ['/bin/cat'] })).error.code === -32602, 'worker cannot override executable');
  check((await invoke('spawn_agent', { message: '', title: 'Task' })).result.isError, 'empty task rejected');
  check((await invoke('spawn_agent', { message: 'task', title: 'Task', rows: 0 } )).error.code === -32602, 'dimensions are not API arguments');
  const userPost = async (id, op, body = {}) => {
    const key = (await (await fetch(url + '/session')).json()).token;
    const response = await fetch(url + '/pane/' + id + '/' + op + '?k=' + key, { method: 'POST', body: JSON.stringify(body) });
    const result = await response.json();
    assert.ok(response.ok && !result.error, JSON.stringify(result));
    return result;
  };
  check((await invoke('spawn_agent', { message: 'task', title: 'bad\nname' })).result.isError, 'multiline title rejected');
  const pendingPrompt = await tool('spawn_agent', { title: 'Needs inspection', message: 'two\nlines' });
  check(pendingPrompt.promptSent === false && !!pendingPrompt.promptError, 'unsupported initial paste reports non-delivery');
  check((await tool('read_agent', { id: pendingPrompt.id })).running, 'failed initial delivery preserves worker');
  await tool('send_message', { id: pendingPrompt.id, message: 'conversation' });
  await tool('close_agent', { id: pendingPrompt.id });
  const opened = await tool('spawn_agent', { message: 'conversation', title: 'Verification' });
  check(opened.promptSent === true, 'initial task delivered through terminal input: ' + JSON.stringify(opened));
  const identity = { id: opened.id };
  check(!('generation' in opened), 'worker result omits generations');
  check((await tool('list_agents')).workers.every(p => !('generation' in p)), 'list omits generations');
  check(!('generation' in await tool('read_agent', identity)), 'read omits generations');
  check((await tool('list_agents')).workers.some(p => p.id === opened.id && p.title === 'Verification'), 'worker title listed');
  const capture = () => tool('read_agent', { id: opened.id });
  await until(async () => (await capture()).text.includes('READY'));
  check((await tool('list_agents')).workers.some(p => p.id === opened.id && p.cwd.endsWith('/project')), 'opened pane listed');
  check((await invoke('send_message', { ...identity, message: 'bad\u001b' })).result.isError, 'prompt mode rejects raw control characters');
  await tool('send_message', { ...identity, message: 'hello 🚀', raw: true });
  await sleep(150);
  check(!(await capture()).text.includes('GOT:'), 'type does not press Enter');
  const before = await capture();
  const waiting = tool('read_agent', { ...identity, revision: before.revision, timeout_ms: 3000 });
  await tool('send_message', { ...identity, message: '\r', raw: true });
  check((await waiting).reason === 'output', 'wait allows concurrent submission');
  await until(async () => (await capture()).text.includes('GOT:hello 🚀'));
  const quiet = await capture();
  check((await tool('read_agent', { ...identity, revision: quiet.revision, timeout_ms: 100 })).reason === 'timeout', 'bounded timeout');
  await tool('send_message', { ...identity, message: '\u0003', raw: true });
  await until(async () => !(await capture()).running);
  check((await tool('read_agent', { ...identity, revision: (await capture()).revision, timeout_ms: 100 })).reason === 'exit', 'exit observation');
  const token = (await (await fetch(url + '/session')).json()).token;
  const replaced = await (await fetch(url + '/pane/' + opened.id + '/start?k=' + token, { method: 'POST', body: '{}' })).json();
  check(replaced.running, 'session replaced in the same pane');
  check((await invoke('close_agent', identity)).result.isError, 'manual replacement revokes ownership');
  const environment = await tool('spawn_agent', { message: 'environment', title: 'Environment', cwd: '..' });
  const environmentScreen = await until(async () => {
    const screen = await tool('read_agent', { id: environment.id });
    return !screen.running && screen.text.includes('/vz') && screen;
  });
  check(environmentScreen.text.includes(endpoint), 'pane inherits its control socket');
  check(environment.cwd === await import('node:fs').then(m => m.realpathSync(root)), 'project-relative cwd');
  check(!(await tool('list_agents')).workers.some(p => p.id === environment.id), 'exited workers omitted from list');
  await tool('close_agent', { id: environment.id });
  const exited = await tool('spawn_agent', { message: 'final', title: 'Final report' });
  await until(async () => !(await tool('read_agent', { id: exited.id })).running);
  chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', ['--headless=new', '--no-first-run', '--no-default-browser-check', '--remote-debugging-port=0', '--user-data-dir=' + join(root, 'chrome'), 'about:blank'], { stdio: 'ignore' });
  const port = (await until(() => readFile(join(root, 'chrome', 'DevToolsActivePort'), 'utf8'))).split('\n')[0];
  const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  ws = new WebSocket(targets.find(t => t.type === 'page').webSocketDebuggerUrl);
  await new Promise(resolve => ws.addEventListener('open', resolve, { once: true }));
  let cdpId = 0;
  const cdpPending = new Map(), browserErrors = [];
  ws.addEventListener('message', e => { const m = JSON.parse(e.data); cdpPending.get(m.id)?.(m); if (m.method === 'Runtime.exceptionThrown') browserErrors.push(m.params); });
  const cdp = (method, params = {}) => new Promise(resolve => { const id = ++cdpId; cdpPending.set(id, resolve); ws.send(JSON.stringify({ id, method, params })); });
  const evaluate = async expression => { const reply = await cdp('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }); assert.ok(!reply.result.exceptionDetails, JSON.stringify(reply)); return reply.result.result.value; };
  await cdp('Runtime.enable');
  await cdp('Page.navigate', { url });
  await until(() => evaluate(`!!document.getElementById('pane-${exited.id}')`));
  check(await evaluate(`document.getElementById('pane-${exited.id}').dataset.rail === 'bottom' && document.getElementById('pane-${exited.id}').classList.contains('shut')`), 'recovered MCP pane is collapsed on the bottom rail');
  check(!(await tool('read_agent', { id: exited.id })).running, 'browser preserves exited command');
  check((await tool('read_agent', { id: exited.id })).text.includes('FINAL-SCREEN'), 'final screen preserved');
  const live = await tool('spawn_agent', { title: 'Worker' });
  check(live.promptSent === true, 'role-only introduction delivered: ' + JSON.stringify(live));
  await tool('send_message', { id: live.id, message: 'Follow-up task' });
  await until(async () => (await tool('read_agent', { id: live.id })).text.replace(/\s/g, '').includes('Follow-uptask'));
  check((await invoke('send_message', { id: live.id, message: 'bad\u001b[201~' })).result.isError, 'prompt rejects terminal control injection');
  check((await invoke('send_message', { id: live.id, message: 'two\nlines' })).result.isError, 'multiline requires bracketed paste');
  await until(() => evaluate(`!!document.getElementById('pane-${live.id}')`));
  check(await evaluate(`document.getElementById('pane-${live.id}').dataset.rail === 'bottom' && document.getElementById('pane-${live.id}').classList.contains('shut')`), 'new MCP pane appears collapsed on the bottom rail');
  check(await evaluate(`document.getElementById('pane-${live.id}').offsetWidth === document.getElementById('config').offsetWidth`), 'Computer tab starts at Visualize width');
  await until(() => evaluate(`document.getElementById('pane-${live.id}').querySelector('.label').textContent === 'Worker'`));
  await cdp('Page.reload');
  await until(() => evaluate(`document.getElementById('pane-${live.id}')?.querySelector('.label').textContent === 'Worker'`));
  check(true, 'creation titles survive reload');
  await tool('close_agent', { id: live.id });
  await until(() => evaluate(`!document.getElementById('pane-${live.id}')`));
  check(true, 'MCP close removes browser tab');
  const regular = await evaluate("import('/panes.js').then(m => m.openTerminal().root.id.slice(5))");
  const regularState = await until(async () => { const state = await userPost(regular, 'start'); return state.running && state; });
  check(!(await tool('list_agents')).workers.some(p => p.id === regular), 'user sessions omitted from list');
  check((await invoke('read_agent', { id: regular })).result.isError, 'user sessions cannot be read');
  await sleep(200);
  check(regularState.argv.length === 3 && regularState.argv[1] === '-l' && regularState.argv[2] === '-i', 'manual tab opens plain login shell');
  check((await invoke('close_agent', { id: regular })).result.isError, 'user tab cannot be closed by Computer');
  check((await invoke('send_message', { id: regular, message: 'Do work' })).result.isError, 'prompting is restricted to owned workers');
  await userPost(regular, 'shutdown');
  await until(() => evaluate(`!document.getElementById('pane-${regular}')`));
  check(true, 'user can still close a protected pane');
  await userPost(identity.id, 'shutdown');
  await tool('close_agent', { id: exited.id });
  check(!(await tool('list_agents')).workers.some(p => p.id.startsWith('agent-')), 'closed panes removed');
  check(browserErrors.length === 0, 'no browser exceptions: ' + JSON.stringify(browserErrors));
  const baseline = await starts();
  const harnessBefore = await userPost('harness', 'capture');
  check(!(await tool('list_agents')).workers.some(p => p.id === 'harness'), 'coordinator omitted from API listing');
  for (const [op, args] of [['read_agent', {}], ['send_message', { message: '\u0003', raw: true }], ['close_agent', {}]]) {
    check((await invoke(op, { id: 'harness', ...args })).result.isError, 'coordinator rejects direct ' + op);
  }
  for (let reload = 0; reload < 2; reload++) {
    await cdp('Page.reload');
    await until(() => evaluate("!!document.querySelector('#harness textarea')"));
    await sleep(150);
  }
  check((await userPost('harness', 'capture')).generation === harnessBefore.generation, 'page reload reattaches the original session');
  check(await starts() === baseline, 'page reload never reruns startup');
  const freshToken = (await (await fetch(url + '/session')).json()).token;
  const panePost = async (op, body = {}) => (await fetch(url + '/pane/700/' + op + '?k=' + freshToken, { method: 'POST', body: JSON.stringify(body) })).json();
  const ordinary = await panePost('start');
  await panePost('input', { text: 'RECOVER-REGULAR\r', generation: ordinary.generation });
  await until(async () => (await userPost('700', 'capture')).text.includes('RECOVER-REGULAR'));
  await panePost('stop');
  check((await invoke('close_agent', { id: 'harness' })).result.isError, 'coordinator is protected');
  await userPost('harness', 'shutdown');
  const saved = await userPost('700', 'capture');
  const ownedRecovery = await tool('spawn_agent', { message: 'wait', title: 'Keep across restart' });
  const beforeRecovery = await starts();
  async function restart() {
    const done = once(server, 'exit'); server.kill('SIGTERM'); await done;
    await rm(join(root, 'url'), { force: true });
    startServer();
    assert.equal(await until(() => readFile(join(root, 'url'), 'utf8')), url);
  }
  await restart();
  const recoveredList = await tool('list_agents');
  check(recoveredList.workers.some(p => p.id === ownedRecovery.id && p.title === 'Keep across restart'), 'ownership and title survive server restart');
  await tool('close_agent', { id: ownedRecovery.id });
  check((await tool('list_agents')).workers.length === 0 && !recoveredList.workers.some(p => p.id === '700'), 'recovered user sessions remain outside the worker API');
  await cdp('Page.reload');
  await until(() => evaluate("!!document.querySelector('#pane-700 textarea')"));
  await sleep(200);
  check(await evaluate("!document.getElementById('harness')"), 'browser has no phantom harness after recovery');
  const recovered = await userPost('700', 'capture');
  check(!recovered.running && recovered.text.includes('RECOVER-REGULAR'), 'ordinary exited pane keeps its final screen');
  check(await starts() === beforeRecovery, 'server restart and browser attachment do not invoke startup when any pane survives');
  await userPost('700', 'shutdown');
  await restart();
  check(await until(async () => await starts() === beforeRecovery + 1), 'empty recovery invokes startup once');
  await until(() => evaluate("!!document.querySelector('#harness textarea')"));
  check(true, 'browser reconnect discovers the new harness without a page reload');
  check(await starts() === beforeRecovery + 1, 'browser attachment does not duplicate cold startup');
  const cli = spawn(join(repo, 'vz'), ['--socket', endpoint, 'list_agents'], { cwd: root });
  let cliOut = ''; cli.stdout.on('data', b => { cliOut += b; });
  check((await once(cli, 'exit'))[0] === 0 && JSON.parse(cliOut).workers.length === 0, 'CLI uses same API');
  mcp.stdin.end();
  check((await once(mcp, 'exit'))[0] === 0, 'clean MCP EOF');
  mcp = null;
  server.kill('SIGINT');
  await once(server, 'exit'); server = null;
  check(!(await stat(endpoint).catch(() => null)), 'control socket removed on shutdown');
  console.log(JSON.stringify({ passed: count }));
} catch (error) {
  console.error(log);
  console.error({ serverExit: server?.exitCode, signal: server?.signalCode });
  throw error;
} finally {
  ws?.close(); mcp?.kill('SIGTERM'); chrome?.kill('SIGTERM');
  if (server) { const done = once(server, 'exit'); server.kill('SIGINT'); await Promise.race([done, sleep(3000)]); }
  await sleep(200);
  await rm(root, { recursive: true, force: true }).catch(() => {});
}
