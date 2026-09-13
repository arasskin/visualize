import assert from 'node:assert/strict';
import { matchesText } from '../src/web/text-match.js';

assert(matchesText('plan.order_fulfillment', 'FULFILL'));
assert(matchesText('order_fulfillment', 'ORDER FULFILLMENT'));
assert(matchesText('order fulfillment', 'order_fulfillment'));
assert(matchesText('CAFÉ_λ', 'café λ'));
assert(matchesText('🪴_garden', '🪴 garden'));
assert(matchesText('alpha', ''));
assert(!matchesText('order_fulfillment', 'ordful'));
assert(!matchesText('order_fulfillment', 'of'));
assert(!matchesText('abc', 'cba'));
assert(!matchesText('abc', 'abbc'));
assert(!matchesText('🪴_garden', '🪴g'));
console.log('Passed 11 substring search checks');
