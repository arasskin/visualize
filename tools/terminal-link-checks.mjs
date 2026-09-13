import assert from 'node:assert/strict';
import { textLinks } from '../src.wterm/wterm-dom-hyperlink.js';

const cases = [
  ['(http://127.0.0.1:8768/recordings)—refresh', ['http://127.0.0.1:8768/recordings']],
  ['(http://127.0.0.1:8768/recordings)-refresh', ['http://127.0.0.1:8768/recordings']],
  ['https://example.com/path—refresh', ['https://example.com/path']],
  ['[https://example.com/path]next', ['https://example.com/path']],
  ['“https://example.com/path”,', ['https://example.com/path']],
  ['(https://example.com/wiki/Function_(math)).', ['https://example.com/wiki/Function_(math)']],
  ['http://[::1]:8768/a-b?q=one-two&x=3#section-1', ['http://[::1]:8768/a-b?q=one-two&x=3#section-1']],
  ['https://example.com/a%29b', ['https://example.com/a%29b']],
  ['one https://a.test/a; two https://b.test/b!', ['https://a.test/a', 'https://b.test/b']],
];
for (const [text, expected] of cases) {
  const links = textLinks(text);
  assert.deepEqual(links.map(link => link.uri), expected, text);
  for (const link of links) assert.equal(text.slice(link.index, link.index + link.uri.length), link.uri);
}
console.log(`Passed ${cases.length} terminal URL boundary checks.`);
