import assert from 'node:assert/strict';
import {readFile, readdir} from 'node:fs/promises';
import {posix} from 'node:path';
import {createCamera} from '../src/web/graph/camera.js';
import {refreshLoop} from '../src/web/shared/refresh.js';

const camera = createCamera();
assert(camera.fit(800, 600, 400, 200));
const center = {x: 200, y: 100, width: 0, height: 0};
assert.deepEqual(camera.project(center), {x: 400, y: 300, width: 0, height: 0});
assert.equal(camera.touched, false);
const pointer = {x: 317, y: 219};
const world = {x: (pointer.x - camera.tx) / camera.scale, y: (pointer.y - camera.ty) / camera.scale, width: 0, height: 0};
for (const factor of [1.2, .5, 1000, .0001, 2]) {
  camera.zoom(factor, pointer.x, pointer.y);
  const projected = camera.project(world);
  assert(Math.abs(projected.x - pointer.x) < 1e-8 && Math.abs(projected.y - pointer.y) < 1e-8, 'zoom preserves the point under the pointer, including at limits');
}
assert.equal(camera.touched, true);
camera.anchor(center, pointer);
assert(Math.abs(camera.project(center).x - pointer.x) < 1e-8);
const before = camera.project(center); camera.pan(13, -7);
assert.equal(camera.project(center).x, before.x + 13);
assert.equal(camera.project(center).y, before.y - 7);

const loads = [], applied = [], errors = [];
const refresh = refreshLoop({interval: 60000,
  load: signal => new Promise((resolve, reject) => loads.push({signal, resolve, reject})),
  apply: value => applied.push(value), error: error => errors.push(error),
});
const first = refresh.refresh();
assert.equal(loads.length, 1, 'simultaneous refreshes share one request');
refresh.invalidate();
assert(loads[0].signal.aborted);
loads[0].resolve('stale'); await first;
assert.deepEqual(applied, [], 'a late pre-edit response cannot overwrite the new view');
const second = refresh.refresh(); loads[1].resolve('current'); await second;
assert.deepEqual(applied, ['current']);
const last = refresh.refresh(); refresh.stop();
assert(loads[2].signal.aborted);
loads[2].resolve('closed'); await last; await refresh.refresh();
assert.deepEqual(applied, ['current'], 'closing prevents late rendering and new requests');
assert.equal(loads.length, 3); assert.deepEqual(errors, []);

const files = (await readdir(new URL('../src/web/', import.meta.url), {recursive: true})).filter(file => file.endsWith('.js'));
const imports = new Map();
for (const file of files) {
  const source = await readFile(new URL('../src/web/' + file, import.meta.url), 'utf8');
  imports.set(file, [...source.matchAll(/(?:from\s+|import\s*(?:\(\s*)?)['"](\.[^'"]+)['"]/g)]
    .map(match => posix.normalize(posix.join(posix.dirname(file), match[1]))));
}
const seen = new Set();
function visit(file, path = []) {
  assert(!path.includes(file), 'frontend dependency cycle: ' + [...path, file].join(' -> '));
  if (seen.has(file)) return;
  assert(imports.has(file), 'missing module: ' + file);
  for (const dependency of imports.get(file)) visit(dependency, [...path, file]);
  seen.add(file);
}
for (const file of files) visit(file);
for (const file of ['panes/frame.js', 'panes/layout.js', 'graph/camera.js', 'shared/completion-list.js', 'shared/refresh.js']) {
  assert.deepEqual(imports.get(file), [], file + ' must remain independent of application features');
}
assert(!imports.get('terminal/content.js').some(file => /panes|document|layout/.test(file)), 'terminal content must not own workspace or documents');
console.log('Passed camera invariants, refresh races and lifecycle, and dependency boundaries for ' + files.length + ' modules.');
