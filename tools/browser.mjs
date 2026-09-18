import {spawn} from 'node:child_process';
import {mkdir, readFile} from 'node:fs/promises';
import {join} from 'node:path';
import {setTimeout as sleep} from 'node:timers/promises';

export async function waitFor(fn, ms = 15000) {
  const end = Date.now() + ms;
  let error;
  while (Date.now() < end) {
    try { const value = await fn(); if (value) return value; } catch (e) { error = e; }
    await sleep(50);
  }
  throw new Error(`Timed out: ${fn}\n${error?.stack || ''}`);
}

export async function stopProcess(child, signal = 'SIGTERM') {
  if (!child || child.exitCode !== null || child.signalCode) return;
  const exited = new Promise(resolve => child.once('exit', resolve));
  child.kill(signal);
  const timer = setTimeout(() => child.kill('SIGKILL'), 5000);
  try { await exited; } finally { clearTimeout(timer); }
}

export async function browser(engine, root) {
  const firefox = engine === 'firefox', errors = [], logs = [];
  const profile = join(root, engine);
  await mkdir(profile);
  const executable = firefox ? process.env.FIREFOX || '/Applications/Firefox.app/Contents/MacOS/firefox'
    : process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
  const child = spawn(executable, firefox
    ? ['--headless', '--no-remote', '--profile', profile, '--remote-debugging-port', '0', 'about:blank']
    : ['--headless=new', '--no-first-run', '--no-default-browser-check', '--disable-background-timer-throttling',
      '--disable-renderer-backgrounding', '--remote-debugging-port=0', '--user-data-dir=' + profile, 'about:blank'],
  {stdio: ['ignore', 'pipe', 'pipe']});
  child.on('error', error => logs.push(String(error)));
  child.stdout.on('data', data => logs.push(String(data)));
  child.stderr.on('data', data => logs.push(String(data)));
  let socket;
  try {
    let address;
    if (firefox) address = await waitFor(() => logs.join('').match(/WebDriver BiDi listening on (ws:\/\/[^\s]+)/)?.[1], 60000);
    else {
      const port = (await waitFor(() => readFile(join(profile, 'DevToolsActivePort'), 'utf8'), 60000)).split('\n')[0];
      const pages = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
      address = pages.find(page => page.type === 'page').webSocketDebuggerUrl;
    }
    socket = new WebSocket(firefox ? address.replace(/\/$/, '') + '/session' : address);
    await new Promise((resolve, reject) => {
      socket.addEventListener('open', resolve, {once: true});
      socket.addEventListener('error', reject, {once: true});
    });
    let serial = 0, context;
    const pending = new Map();
    socket.addEventListener('message', event => {
      const message = JSON.parse(event.data);
      if (message.id) {
        const ticket = pending.get(message.id);
        if (!ticket) return;
        pending.delete(message.id); clearTimeout(ticket.timer);
        message.error ? ticket.reject(new Error(JSON.stringify(message))) : ticket.resolve(message.result);
      } else if (message.method === 'Runtime.exceptionThrown'
        || (message.method === 'Runtime.consoleAPICalled' && message.params.type === 'error')
        || (message.method === 'log.entryAdded' && message.params.level === 'error')) errors.push(message.params);
    });
    socket.addEventListener('close', () => {
      for (const ticket of pending.values()) { clearTimeout(ticket.timer); ticket.reject(new Error('Browser closed')); }
      pending.clear();
    });
    const send = (method, params = {}) => new Promise((resolve, reject) => {
      const id = ++serial;
      const timer = setTimeout(() => { pending.delete(id); reject(new Error(`Browser command timed out: ${method}`)); }, 15000);
      pending.set(id, {resolve, reject, timer}); socket.send(JSON.stringify({id, method, params}));
    });
    if (firefox) {
      await send('session.new', {capabilities: {}});
      context = (await send('browsingContext.getTree')).contexts[0].context;
      await send('session.subscribe', {events: ['log.entryAdded']});
    } else { await send('Runtime.enable'); await send('Page.enable'); }
    return {
      errors,
      async evaluate(expression) {
        const script = `(async()=>JSON.stringify(await eval(${JSON.stringify(expression)})))()`;
        const result = await send(firefox ? 'script.evaluate' : 'Runtime.evaluate', firefox
          ? {expression: script, target: {context}, awaitPromise: true}
          : {expression: script, awaitPromise: true, returnByValue: true});
        if (result.exceptionDetails || result.type === 'exception') throw new Error(JSON.stringify(result));
        return result.result.value === undefined ? undefined : JSON.parse(result.result.value);
      },
      async navigate(url) {
        await send(firefox ? 'browsingContext.navigate' : 'Page.navigate', firefox ? {context, url, wait: 'complete'} : {url});
      },
      async viewport(width, height) {
        await send(firefox ? 'browsingContext.setViewport' : 'Emulation.setDeviceMetricsOverride', firefox
          ? {context, viewport: {width, height}, devicePixelRatio: 1} : {width, height, deviceScaleFactor: 1, mobile: false});
      },
      async screenshot() {
        const result = await send(firefox ? 'browsingContext.captureScreenshot' : 'Page.captureScreenshot',
          firefox ? {context} : {format: 'png'});
        return Buffer.from(result.data, 'base64');
      },
      async drag(x, y, dx = 0, dy = 0) {
        x = Math.round(x); y = Math.round(y); dx = Math.round(dx); dy = Math.round(dy);
        if (firefox) {
          await send('input.performActions', {context, actions: [{type: 'pointer', id: 'mouse', parameters: {pointerType: 'mouse'},
            actions: [{type: 'pointerMove', x, y, origin: 'viewport'}, {type: 'pointerDown', button: 0},
              {type: 'pointerMove', x: x + dx, y: y + dy, origin: 'viewport', duration: dx || dy ? 100 : 0},
              {type: 'pointerUp', button: 0}]}]});
        } else {
          await send('Input.dispatchMouseEvent', {type: 'mouseMoved', x, y});
          await send('Input.dispatchMouseEvent', {type: 'mousePressed', x, y, button: 'left', buttons: 1, clickCount: 1});
          for (let i = 1; i <= 5; i++) {
            await send('Input.dispatchMouseEvent',
              {type: 'mouseMoved', x: x + dx * i / 5, y: y + dy * i / 5, button: 'left', buttons: 1});
            await sleep(20);
          }
          await send('Input.dispatchMouseEvent', {type: 'mouseReleased', x: x + dx, y: y + dy, button: 'left', buttons: 0, clickCount: 1});
        }
      },
      async close() { socket.close(); await stopProcess(child); },
    };
  } catch (error) {
    socket?.close(); await stopProcess(child);
    throw new Error(`${error.stack}\n${logs.join('')}`);
  }
}
