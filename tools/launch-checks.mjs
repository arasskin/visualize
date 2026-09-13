import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, readFile, readdir, realpath, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { once } from 'node:events';

const repo = resolve(import.meta.dirname, '..');
const root = await mkdtemp(join(tmpdir(), 'visualize-launch-checks-'));
const project = join(root, 'project with spaces');
let server, logs = '', count = 0;
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
  agentFile: env.VISUALIZE_AGENT_FILE, agent: env.VISUALIZE_AGENT_JSON,
  command: env.VISUALIZE_MCP_COMMAND, socket: env.VISUALIZE_SOCKET,
}));
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
    return async (id, op, body = {}) => {
      const response = await fetch(url + '/pane/' + id + '/' + op + '?k=' + token, { method: 'POST', body: JSON.stringify(body) });
      const result = await response.json();
      assert.ok(response.ok && !result.error, JSON.stringify(result));
      return result;
    };
  }
  let post = await start();
  const original = await post('harness', 'capture');
  const record = await until(async () => JSON.parse(await readFile(join(root, 'records/harness.json'), 'utf8')));
  const instructions = await readFile(join(repo, 'src.mcp/agent.md'), 'utf8');
  check(record.login === 'loaded', 'login shell setup precedes invocation');
  check(record.cwd.endsWith('/project with spaces'), 'harness cwd is the attached project');
  check(record.pane === 'harness', 'coordinator knows its own pane');
  check(record.args.length === 6 && [0, 2, 4].every(i => record.args[i] === '-c'), 'default command supplies runtime overrides');
  check(record.args[1] === 'agents.enabled=false', 'main harness disables native subagents');
  check(JSON.parse(record.args[3].slice('developer_instructions='.length)) === instructions, 'agent.md injected exactly');
  check(record.args[5].includes(JSON.stringify(record.socket)), 'MCP override names this instance');
  const settings = JSON.parse(await run('codex', [...record.args, 'mcp', 'get', 'visualize', '--json']));
  check(settings.transport.command === record.command && settings.transport.args[0] === record.socket, 'installed Codex accepts the inline MCP settings');
  check((await post('harness', 'capture')).running, 'default harness remains running');
  const ownFiles = await readdir(project);
  check(ownFiles.every(name => ['a.janet', 'visualize.conf'].includes(name)), 'no harness config or instruction files written to the project');
  const customFile = join(root, "agent 'quoted' $name.md");
  const workerRole = (await readFile(join(repo, 'src.mcp/worker.md'), 'utf8')).trim();
  const customText = '# Test role\nKeep "quotes", $(touch ' + join(root, 'must-not-exist') + '), `false`, backslashes \\ and 🚀 literally.\n';
  await writeFile(customFile, customText);
  await stop('SIGTERM');
  await rm(join(root, 'records/harness.json'));
  const script = 'values=("argument with spaces" "literal \'quote\'")\nexec codex "${values[@]}" "$(cat "$VISUALIZE_AGENT_FILE")"';
  post = await start(['--command', script, '--agent', customFile]);
  check((await post('harness', 'capture')).generation === original.generation, 'recovery does not invoke the new startup command');
  check(!(await readdir(join(root, 'records'))).includes('harness.json'), 'recovery leaves the invocation untouched');
  const replacement = await post('harness', 'start');
  check(replacement.generation > original.generation, 'manual restart reuses supervisor');
  check(!(await readdir(join(root, 'records'))).includes('harness.json'), 'manual restart opens a shell without invoking Codex');
  await post('harness', 'shutdown');
  await stop('SIGINT');
  post = await start(['--command', script, '--agent', customFile]);
  const fresh = await post('harness', 'capture');
  const updated = await until(async () => JSON.parse(await readFile(join(root, 'records/harness.json'), 'utf8')));
  check(updated.args[0] === 'argument with spaces' && updated.args[1] === "literal 'quote'", 'CLI override runs Bash array syntax without splitting');
  check(updated.args[2] === customText.replace(/\n+$/, ''), 'custom instruction file injected without shell reinterpretation');
  check(JSON.parse(updated.agent) === customText && updated.agentFile === await realpath(customFile), 'cold startup receives custom launch environment');
  check(!(await readdir(root)).includes('must-not-exist'), 'instruction text cannot execute shell substitutions');
  const list = JSON.parse(await run(join(repo, 'vz'), ['--socket', updated.socket, 'list_agents']));
  check(!list.workers.some(p => p.id === 'harness'), 'MCP excludes the coordinator after recovery');
  await post('harness', 'theme', { theme: { foreground: 0xe6e6e6, background: 0x212734 } });
  const child = JSON.parse(await run(join(repo, 'vz'), ['--socket', updated.socket, 'spawn_agent', JSON.stringify({ title: 'Worker', message: customText })]));
  check(child.promptSent === true, 'initial prompt was sent');
  const childRecord = await until(async () => { const r = JSON.parse(await readFile(join(root, 'records', child.id + '.json'), 'utf8')); return r.prompt === workerRole + ' ' + customText && r; });
  check(childRecord.background === '2121/2727/3434', 'worker receives the active dark theme before its startup color query');
  check(childRecord.args.length === 0 && childRecord.prompt === workerRole + ' ' + customText, 'default worker receives a multiline task through terminal paste, with no CLI arguments');
  await run(join(repo, 'vz'), ['--socket', updated.socket, 'send_message', JSON.stringify({ id: child.id, message: 'Follow up\nwith details 🚀' })]);
  await until(async () => JSON.parse(await readFile(join(root, 'records', child.id + '.json'), 'utf8')).prompt === 'Follow up\nwith details 🚀');
  check(true, 'follow-up prompt uses the same generic terminal interface');
  check(childRecord.pane === child.id && childRecord.pane !== updated.pane, 'workers receive their own pane identity');
  check(childRecord.socket === updated.socket && JSON.parse(childRecord.agent) === customText, 'workers inherit the active instance context');
  await run(join(repo, 'vz'), ['--socket', updated.socket, 'close_agent', JSON.stringify({ id: child.id })]);
  await stop('SIGTERM');
  const alternate = join(root, 'bin', 'another harness');
  await writeFile(alternate, '#!/bin/sh\nexec ' + quote(process.execPath) + ' ' + quote(join(root, 'record.cjs')) + ' "$@"\n', { mode: 0o755 });
  post = await start(['--default-harness', alternate]);
  await post('harness', 'theme', { theme: { foreground: 0x3a4851, background: 0xffffff } });
  const override = JSON.parse(await run(join(repo, 'vz'), ['--socket', updated.socket, 'spawn_agent', JSON.stringify({ title: 'Override', message: 'Investigate lag' })]));
  const overrideRecord = await until(async () => { const r = JSON.parse(await readFile(join(root, 'records', override.id + '.json'), 'utf8')); return r.prompt === workerRole + ' Investigate lag' && r; });
  check(overrideRecord.background === 'ffff/ffff/ffff', 'later worker receives the active light theme before startup');
  check(overrideRecord.args.length === 0 && overrideRecord.prompt === workerRole + ' Investigate lag', 'CLI overrides default worker harness after recovery');
  await run(join(repo, 'vz'), ['--socket', updated.socket, 'close_agent', JSON.stringify({ id: override.id })]);
  await stop('SIGINT');
  console.log(JSON.stringify({ passed: count }));
} finally {
  await stop('SIGINT');
  await rm(root, { recursive: true, force: true });
}
