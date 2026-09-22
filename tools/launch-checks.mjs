import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, readFile, readdir, rm, cp, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve, relative } from 'node:path';
import { once } from 'node:events';

const repo = resolve(import.meta.dirname, '..');
const root = await mkdtemp(join(tmpdir(), 'visualize-launch-checks-'));
const project = join(root, 'project with spaces');
let server, request, page, logs = '', count = 0;
const sleep = ms => new Promise(r => setTimeout(r, ms));
const check = (value, message) => { assert.ok(value, message); count++; };
const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";
async function until(fn) {
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    try { const value = await fn(); if (value) return value; } catch (_) {}
    await sleep(50);
  }
  throw new Error('timeout\n' + logs);
}
async function run(command, args, options = {}) {
  const child = spawn(command, args, { cwd: repo, ...options, stdio: ['ignore', 'pipe', 'pipe'] });
  let stdout = '', stderr = '';
  child.stdout.on('data', b => { stdout += b; }); child.stderr.on('data', b => { stderr += b; });
  const [code] = await once(child, 'exit');
  assert.equal(code, 0, stderr + stdout);
  return stdout;
}
async function stop(signal) {
  if (!server) return;
  const done = once(server, 'exit'); server.kill(signal); await done; server = null;
}
try {
  await mkdir(project);
  await mkdir(join(root, 'bin'));
  await mkdir(join(root, 'records'));
  await writeFile(join(project, 'a.janet'), '(def a 1)\n');
  await writeFile(join(root, 'bin', 'open'), '#!/bin/sh\nprintf "%s" "$1" > "$VZ_TEST_URL"\n', { mode: 0o755 });
  await writeFile(join(root, 'bin', 'login-shell'), '#!/bin/sh\n[ "$1" = -l ] && [ "$2" = -i ] || exit 90\nshift 2\nexport VZ_TEST_LOGIN=loaded\nexec /bin/bash "$@"\n', { mode: 0o755 });
  await writeFile(join(root, 'record.cjs'), `const fs = require('node:fs');
const env = process.env;
fs.writeFileSync(env.VZ_TEST_RECORDS + '/' + env.VISUALIZE_PANE_ID + '.json', JSON.stringify({
  args: process.argv.slice(2), cwd: process.cwd(), login: env.VZ_TEST_LOGIN,
  pane: env.VISUALIZE_PANE_ID, project: env.VISUALIZE_PROJECT,
  socket: env.VISUALIZE_SOCKET, command: env.VISUALIZE_MAIN_HARNESS_COMMAND,
  startupPrompt: env.VISUALIZE_STARTUP_PROMPT, startupPromptJSON: env.VISUALIZE_STARTUP_PROMPT_JSON,
}));
if (env.VZ_TEST_EXIT) process.exit(0);
process.stdin.setRawMode?.(true);
process.stdin.resume();
let input = '';
process.stdin.on('data', b => {
  input += b;
  const colorAt = input.indexOf('rgb:');
  if (colorAt >= 0 && input.length >= colorAt + 18) {
    const path = env.VZ_TEST_RECORDS + '/' + env.VISUALIZE_PANE_ID + '.json';
    const record = JSON.parse(fs.readFileSync(path));
    record.background = input.slice(colorAt + 4, colorAt + 18);
    fs.writeFileSync(path, JSON.stringify(record));
  }
  const end = input.indexOf('\\x1b[201~');
  if (end < 0) return;
  const start = input.indexOf('\\x1b[200~');
  const path = env.VZ_TEST_RECORDS + '/' + env.VISUALIZE_PANE_ID + '.json';
  const record = JSON.parse(fs.readFileSync(path));
  record.prompt = input.slice(start + 6, end);
  input = input.slice(end + 6);
  fs.writeFileSync(path, JSON.stringify(record));
});
console.log('\\x1b]11;?\\x1b\\\\\\x1b[?2004hINVOCATION-READY');
setInterval(() => {}, 1000);
`);
  await writeFile(join(root, 'bin', 'codex'), '#!/bin/sh\nexec ' + quote(process.execPath) + ' ' + quote(join(root, 'record.cjs')) + ' "$@"\n', { mode: 0o755 });
  const env = { ...process.env, PATH: join(root, 'bin') + ':' + process.env.PATH,
    SHELL: join(root, 'bin', 'login-shell'), VZ_TEST_URL: join(root, 'url'), VZ_TEST_RECORDS: join(root, 'records') };
  async function start(args = []) {
    await rm(join(root, 'url'), { force: true });
    server = spawn(join(repo, 'visualize'), [project, '--no-dev', ...args], { cwd: repo, env, stdio: ['ignore', 'pipe', 'pipe'] });
    for (const stream of [server.stdout, server.stderr]) stream.on('data', b => { logs += b; });
    const url = await until(() => readFile(join(root, 'url'), 'utf8'));
    const token = (await (await fetch(url + '/session')).json()).token;
    page = () => fetch(url).then(response => response.text());
    request = async (path, body = {}) => {
      const response = await fetch(url + path + '?k=' + token, { method: 'POST', body: JSON.stringify(body) });
      const result = await response.json();
      assert.ok(response.ok && !result.error, JSON.stringify(result));
      return result;
    };
    return (id, op, body) => request('/pane/' + id + '/' + op, body);
  }
  let post = await start();
  check(/^@visualize terminal config placement top 0$/m.test(await readFile(join(project, 'visualize_config'), 'utf8')), 'cold startup saves the default editor before a browser connects');
  await stop('SIGTERM');
  post = await start();
  const recoveredBeforeBrowser = await page();
  check(recoveredBeforeBrowser.includes('window.START_EMPTY = false;') &&
    JSON.parse(recoveredBeforeBrowser.match(/window.PANE_POSITIONS = (.*);/)[1]).config?.[0] === 'top', 'restart before the first browser visit preserves the default editor');
  const original = await post('harness', 'capture');
  const record = await until(async () => JSON.parse(await readFile(join(root, 'records/harness.json'), 'utf8')));
  check(record.login === 'loaded', 'login shell setup precedes invocation');
  check(record.cwd.endsWith('/project with spaces'), 'harness cwd is the attached project');
  check(record.pane === 'harness', 'main harness has a pane identity');
  check(record.args.length === 2 && record.args[0] === '-c' && record.args[1].startsWith('developer_instructions='), 'default harness only adds startup instructions');
  check(JSON.parse(record.args[1].slice('developer_instructions='.length)) === record.startupPrompt, 'startup instructions arrive intact');
  check(record.startupPrompt.includes('Example plan.visualize:\nShip_search\n    Implement_search'), 'startup prompt includes the plan example');
  check(record.startupPrompt.includes('Paths are relative to the project root'), 'startup prompt explains file reference resolution');
  check(record.command.includes('VISUALIZE_STARTUP_PROMPT_JSON'), 'vz receives the configured invocation');
  check((await post('harness', 'capture')).running, 'main harness remains running');
  check((await readdir(project)).every(name => ['a.janet', 'visualize_config'].includes(name)), 'no harness settings written to the project');
  await run(join(repo, 'vz'), [], {env: {...env, VISUALIZE_MAIN_HARNESS_COMMAND: record.command, VISUALIZE_STARTUP_PROMPT_JSON: record.startupPromptJSON, VISUALIZE_PANE_ID: 'cli', VZ_TEST_EXIT: '1'}});
  const cli = JSON.parse(await readFile(join(root, 'records/cli.json'), 'utf8'));
  check(JSON.stringify(cli.args) === JSON.stringify(record.args) && cli.login === 'loaded', 'vz without arguments includes the same startup prompt after login setup');
  await run(join(repo, 'vz'), [join(project, 'a.janet')], {env: {...env, VISUALIZE_SOCKET: record.socket, VISUALIZE_PANE_ID: 'harness'}});
  const {createConnection} = await import('node:net');
  async function control(op) {
    return new Promise((resolve, reject) => {
      const socket = createConnection(record.socket); let text = '';
      socket.on('connect', () => socket.write(JSON.stringify({op, args:{}}) + '\n'));
      socket.on('error', reject);
      socket.on('data', chunk => { text += chunk; if (text.includes('\n')) { socket.end(); resolve(JSON.parse(text)); } });
    });
  }
  check((await control('spawn_agent')).error === 'unknown document operation', 'document socket exposes no worker creation');
  const second = await post('2', 'start');
  const positions = {harness: ['bottom', 2, 640, 480], '2': ['floating', -15, 70, 350, 420]};
  await request('/panes/placements', positions);
  await request('/label', {id: 'harness', text: 'Project "work"'});
  const beforeRecovery = await request('/panes/watch', {generation: -1});
  const saved = await readFile(join(project, 'visualize_config'), 'utf8');
  const harnessLine = saved.split('\n').filter(line => line.startsWith('@visualize terminal harness '));
  check(harnessLine.length === 1 && harnessLine[0].includes(' placement bottom 2 640 480 label "Project \\"work\\"" document '), 'socket, placement, label, and document share one terminal line');
  check(!/@visualize (placement|label|markdown) /.test(saved), 'saves contain no split metadata records');
  await stop('SIGTERM');
  await rm(join(root, 'records/harness.json'));
  const script = 'values=("argument with spaces" "literal quote")\nexec codex "${values[@]}"';
  post = await start(['--command', script]);
  check((await post('harness', 'capture')).generation === original.generation, 'recovery preserves the running harness');
  check(!(await readdir(join(root, 'records'))).includes('harness.json'), 'recovery does not invoke the new startup command');
  check((await post('2', 'capture')).generation === second.generation, 'floating terminal survives restart');
  const restoredPage = await page();
  check(!JSON.parse(restoredPage.match(/window.PANE_POSITIONS = (.*);/)[1]).config, 'a closed editor remains closed when terminals are recovered');
  check(JSON.stringify(JSON.parse(restoredPage.match(/window.PANE_POSITIONS = (.*);/)[1])) === JSON.stringify(Object.fromEntries(Object.entries(positions).sort())), 'restart restores rail and floating positions and sizes');
  check(JSON.parse(restoredPage.match(/window.PANE_LABELS = (.*);/)[1]).harness === 'Project "work"', 'restart restores the quoted title');
  const recovered = await request('/panes/watch', {generation: -1});
  check(JSON.stringify(recovered.documents) === JSON.stringify(beforeRecovery.documents), 'restart restores the document associated with the terminal');
  const replacement = await post('harness', 'start');
  check(replacement.generation > original.generation, 'manual restart reuses the supervisor');
  check(!(await readdir(join(root, 'records'))).includes('harness.json'), 'manual restart opens a plain shell');
  await stop('SIGINT');
  post = await start(['--command', script]);
  const updated = await until(async () => JSON.parse(await readFile(join(root, 'records/harness.json'), 'utf8')));
  check(updated.args[0] === 'argument with spaces' && updated.args[1] === 'literal quote', 'custom Bash invocation preserves arguments');
  check(updated.command === script, 'custom invocation is passed to vz');
  await run(join(repo, 'vz'), [], {env: {...env, VISUALIZE_MAIN_HARNESS_COMMAND: script, VISUALIZE_PANE_ID: 'custom-cli', VZ_TEST_EXIT: '1'}});
  const custom = JSON.parse(await readFile(join(root, 'records/custom-cli.json'), 'utf8'));
  check(JSON.stringify(custom.args) === JSON.stringify(updated.args), 'vz executes custom Bash scripts like cold startup');
  await stop('SIGINT');
  const restartApp = join(root, 'restart-app');
  await mkdir(restartApp);
  await cp(join(repo, 'src.server'), join(restartApp, 'src.server'), {recursive: true});
  for (const name of ['external-src', 'src', 'src.wterm', 'src.vterm', 'src.graphviz']) {
    await symlink(join(repo, name), join(restartApp, name), 'dir');
  }
  const graphPath = join(restartApp, 'src.server/graph.janet');
  await writeFile(graphPath, (await readFile(graphPath, 'utf8')).replace('(defn handle [op sent]', `(defn handle [op sent]
    (when (os/stat (string root "/block-graph"))
      (spit (string root "/graph-busy") "busy")
      (ev/sleep 60))`));
  await rm(join(root, 'url'), {force: true});
  const pidPath = join(root, 'restart.pid');
  const driver = join(root, 'restart-pty.janet');
  await writeFile(driver, `(import ${relative(root, join(repo, 'src.server/term/pty'))} :as pty)
(def session (pty/open (drop 1 (dyn *args*)) 24 100))
(ev/thread (fn [session]
  (pty/pump session (fn [chunk] (file/write stdout chunk) (file/flush stdout))) :done)
  session :nt (ev/thread-chan 1))
(defer (pty/close session)
  (forever
    (def byte (file/read stdin 1))
    (unless byte (break))
    (pty/write-input session byte)))
`);
  const terminal = spawn(join(repo, 'external-src/janet/janet'), [driver, '/bin/sh', '-c',
    'printf "%s" "$$" > "$1"; shift; exec "$@"', 'visualize-restart-test', pidPath,
    join(repo, 'external-src/janet/janet'), join(restartApp, 'src.server/core.janet'),
    project, '--no-dev', '--command', 'exec /bin/cat'], {cwd: repo, env, stdio: ['pipe', 'pipe', 'pipe']});
  let restartLog = '', restartPid, supervisorSocket;
  for (const stream of [terminal.stdout, terminal.stderr]) stream.on('data', b => { logs += b; restartLog += b; });
  try {
    restartPid = Number(await until(() => readFile(pidPath, 'utf8')));
    const url = await until(() => readFile(join(root, 'url'), 'utf8'));
    const session = () => fetch(url + '/session', {signal: AbortSignal.timeout(2000)}).then(r => r.json());
    const before = await session();
    const capture = token => fetch(url + '/pane/harness/capture?k=' + token, {
      method: 'POST', body: '{}', signal: AbortSignal.timeout(2000),
    }).then(r => r.json());
    const original = await capture(before.token);
    supervisorSocket = (await readFile(join(project, 'visualize_config'), 'utf8')).match(/^@visualize terminal harness socket (\S+)/m)?.[1];
    await writeFile(join(project, 'block-graph'), '');
    const pendingDraw = fetch(url, {signal: AbortSignal.timeout(10000)}).catch(() => null);
    await until(() => readFile(join(project, 'graph-busy'), 'utf8'));
    await rm(join(project, 'block-graph'));
    const began = Date.now();
    terminal.stdin.write('\x04');
    const recovered = await until(async () => { const next = await session(); return next.token !== before.token && next; });
    check(Date.now() - began < 10000, 'Ctrl-D restarts without waiting for an occupied graph worker');
    check(restartLog.includes('restarting server; terminal sessions kept'), 'Ctrl-D reaches the native terminal EOF handler');
    const restored = await capture(recovered.token);
    check(restored.running && restored.generation === original.generation, 'Ctrl-D preserves the running terminal session');
    check((await fetch(url, {signal: AbortSignal.timeout(5000)})).ok, 'the restarted graph serves the main page');
    terminal.stdin.write('\x04');
    const again = await until(async () => { const next = await session(); return next.token !== recovered.token && next; });
    check((await capture(again.token)).generation === original.generation, 'Ctrl-D works again after replacing the server process');
    await pendingDraw;
  } finally {
    if (restartPid) { try { process.kill(restartPid, 'SIGTERM'); } catch {} }
    if (supervisorSocket) {
      await new Promise(resolve => {
        const socket = createConnection(supervisorSocket);
        socket.setTimeout(2000);
        socket.on('connect', () => socket.write('{"op":"shutdown"}\n'));
        const finish = () => { socket.destroy(); resolve(); };
        socket.on('data', finish); socket.on('error', finish); socket.on('timeout', finish);
      });
    }
    terminal.stdin.end(); terminal.kill('SIGTERM');
  }
  console.log(JSON.stringify({passed: count}));
} catch (error) {
  console.error(logs);
  throw error;
} finally {
  await stop('SIGINT');
  await rm(root, {recursive: true, force: true});
}
