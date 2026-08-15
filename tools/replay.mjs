// Replay a captured byte stream through the emulator, headlessly.
//
// THE FORENSIC TOOL OF THE RENDERING HUNT: the supervisor's backlog is a
// recording of everything the program drew, and this runs that recording
// through the same term.js the page uses -- deterministically, in seconds,
// with no browser and no timing. The wrap and alternate-screen bugs were
// convicted exactly this way. (dev/dump) at the repl writes the capture;
// (dev/replay path) runs this over it.
//
//     node tools/replay.mjs <capture> [--rows N] [--cols N]
//
// Bytes are fed in pty-sized bites so chunk-boundary handling -- split
// escapes, split surrogate pairs -- is exercised the way the wire does it.

import { readFileSync } from 'node:fs';
import { makeTerminal } from '../web/term.js';

export function replay(bytes, rows = 24, cols = 80, bite = 4096) {
  const term = makeTerminal({ innerHTML: '' },
    { rows, cols, showCursor: false, scrollbackVisible: false });
  for (let i = 0; i < bytes.length; i += bite) term.write(bytes.slice(i, i + bite));
  const screen = term.text();
  // Rows that look like escape sequences rendered as text -- the signature
  // of a torn stream or a parser gap. A heuristic for a human to judge:
  // ordinary content can contain brackets too.
  const suspects = screen
    .map((line, row) => ({ row, line }))
    .filter(({ line }) => /\[[\d;]+[A-HJKSTfm]|\[\?[\d;]*[hl]|�/.test(line));
  return {
    screen,
    suspects,
    filled: screen.filter((l) => l.trim() !== '').length,
  };
}

const cliMain = process.argv[1] && import.meta.url.endsWith(process.argv[1].split('/').pop());
if (cliMain) {
  const args = process.argv.slice(2);
  const file = args.find((a) => !a.startsWith('--'));
  if (!file) {
    console.error('usage: node tools/replay.mjs <capture> [--rows N] [--cols N]');
    process.exit(2);
  }
  const flag = (name, fallback) => {
    const i = args.indexOf(name);
    return i >= 0 ? parseInt(args[i + 1], 10) : fallback;
  };
  const bytes = readFileSync(file, 'latin1');
  const { screen, suspects, filled } = replay(bytes, flag('--rows', 24), flag('--cols', 80));
  console.log(`${bytes.length} bytes -> ${filled} of ${screen.length} rows filled`);
  if (suspects.length === 0) {
    console.log('no escape-fragment suspects: the stream parsed clean');
  } else {
    console.log(`${suspects.length} suspect row(s) -- escape-like text on screen:`);
    for (const { row, line } of suspects.slice(0, 10)) {
      console.log(`  row ${row}: ${JSON.stringify(line.slice(0, 90))}`);
    }
  }
  console.log('final frame, last 10 rows:');
  for (const line of screen.slice(-10)) console.log(` | ${line.slice(0, 110)}`);
}
