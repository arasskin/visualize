import { readFile } from 'node:fs/promises';
import { Worker, isMainThread, parentPort, workerData } from 'node:worker_threads';

if (isMainThread) {
  const [cols, rows, capture, binary] = process.argv.slice(2);
  if (!capture || !Number.isInteger(Number(cols)) || !Number.isInteger(Number(rows)) || Number(cols) < 1 || Number(rows) < 1) {
    throw new Error('Usage: node tools/emulator-replay.mjs <cols> <rows> <base64-batches.json> [wasm-path]');
  }
  const worker = new Worker(new URL(import.meta.url), {
    workerData: { cols: Number(cols), rows: Number(rows), capture, binary },
  });
  try {
    const result = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('Emulator replay stalled for 10 seconds')), 10000);
      worker.once('message', result => { clearTimeout(timer); resolve(result); });
      worker.once('error', error => { clearTimeout(timer); reject(error); });
      worker.once('exit', code => { if (code) { clearTimeout(timer); reject(new Error(`Replay worker exited with ${code}`)); } });
    });
    console.log(`Passed: ${result.batches} batches, ${result.bytes} bytes at ${cols}×${rows}`);
  } finally {
    await worker.terminate();
  }
} else {
  const { cols, rows, capture, binary } = workerData;
  let wasm;
  const messages = [];
  const bytes = await readFile(binary || new URL('../external-src/wterm/ghostty-vt.wasm', import.meta.url));
  const { instance } = await WebAssembly.instantiate(bytes, {
    env: { log(ptr, length) {
      messages.push(new TextDecoder().decode(new Uint8Array(wasm.memory.buffer, ptr, length)));
      if (messages.length > 8) messages.shift();
    } },
  });
  wasm = instance.exports;
  const terminal = wasm.init(cols, rows, 10000, 0x3a4851, 0xffffff);
  if (!terminal) throw new Error('Emulator initialization failed');
  const batches = JSON.parse(await readFile(capture, 'utf8'));
  let total = 0;
  try {
    for (const batch of batches) {
      const data = Buffer.from(batch, 'base64');
      if (!data.length) continue;
      const ptr = wasm.alloc_buffer(data.length);
      if (!ptr) throw new Error('Emulator allocation failed');
      new Uint8Array(wasm.memory.buffer, ptr, data.length).set(data);
      wasm.write(terminal, ptr, data.length);
      wasm.free_buffer(ptr, data.length);
      total += data.length;
    }
  } catch (error) {
    throw new Error(`${error.message}\n${messages.join('\n')}`, { cause: error });
  }
  parentPort.postMessage({ batches: batches.length, bytes: total });
}
