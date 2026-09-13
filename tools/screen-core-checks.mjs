import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { WTerm } from '../src.wterm/wterm-dom-wterm.js';
import { ScreenCore } from '../src/web/screen-core.js';

const code = `(import ./src.server/term/vterm)
(import ./src.server/json)
(def terminal (vterm/create 4 20))
(defn emit [at] (print (json/encode (:snapshot terminal at))))
(:write terminal "界é\\e[38;2;12;34;56mX\\e[0m")
(emit 0)
(def baseline (:revision terminal))
(:write terminal "\\r\\nnext")
(emit baseline)
(:resize terminal 6 30)
(emit baseline)
(:write terminal "\\e[2J\\e[H1\\r\\n2\\r\\n3\\r\\n4\\r\\n5\\r\\n6\\r\\n7\\r\\n8")
(emit 0)
(:close terminal)`;
const snapshots = execFileSync('external-src/janet/janet', ['-e', code], { encoding: 'utf8' }).trim().split('\n').map(JSON.parse);
const core = new ScreenCore();
core.apply(snapshots[0]);
assert.equal(core.getCell(0, 0).char, '界'.codePointAt(0));
assert.equal(core.getCell(0, 0).width, 2);
assert.equal(core.getCell(0, 1).width, 0);
assert.equal(core.getCell(0, 2).chars, 'é');
assert.equal(core.getCell(0, 3).fgRgb, 0x0c2238);
assert.equal(core.getCell(0, 19).char, 32);
core.clearDirty();
core.apply(snapshots[1]);
assert.equal(core.getCell(0, 0).width, 2);
assert.equal(core.getCell(1, 0).char, 110);
assert(core.isDirtyRow(0));
assert(core.isDirtyRow(1));
core.apply(snapshots[2]);
assert.equal(core.getRows(), 6);
assert.equal(core.getCols(), 30);
assert.equal(core.getCell(5, 29).char, 32);
core.apply(snapshots[3]);
assert.equal(core.getScrollbackCount(), 2);
assert.equal(core.getScrollbackCell(0, 0).char, 50);
assert.equal(core.getScrollbackCell(1, 0).char, 49);
assert.equal(core.getCell(0, 0).char, 51);
assert.equal(core.writeString, undefined);
assert.equal(core.writeRaw, undefined);
await assert.rejects(WTerm.prototype.init.call({ destroy() {} }), /a screen core is required/);
assert.equal(WTerm.prototype.write, undefined);
console.log('Screen adapter: 21 checks passed using native libvterm snapshots.');
