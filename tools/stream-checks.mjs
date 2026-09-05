import assert from 'node:assert/strict';
import { createConnection } from 'node:net';
import { request as httpRequest } from 'node:http';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';

export async function check({ cdp, url, root, waitFor, restart }) {
  let checks = 0;
  const token = await cdp.evaluate('window.TOKEN');
  const upgrade = (key, origin) => new Promise((resolve, reject) => {
    const req = httpRequest(url + '/terminal?k=' + key, { headers: {
      Upgrade: 'websocket', Connection: 'Upgrade', 'Sec-WebSocket-Key': 'dGhlIHNhbXBsZSBub25jZQ==',
      'Sec-WebSocket-Version': '13', Origin: origin,
    } });
    req.on('response', r => { r.resume(); resolve(r.statusCode); });
    req.on('upgrade', (r, socket) => { socket.destroy(); resolve(r.statusCode); });
    req.on('error', reject); req.end();
  });
  assert.equal(await upgrade('wrong', url), 403); checks++;
  assert.equal(await upgrade(token, 'https://example.invalid'), 403); checks++;
  assert.equal(await upgrade(token, url), 101); checks++;

  function masked(opcode, text, final = true) {
    const body = Buffer.from(text), mask = Buffer.from([1,2,3,4]);
    assert(body.length < 126);
    return Buffer.concat([Buffer.from([(final ? 128 : 0) | opcode, 128 | body.length]), mask,
      Buffer.from(body.map((b,i) => b ^ mask[i%4]))]);
  }
  const wire = createConnection(new URL(url).port, '127.0.0.1');
  let carry = Buffer.alloc(0), upgraded = false;
  const frames = [];
  wire.on('data', chunk => {
    carry = Buffer.concat([carry, chunk]);
    if (!upgraded) {
      const end = carry.indexOf('\r\n\r\n'); if (end < 0) return;
      assert(carry.subarray(0,end).toString().startsWith('HTTP/1.1 101'));
      carry = carry.subarray(end+4); upgraded = true;
    }
    while (carry.length >= 2) {
      let size = carry[1] & 127, head = 2;
      if (size === 126) { if (carry.length < 4) return; size = carry.readUInt16BE(2); head = 4; }
      if (size === 127) { if (carry.length < 10) return; size = Number(carry.readBigUInt64BE(2)); head = 10; }
      if (carry.length < head+size) return;
      frames.push({ opcode: carry[0] & 15, body: carry.subarray(head,head+size) });
      carry = carry.subarray(head+size);
    }
  });
  try {
    await new Promise((resolve, reject) => { wire.once('connect', resolve); wire.once('error', reject); });
    wire.write(`GET /terminal?k=${token} HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nOrigin: ${url}\r\n\r\n`);
    await waitFor(() => upgraded);
    const command = JSON.stringify({type:'request',pane:'harness',id:7,op:'poll',body:{at:0,generation:0}});
    wire.write(Buffer.concat([masked(1, command.slice(0,40), false), masked(9,'ping'), masked(0,command.slice(40))]));
    await waitFor(() => frames.some(f => f.opcode === 2));
    assert(frames.some(f => f.opcode === 10 && f.body.toString() === 'ping')); checks++;
    assert.equal(JSON.parse(frames.find(f => f.opcode === 2).body).id, 7); checks++;
    wire.write(masked(8, Buffer.from([3,232])));
    await waitFor(() => frames.some(f => f.opcode === 8)); checks++;
  } finally { wire.destroy(); }

  const conf = await readFile(join(root,'project','visualize.conf'),'utf8');
  const host = createConnection(conf.match(/@visualize terminal harness socket (.+)/)[1]);
  let text = ''; const awaiting = [];
  host.on('data', b => {
    text += String(b);
    for (;;) {
      const end = text.indexOf('\n'); if (end < 0) return;
      const line = text.slice(0,end); text = text.slice(end+1);
      awaiting.shift()(JSON.parse(line));
    }
  });
  await new Promise((resolve, reject) => { host.once('connect', resolve); host.once('error', reject); });
  const ask = message => new Promise(resolve => { awaiting.push(resolve); host.write(JSON.stringify(message)+'\n'); });
  try {
    const before = await ask({op:'state'});
    const count = await cdp.evaluate('(document.querySelector("#harness .screen").textContent.match(/x/g)||[]).length');
    await restart(async () => {
      await ask({op:'input',text:'z',quiet:true,generation:before.generation});
    });
    await waitFor(() => cdp.evaluate(`window.TOKEN !== ${JSON.stringify(token)}`));
    await waitFor(() => cdp.evaluate('document.querySelector("#harness .screen").textContent.includes("z")'));
    const after = await ask({op:'state'});
    assert.equal(after.generation, before.generation); checks++;
    assert.equal(await cdp.evaluate('(document.querySelector("#harness .screen").textContent.match(/x/g)||[]).length'), count); checks++;
    assert.equal(await cdp.evaluate('(document.querySelector("#harness .screen").textContent.match(/z/g)||[]).length'), 1); checks++;
    const stream = await ask({op:'since',at:0,generation:before.generation,limit:4,encoding:'base64'});
    assert.equal(stream.encoding,'base64'); assert(stream.at <= after.chunks); checks++;
    const old = await ask({op:'input',text:'BAD',quiet:true,generation:before.generation+1});
    assert.equal(old.error,'terminal session changed'); checks++;
    await cdp.evaluate('document.querySelector("#harness textarea").focus()');
    await cdp.send('Input.dispatchKeyEvent',{type:'keyDown',key:'y',code:'KeyY',text:'y'});
    await cdp.send('Input.dispatchKeyEvent',{type:'keyUp',key:'y',code:'KeyY'});
    await waitFor(() => cdp.evaluate('document.querySelector("#harness .screen").textContent.includes("y")')); checks++;
    const result = await ask({op:'since',at:0});
    assert(!result.text.includes('BAD')); checks++;
    await ask({op:'start',argv:['/usr/bin/python3','-c',
      "import sys,time;sys.stdout.buffer.write(bytes([226]));sys.stdout.flush();time.sleep(.04);sys.stdout.buffer.write(bytes([130,172]));sys.stdout.flush();time.sleep(2)"],root:join(root,'project'),rows:24,cols:80});
    try { await waitFor(() => cdp.evaluate('document.querySelector("#harness .screen").textContent.includes("€")'), 5000); }
    catch (error) {
      console.log('Unicode probe:', JSON.stringify(await ask({op:'since',at:0})), await cdp.evaluate('document.querySelector("#harness").textContent'));
      throw error;
    }
    assert(!await cdp.evaluate('document.querySelector("#harness .screen").textContent.includes("�")')); checks++;
  } finally { host.end(); }
  await sleep(100);
  console.log('Stream integration checks:', checks);
  return checks;
}
