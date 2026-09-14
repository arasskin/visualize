import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {mkdtemp, readFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {browser} from './browser.mjs';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const root = await mkdtemp(join(tmpdir(), 'vz-terminal-render-'));
const server = createServer(async (request, response) => {
  try {
    const path = new URL(request.url, 'http://localhost').pathname;
    if (path === '/') {
      response.setHeader('Content-Type', 'text/html');
      response.end('<link rel="stylesheet" href="/src.wterm/wterm.css"><link rel="stylesheet" href="/src/web/style.css">' +
        '<div class="panel picked"><div class="panel-body"><div class="screen wterm focused"><div class="term-grid"></div></div></div></div>');
    } else if (path.startsWith('/src.wterm/') || path === '/src/web/style.css') {
      response.setHeader('Content-Type', path.endsWith('.js') ? 'text/javascript' : 'text/css');
      response.end(await readFile(join(repo, path)));
    } else { response.writeHead(404); response.end(); }
  } catch { response.writeHead(404); response.end(); }
});

try {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  for (const engine of ['chrome', 'firefox']) {
    const page = await browser(engine, root);
    try {
      await page.viewport(1200, 700);
      await page.navigate(`http://127.0.0.1:${server.address().port}/`);
      const results = await page.evaluate(`(async () => {
        const {Renderer} = await import('/src.wterm/wterm-dom-renderer.js');
        const renderer = new Renderer(document.querySelector('.term-grid'));
        renderer.setup(80, 1);
        const row = renderer.rowEls[0], screen = document.querySelector('.screen');
        const blank = {char: 32, width: 1, fg: 256, bg: 256, flags: 0};
        const character = (text, extra = {}) => ({...blank, char: text.codePointAt(0), ...extra});
        const draw = (cells, cursor = -1) => renderer._buildRowContent(row, col => cells[col] || blank, cells.length, cursor, 0);
        const positions = () => {
          const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT), points = [];
          let node;
          while (node = walker.nextNode()) for (let i = 0; i < node.length; i++) {
            const range = document.createRange();
            range.setStart(node, i); range.setEnd(node, i + 1);
            points.push(range.getBoundingClientRect().x);
          }
          return points;
        };
        const results = [];
        for (const size of [12, 14, 18]) for (const cursor of [-1, 1, 2, 18]) {
          screen.style.fontSize = size + 'px';
          const samples = [];
          for (const spinner of [' ', '⠁', '⠂', '⠄', '⡀', '⢀', '⣿', ' ']) {
            draw([character('›', {flags: 1}), character(spinner, {fg: 8}),
              ...Array.from('The input text must stay in place', ch => character(ch))], cursor);
            samples.push(positions().slice(2, 34));
          }
          const drift = Math.max(...samples[0].map((_, i) =>
            Math.max(...samples.map(sample => sample[i])) - Math.min(...samples.map(sample => sample[i]))));
          results.push({size, cursor, drift});
        }
        screen.style.fontSize = '12px';
        const link = {linkUri: 'https://example.com/é', linkId: 'example'};
        draw([character('⠁'), character('界', {width: 2}), {...blank, width: 0},
          character('e', {chars: 'é'}), ...Array.from('https://example.com/é', ch => character(ch, link))], 2);
        const wide = row.querySelector('.term-wide');
        const anchor = row.querySelector('a');
        const selection = getSelection(), range = document.createRange();
        range.selectNodeContents(anchor); selection.removeAllRanges(); selection.addRange(range);
        const details = {wideText: wide.textContent, wideCursor: wide.classList.contains('term-cursor'),
          wideWidth: wide.getBoundingClientRect().width, narrowWidth: row.firstElementChild.getBoundingClientRect().width,
          selection: selection.toString(), href: anchor.href, text: row.textContent.trimEnd()};
        selection.removeAllRanges();
        draw([...Array.from({length: 79}, () => blank), character('é')], 79);
        details.lastCell = row.querySelector('.term-cursor').textContent;
        return {results, details};
      })()`);
      for (const result of results.results) assert(result.drift < 0.05,
        `${engine}: spinner shifts input text at ${result.size}px, cursor ${result.cursor}: ${result.drift}px`);
      const details = results.details;
      assert.equal(details.wideText, '界');
      assert(details.wideCursor);
      assert(Math.abs(details.wideWidth - 2 * details.narrowWidth) < 0.05);
      assert.equal(details.selection, 'https://example.com/é');
      assert.equal(details.href, 'https://example.com/%C3%A9');
      assert.equal(details.text, '⠁界éhttps://example.com/é');
      assert.equal(details.lastCell, 'é');
      assert.deepEqual(page.errors, []);
      console.log(`${engine}: passed 12 spinner/cursor/font checks, wide and combining cells, links, selection and last-column rendering.`);
    } finally { await page.close(); }
  }
} finally {
  await new Promise(resolve => server.close(resolve));
  await rm(root, {recursive: true, force: true});
}
