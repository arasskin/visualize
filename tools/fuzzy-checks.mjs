import assert from 'node:assert/strict';
import { fuzzyRank, fuzzyScore } from '../src/web/fuzzy.js';

assert.deepEqual(fuzzyRank(['xxordful', 'order_fulfillment', 'ordful_extra', 'ordful'], 'ordful'),
  ['ordful', 'ordful_extra', 'xxordful', 'order_fulfillment']);
assert.equal(fuzzyScore('order_fulfillment', 'ORDER FULFILLMENT'), 0);
assert.equal(fuzzyScore('order fulfillment', 'order_fulfillment'), 0);
assert.ok(Number.isFinite(fuzzyScore('plan.order_fulfillment', 'ordful')));
assert.ok(Number.isFinite(fuzzyScore('order_fulfillment', 'of')));
assert.equal(fuzzyScore('order_fulfillment', 'zyx'), Infinity);
assert.equal(fuzzyScore('abc', 'cba'), Infinity);
assert.equal(fuzzyScore('abc', 'abbc'), Infinity);
assert.ok(fuzzyScore('a_b_c', 'abc') < fuzzyScore('a_long_b_long_c', 'abc'));
assert.deepEqual(fuzzyRank(['beta', 'alpha'], ''), ['beta', 'alpha']);
assert.deepEqual(fuzzyRank(['beta', 'alpha'], 'zzz'), []);
assert.equal(fuzzyScore('CAFÉ_λ', 'café λ'), 0);
assert.ok(Number.isFinite(fuzzyScore('🪴_garden', '🪴g')));
console.log('Passed 13 fuzzy search checks');
