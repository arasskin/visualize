// A terminal, in about as few lines as an agent harness needs.
//
// NOT A FULL XTERM, and not trying to be. It covers what Claude Code and pi
// actually emit, which was measured rather than guessed: 17 and 19 distinct
// sequences respectively at startup, overwhelmingly SGR colour, with a
// handful of cursor moves and erases. Neither uses the alternate screen
// buffer and neither turns on mouse tracking, which is what keeps this small
// -- those two features are most of what makes a real emulator large.
//
// WHY AN EMULATOR AT ALL, rather than appending text. A harness REDRAWS IN
// PLACE as tokens stream: it moves the cursor up, erases the line, and writes
// it again. Appending would produce one copy of every partial line, so the
// screen has to be a grid with a cursor, not a log.
//
// THE GRID IS THE MODEL AND THE DOM IS A VIEW OF IT. Every write mutates
// cells; a repaint renders the whole grid. That is more work per frame than
// patching the DOM, and it is the reason this stays comprehensible: there is
// exactly one way the screen can be wrong, and it is the grid.

export function makeTerminal(screen, options = {}) {
  let rows = options.rows || 24;
  let cols = options.cols || 80;

  // A cell is { ch, fg, bg, bold, dim, underline, inverse }. Null fg/bg mean
  // "the default", which the CSS supplies.
  const blank = () => ({ ch: ' ', fg: null, bg: null, bold: false, dim: false,
                         underline: false, inverse: false,
                         wide: false, cont: false });

  let grid = [];
  let cursor = { row: 0, col: 0, visible: true };
  let saved = null;
  // DEFERRED WRAP, as every real terminal does it. Printing in the last
  // column leaves the cursor ON that column with the wrap owed; the next
  // printable pays it, and any explicit cursor motion cancels it. The naive
  // version let the cursor sit one past the edge, where a following CSI C
  // clamped it BACKWARD and a following printable wrapped SPURIOUSLY --
  // off-by-ones that claude's delta renderer (which patches lines in place
  // and rarely clears) accumulated into smeared frames.
  let wrapPending = false;
  // The alternate screen (?1049). Claude runs its whole TUI there. Entering
  // clears; leaving restores what was; and rows scrolled off while inside
  // VANISH rather than entering scrollback -- an alt-screen program's
  // repaint debris is not history.
  let altSaved = null;
  // Whether the program asked for the mouse (?1000/1002/1003) and for SGR
  // encoding (?1006). Claude turns all four on at startup and scrolls its
  // own transcript on wheel events -- it never scrolls the terminal -- so
  // whoever hosts this emulator must forward the wheel when this is on, or
  // history is unreachable. See the wheel listener in app.js.
  let mouse = { tracking: false, sgr: false };
  // ?2026, synchronized output: the program brackets a repaint between h and
  // l so the terminal shows whole frames, never a half-painted one. Claude
  // wraps every frame in it. Honouring it is what keeps typing and scrolling
  // from flickering -- paints hold while a frame is open -- and the backstop
  // timer in write() covers a program that opens a frame and dies.
  let sync = false;
  let syncTimer = null;
  // Pending attributes, applied to every cell written until they change.
  let attr = { fg: null, bg: null, bold: false, dim: false, underline: false,
               inverse: false };
  // Rows the harness has scrolled off the top. Kept so the pane can be
  // scrolled back, which a graph tool's user will expect even though a real
  // terminal in its default mode has no scrollback of its own.
  let scrollback = [];
  const scrollbackLimit = options.scrollback || 2000;

  // -- the two-part view ------------------------------------------------------
  // History is IMMUTABLE BY CONSTRUCTION: a row that scrolls off the grid
  // never changes again. The render used to ignore that and rebuild
  // scrollback + grid as one innerHTML string every paint -- measured at 67x
  // the cost of an empty screen once scrollback was full, plus a full DOM
  // teardown that broke scroll anchoring and killed any selection every
  // frame. So the screen is two elements: `.history`, appended to exactly
  // once per row as it dies, and `.live`, the only part a paint rewrites.
  // The browser then has stable nodes to anchor scrolling to, selection in
  // history survives streaming, and per-frame cost stops depending on how
  // long the session has run.
  //
  // Headless (the node tests) has no document; there the render keeps the
  // old single-string shape, which is also what `scrollbackVisible` tests
  // rely on. The split is a DOM optimisation, not a model change.
  const doc = screen.ownerDocument;
  const dom = !!(doc && doc.createElement);
  let historyEl = null;
  let liveEl = null;
  // The live block is ONE ELEMENT PER ROW, and these run parallel to its
  // children: the HTML each row currently holds. A paint compares and writes
  // only the rows that differ -- wterm calls this dirty-row tracking, and it
  // is what lets a one-cell change (a cursor step, a spinner tick) touch one
  // div instead of tearing down the whole grid. It is also what lets a
  // selection in the live region survive a paint that did not touch its rows.
  let liveDivs = [];
  let liveHTML = [];
  if (dom) {
    historyEl = doc.createElement('div');
    historyEl.className = 'history';
    liveEl = doc.createElement('div');
    liveEl.className = 'live';
    screen.append(historyEl, liveEl);
  }

  function reset() {
    grid = [];
    for (let r = 0; r < rows; r++) {
      grid.push(Array.from({ length: cols }, blank));
    }
    cursor = { row: 0, col: 0, visible: true };
    wrapPending = false;
    altSaved = null;
  }
  reset();

  function cell(r, c) {
    if (r < 0 || r >= rows || c < 0 || c >= cols) return null;
    return grid[r][c];
  }

  // One row as HTML, runs of identical styling merged into single spans.
  // `cursorCol` marks the cell wearing the cursor; history rows pass null,
  // which is also why banking a row is cheap -- no per-cell cursor check.
  function rowHTML(row, cursorCol) {
    let line = '';
    let runStyle = null;
    let run = '';
    const flush = () => {
      if (!run) return;
      line += runStyle
        ? `<span style="${runStyle}">${escapeHtml(run)}</span>`
        : escapeHtml(run);
      run = '';
    };
    for (let c = 0; c < row.length; c++) {
      // The continuation half of a wide pair renders nothing: its character
      // already spans both cells, held to exactly that span by the CSS class.
      if (row[c].cont && c !== cursorCol) continue;
      if (c === cursorCol) {
        flush();
        line += `<span class="cursor${row[c].wide ? ' w' : ''}">${escapeHtml(row[c].ch || ' ')}</span>`;
        runStyle = null;
        continue;
      }
      if (row[c].wide) {
        flush();
        const style = styleOf(row[c]);
        line += `<span class="w"${style ? ` style="${style}"` : ''}>${escapeHtml(row[c].ch)}</span>`;
        runStyle = null;
        continue;
      }
      const style = styleOf(row[c]);
      if (style !== runStyle) { flush(); runStyle = style; }
      run += row[c].ch;
    }
    flush();
    // Trailing blanks render identically and are most of a sparse row.
    return line.replace(/\s+$/, '');
  }

  // A row leaves the grid for good: remember it, and in the DOM render it
  // NOW, once -- the only time this row will ever be serialized.
  function bankRow(gone) {
    if (altSaved) return;
    scrollback.push(gone);
    if (dom && options.scrollbackVisible !== false) {
      historyEl.insertAdjacentHTML('beforeend', `<div>${rowHTML(gone, null)}</div>`);
    }
    if (scrollback.length > scrollbackLimit) {
      scrollback.shift();
      if (dom && historyEl.firstChild) historyEl.removeChild(historyEl.firstChild);
    }
  }

  function scrollUp() {
    bankRow(grid.shift());
    grid.push(Array.from({ length: cols }, blank));
  }

  function newline() {
    cursor.row++;
    if (cursor.row >= rows) {
      cursor.row = rows - 1;
      scrollUp();
    }
  }

  // -- character width --------------------------------------------------------
  // A wide character owns TWO cells, and pretending otherwise misaligns every
  // column to its right -- claude's output is full of emoji, and each one
  // used to shear the rest of its row. The ranges are the East Asian
  // Wide/Fullwidth blocks plus the emoji-presentation blocks: not the whole
  // of Unicode's width data, but the part these harnesses emit. Sorted, for
  // the binary search.
  const wideRanges = [
    [0x1100, 0x115F],   // Hangul Jamo
    [0x231A, 0x231B], [0x23E9, 0x23EC], [0x23F0, 0x23F0], [0x23F3, 0x23F3],
    [0x25FD, 0x25FE], [0x2614, 0x2615], [0x2648, 0x2653], [0x267F, 0x267F],
    [0x2693, 0x2693], [0x26A1, 0x26A1], [0x26AA, 0x26AB], [0x26BD, 0x26BE],
    [0x26C4, 0x26C5], [0x26CE, 0x26CE], [0x26D4, 0x26D4], [0x26EA, 0x26EA],
    [0x26F2, 0x26F3], [0x26F5, 0x26F5], [0x26FA, 0x26FA], [0x26FD, 0x26FD],
    [0x2705, 0x2705], [0x270A, 0x270B], [0x2728, 0x2728], [0x274C, 0x274C],
    [0x274E, 0x274E], [0x2753, 0x2755], [0x2757, 0x2757], [0x2795, 0x2797],
    [0x27B0, 0x27B0], [0x27BF, 0x27BF], [0x2B1B, 0x2B1C], [0x2B50, 0x2B50],
    [0x2B55, 0x2B55],
    [0x2E80, 0x303E],   // CJK radicals, punctuation
    [0x3041, 0x33FF],   // kana, CJK symbols
    [0x3400, 0x4DBF], [0x4E00, 0x9FFF],   // CJK ideographs
    [0xA000, 0xA4CF],   // Yi
    [0xAC00, 0xD7A3],   // Hangul syllables
    [0xF900, 0xFAFF],   // CJK compatibility
    [0xFE30, 0xFE4F],   // CJK compatibility forms
    [0xFF00, 0xFF60], [0xFFE0, 0xFFE6],   // fullwidth forms
    [0x1F000, 0x1F0FF],  // mahjong, dominoes, cards
    [0x1F18E, 0x1F18E], [0x1F191, 0x1F19A],
    [0x1F200, 0x1F2FF],  // enclosed ideographs
    [0x1F300, 0x1F64F],  // emoji proper
    [0x1F680, 0x1F6FF],  // transport
    [0x1F900, 0x1FAFF],  // supplemental emoji
    [0x20000, 0x3FFFD],  // CJK extensions
  ];
  // Marks that occupy no cell of their own: combining accents, the variation
  // selectors, ZWJ. They attach to the character before them rather than
  // being dropped, so what selection copies out is what the program printed.
  const zeroRanges = [
    [0x0300, 0x036F], [0x1AB0, 0x1AFF], [0x1DC0, 0x1DFF],
    [0x200B, 0x200D], [0x20D0, 0x20FF], [0xFE00, 0xFE0F], [0xE0100, 0xE01EF],
  ];
  function inRanges(ranges, cp) {
    let lo = 0, hi = ranges.length - 1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (cp < ranges[mid][0]) hi = mid - 1;
      else if (cp > ranges[mid][1]) lo = mid + 1;
      else return true;
    }
    return false;
  }
  function charWidth(cp) {
    if (inRanges(zeroRanges, cp)) return 0;
    return inRanges(wideRanges, cp) ? 2 : 1;
  }

  // Overwriting either half of a wide pair orphans the other half, which
  // becomes a plain space -- the classic terminal answer, and the one that
  // keeps the row the right length.
  function unpair(r, c) {
    const t = cell(r, c);
    if (!t) return;
    if (t.cont) {
      const left = cell(r, c - 1);
      if (left && left.wide) { left.ch = ' '; left.wide = false; }
    }
    if (t.wide) {
      const right = cell(r, c + 1);
      if (right && right.cont) { right.ch = ' '; right.cont = false; }
    }
    t.wide = false;
    t.cont = false;
  }

  function putChar(ch) {
    const width = charWidth(ch.codePointAt(0));
    // Zero width: the mark belongs to the character before it. `col - 1` may
    // be the continuation half of a wide pair; the character lives one left.
    if (width === 0) {
      let c = cursor.col - 1;
      if (c >= 0 && grid[cursor.row][c] && grid[cursor.row][c].cont) c--;
      const prev = cell(cursor.row, c);
      if (prev) prev.ch += ch;
      return;
    }
    // Pay the owed wrap first; then a wide character that would straddle
    // the edge wraps whole -- half an emoji is not a thing a terminal
    // prints.
    if (wrapPending) {
      wrapPending = false;
      cursor.col = 0;
      newline();
    }
    if (cursor.col + width > cols) {
      cursor.col = 0;
      newline();
    }
    const target = cell(cursor.row, cursor.col);
    if (target) {
      unpair(cursor.row, cursor.col);
      target.ch = ch;
      target.fg = attr.fg;
      target.bg = attr.bg;
      target.bold = attr.bold;
      target.dim = attr.dim;
      target.underline = attr.underline;
      target.inverse = attr.inverse;
      if (width === 2) {
        target.wide = true;
        const next = cell(cursor.row, cursor.col + 1);
        if (next) {
          unpair(cursor.row, cursor.col + 1);
          Object.assign(next, blank());
          next.ch = '';
          next.cont = true;
        }
      }
    }
    const next = cursor.col + width;
    if (next >= cols) {
      cursor.col = cols - 1;
      wrapPending = true;
    } else {
      cursor.col = next;
    }
  }

  // -- SGR, which is the overwhelming majority of what arrives ---------------
  // 30-37/90-97 foreground, 40-47/100-107 background, 38;5;N and 48;5;N for
  // the 256-colour palette (which is what both harnesses actually use).
  // The 16 named colours live in style.css with the rest of the theme; the
  // emulator refers to them and owns no colour of its own.
  const names = ['black', 'red', 'green', 'yellow',
                 'blue', 'magenta', 'cyan', 'white'];
  const basic = names.map(n => `var(--term-${n})`);
  const bright = names.map(n => `var(--term-bright-${n})`);

  // The xterm 256-colour cube, computed rather than tabulated.
  function palette(n) {
    if (n < 8) return basic[n];
    if (n < 16) return bright[n - 8];
    if (n < 232) {
      const i = n - 16;
      const steps = [0, 95, 135, 175, 215, 255];
      const r = steps[Math.floor(i / 36) % 6];
      const g = steps[Math.floor(i / 6) % 6];
      const b = steps[i % 6];
      return `rgb(${r},${g},${b})`;
    }
    const grey = 8 + (n - 232) * 10;
    return `rgb(${grey},${grey},${grey})`;
  }

  function applySGR(params) {
    if (params.length === 0) params = [0];
    for (let i = 0; i < params.length; i++) {
      const p = params[i];
      if (p === 0) {
        attr = { fg: null, bg: null, bold: false, dim: false,
                 underline: false, inverse: false };
      } else if (p === 1) attr.bold = true;
      else if (p === 2) attr.dim = true;
      else if (p === 4) attr.underline = true;
      else if (p === 7) attr.inverse = true;
      else if (p === 22) { attr.bold = false; attr.dim = false; }
      else if (p === 24) attr.underline = false;
      else if (p === 27) attr.inverse = false;
      else if (p >= 30 && p <= 37) attr.fg = basic[p - 30];
      else if (p === 39) attr.fg = null;
      else if (p >= 40 && p <= 47) attr.bg = basic[p - 40];
      else if (p === 49) attr.bg = null;
      else if (p >= 90 && p <= 97) attr.fg = bright[p - 90];
      else if (p >= 100 && p <= 107) attr.bg = bright[p - 100];
      else if (p === 38 || p === 48) {
        // 38;5;N (256 colour) or 38;2;R;G;B (truecolour). Both appear in the
        // wild; the harnesses measured used the first.
        const target = p === 38 ? 'fg' : 'bg';
        if (params[i + 1] === 5) { attr[target] = palette(params[i + 2] || 0); i += 2; }
        else if (params[i + 1] === 2) {
          attr[target] = `rgb(${params[i + 2] || 0},${params[i + 3] || 0},${params[i + 4] || 0})`;
          i += 4;
        }
      }
    }
  }

  function eraseInLine(mode) {
    const row = grid[cursor.row];
    if (!row) return;
    const from = mode === 1 ? 0 : mode === 2 ? 0 : cursor.col;
    const to = mode === 0 ? cols : mode === 1 ? cursor.col + 1 : cols;
    for (let c = from; c < to; c++) row[c] = blank();
  }

  function eraseInDisplay(mode) {
    if (mode === 2 || mode === 3) {
      // A clear clears, exactly as it does in a real terminal: nothing is
      // saved. An earlier version banked the doomed screen into scrollback and
      // tried to guess afterwards whether the clear was a resize-repaint
      // (delete the copy) or a real discard (keep it). The guess compared the
      // cleared rows against the repaint, and Claude's status line always
      // holds a ticking timer -- one character of drift and a whole stale
      // frame, input box and all, sat in scrollback forever. The harness
      // commits real history the one unambiguous way a terminal has: by
      // scrolling it off the top, where scrollUp banks it. What it clears,
      // it meant to clear.
      for (let r = 0; r < rows; r++) grid[r] = Array.from({ length: cols }, blank);
      return;
    }
    if (mode === 0) {
      eraseInLine(0);
      for (let r = cursor.row + 1; r < rows; r++) grid[r] = Array.from({ length: cols }, blank);
    } else if (mode === 1) {
      for (let r = 0; r < cursor.row; r++) grid[r] = Array.from({ length: cols }, blank);
      eraseInLine(1);
    }
  }

  function insertLines(n) {
    for (let i = 0; i < n; i++) {
      grid.splice(cursor.row, 0, Array.from({ length: cols }, blank));
      grid.splice(rows, 1);
    }
  }

  function deleteLines(n) {
    for (let i = 0; i < n; i++) {
      grid.splice(cursor.row, 1);
      grid.splice(rows - 1, 0, Array.from({ length: cols }, blank));
    }
  }

  // -- the parser ------------------------------------------------------------
  // A small state machine over bytes. `pending` holds a sequence split across
  // two chunks -- a real possibility, since a 64KB read can land anywhere.
  let pending = '';

  function write(text) {
    const data = pending + text;
    pending = '';
    let i = 0;

    while (i < data.length) {
      const ch = data[i];

      if (ch === '\x1b') {
        const consumed = escape(data, i);
        if (consumed === -1) {
          // Incomplete: keep it for the next chunk rather than misreading it.
          pending = data.slice(i);
          break;
        }
        i += consumed;
        continue;
      }

      if (ch === '\n') { wrapPending = false; newline(); i++; continue; }
      if (ch === '\r') { wrapPending = false; cursor.col = 0; i++; continue; }
      if (ch === '\b') { wrapPending = false; cursor.col = Math.max(0, cursor.col - 1); i++; continue; }
      if (ch === '\t') {
        wrapPending = false;
        cursor.col = Math.min(cols - 1, (Math.floor(cursor.col / 8) + 1) * 8);
        i++;
        continue;
      }
      if (ch === '\x07') { i++; continue; }              // bell: nothing to ring
      if (ch < ' ' && ch !== '\x1b') { i++; continue; }  // other C0: ignored

      // BY CODE POINT, not UTF-16 unit: an emoji is a surrogate pair, and
      // feeding putChar the halves painted two garbage cells. A high
      // surrogate at the end of the chunk waits for its partner exactly as a
      // split escape sequence does.
      const cp = data.codePointAt(i);
      if (cp >= 0xd800 && cp <= 0xdbff && i + 1 >= data.length) {
        pending = data.slice(i);
        break;
      }
      const glyph = String.fromCodePoint(cp);
      putChar(glyph);
      i += glyph.length;
    }

    if (sync) {
      // A frame is open: hold the paint for the l that closes it. The
      // backstop is for a frame that never closes -- a crash mid-repaint, an
      // l lost to a trimmed backlog -- because a held paint must never
      // become a frozen screen.
      if (syncTimer === null) {
        syncTimer = setTimeout(() => { syncTimer = null; sync = false; paint(); }, 250);
      }
      return;
    }
    paint();
  }

  // Returns how many characters the escape consumed, or -1 if it is not all
  // here yet.
  function escape(data, start) {
    const next = data[start + 1];
    if (next === undefined) return -1;

    // CSI: the one that matters. ESC [ params letter
    if (next === '[') {
      let i = start + 2;
      let raw = '';
      while (i < data.length && !/[a-zA-Z]/.test(data[i])) { raw += data[i]; i++; }
      if (i >= data.length) return -1;
      const final = data[i];
      csi(raw, final);
      return i - start + 1;
    }

    // OSC: ESC ] ... BEL or ESC \. Window titles, mostly -- consumed and
    // dropped, since a panel has its own title bar.
    if (next === ']') {
      let i = start + 2;
      while (i < data.length) {
        if (data[i] === '\x07') return i - start + 1;
        if (data[i] === '\x1b' && data[i + 1] === '\\') return i - start + 2;
        i++;
      }
      return -1;
    }

    // ESC ( B and friends: character set selection. Two bytes, ignored.
    if (next === '(' || next === ')' || next === '#') {
      if (data[start + 2] === undefined) return -1;
      return 3;
    }

    if (next === '7') { saved = { ...cursor, attr: { ...attr } }; return 2; }
    if (next === '8') {
      wrapPending = false;
      if (saved) { cursor.row = saved.row; cursor.col = saved.col; attr = { ...saved.attr }; }
      return 2;
    }
    if (next === 'M') {   // reverse index: up, scrolling if at the top
      wrapPending = false;
      if (cursor.row === 0) { grid.unshift(Array.from({ length: cols }, blank)); grid.splice(rows, 1); }
      else cursor.row--;
      return 2;
    }
    if (next === '=' || next === '>') return 2;  // keypad modes, ignored

    // Anything else: drop the ESC and carry on rather than stalling.
    return 2;
  }

  function csi(raw, final) {
    // `?` marks a private mode (?25l, ?2004h, ?2026h); `>` a secondary one.
    const priv = raw.startsWith('?');
    const body = priv || raw.startsWith('>') ? raw.slice(1) : raw;
    const params = body.split(';').map((p) => (p === '' ? 0 : parseInt(p, 10)))
                       .map((n) => (Number.isNaN(n) ? 0 : n));
    const p0 = params[0] === undefined ? 0 : params[0];
    const n = p0 === 0 ? 1 : p0;

    if (priv) {
      // The private modes both harnesses use. Cursor visibility changes what
      // is drawn; the mouse modes change where the wheel GOES; synchronized
      // output (2026) changes WHEN the paint happens; the alternate screen
      // (1049/1047) swaps the whole grid. Bracketed paste (2004) remains a
      // promise about input framing that changes nothing here.
      // One h/l can carry several modes.
      if (final === 'h' || final === 'l') {
        const on = final === 'h';
        for (const p of params) {
          if (p === 25) cursor.visible = on;
          else if (p === 1000 || p === 1002 || p === 1003) mouse.tracking = on;
          else if (p === 1006) mouse.sgr = on;
          else if (p === 1049 || p === 1047) {
            // ENTERING CLEARS, LEAVING RESTORES -- and ignoring this mode
            // was the margin garbage in the field: claude runs its TUI in
            // the alternate screen, the switch's implicit clear never
            // happened, and whatever predated claude stayed visible
            // wherever claude never painted.
            if (on && !altSaved) {
              altSaved = { grid, cursor: { ...cursor } };
              grid = [];
              for (let r = 0; r < rows; r++) {
                grid.push(Array.from({ length: cols }, blank));
              }
              cursor = { row: 0, col: 0, visible: cursor.visible };
              wrapPending = false;
            } else if (!on && altSaved) {
              grid = altSaved.grid;
              cursor = altSaved.cursor;
              altSaved = null;
              wrapPending = false;
              // The restored grid predates any resize made while inside.
              for (const row of grid) {
                while (row.length < cols) row.push(blank());
                row.length = cols;
              }
              while (grid.length < rows) grid.push(Array.from({ length: cols }, blank));
              while (grid.length > rows) grid.pop();
              cursor.row = Math.min(cursor.row, rows - 1);
              cursor.col = Math.min(cursor.col, cols - 1);
            }
          }
          else if (p === 2026) {
            sync = on;
            if (!on && syncTimer !== null) { clearTimeout(syncTimer); syncTimer = null; }
          }
        }
      }
      return;
    }

    // Any cursor motion or edit cancels an owed wrap, exactly as xterm
    // does; SGR (m) must NOT -- colour changes between the last column and
    // the wrap are routine.
    if ('ABCDEFGHfdJKLMP@Xsur'.includes(final)) wrapPending = false;
    switch (final) {
      case 'A': cursor.row = Math.max(0, cursor.row - n); break;
      case 'B': cursor.row = Math.min(rows - 1, cursor.row + n); break;
      case 'C': cursor.col = Math.min(cols - 1, cursor.col + n); break;
      case 'D': cursor.col = Math.max(0, cursor.col - n); break;
      case 'E': cursor.row = Math.min(rows - 1, cursor.row + n); cursor.col = 0; break;
      case 'F': cursor.row = Math.max(0, cursor.row - n); cursor.col = 0; break;
      case 'G': cursor.col = Math.min(cols - 1, n - 1); break;
      case 'H':
      case 'f':
        cursor.row = Math.min(rows - 1, (params[0] || 1) - 1);
        cursor.col = Math.min(cols - 1, (params[1] || 1) - 1);
        break;
      case 'J': eraseInDisplay(p0); break;
      case 'K': eraseInLine(p0); break;
      case 'L': insertLines(n); break;
      case 'M': deleteLines(n); break;
      case 'P': {  // delete characters, shifting the rest of the line left
        const row = grid[cursor.row];
        if (row) {
          row.splice(cursor.col, n);
          while (row.length < cols) row.push(blank());
        }
        break;
      }
      case '@': {  // insert blanks, shifting right
        const row = grid[cursor.row];
        if (row) {
          for (let i = 0; i < n; i++) row.splice(cursor.col, 0, blank());
          row.length = cols;
        }
        break;
      }
      case 'X': {  // erase n characters in place
        for (let i = 0; i < n; i++) {
          const target = cell(cursor.row, cursor.col + i);
          if (target) Object.assign(target, blank());
        }
        break;
      }
      case 'd': cursor.row = Math.min(rows - 1, n - 1); break;
      case 'm': applySGR(params); break;
      case 'r': break;   // scroll region: unused by both harnesses
      case 's': saved = { ...cursor, attr: { ...attr } }; break;
      case 'u':
        if (saved) { cursor.row = saved.row; cursor.col = saved.col; attr = { ...saved.attr }; }
        break;
      default: break;
    }
  }

  // -- painting --------------------------------------------------------------
  // The whole grid, rebuilt into spans. Runs of identical styling are merged,
  // which is what keeps this from producing one element per character.

  function styleOf(c) {
    if (!c) return '';
    let fg = c.fg, bg = c.bg;
    // Inverse with no colours of its own swaps against the panel's own ink and
    // ground. --term-ground rather than --term: that one is translucent, and a
    // highlight you can see the graph through is not a highlight.
    if (c.inverse) { const t = fg; fg = bg || 'var(--term-ink)'; bg = t || 'var(--term-ground)'; }
    const parts = [];
    if (fg) parts.push(`color:${fg}`);
    if (bg) parts.push(`background:${bg}`);
    if (c.bold) parts.push('font-weight:600');
    if (c.dim) parts.push('opacity:.6');
    if (c.underline) parts.push('text-decoration:underline');
    return parts.join(';');
  }

  // Coalesce bursts: a harness emits many chunks per frame, and painting each
  // one separately is work the user cannot perceive. Falls back to painting
  // immediately where there are no frames -- which is what makes the emulator
  // testable outside a browser, since everything above this line is pure.
  const hasFrames = typeof requestAnimationFrame === 'function';

  let painting = false;
  let timer = null;

  // A TIMER BACKS THE FRAME UP, and it is not belt-and-braces -- it is the
  // difference between a terminal that works in a background tab and one that
  // does not.
  //
  // requestAnimationFrame DOES NOT FIRE in a hidden tab: browsers throttle it
  // to nothing. The first version scheduled the paint on rAF alone and cleared
  // its `painting` guard inside the callback, so a terminal that received
  // output while hidden set the guard, never ran the callback, and never
  // painted again -- the guard stayed true even after the tab came back. The
  // symptom was a screen frozen mid-session with the cursor still blinking,
  // because the blink is CSS and knows nothing about any of this.
  //
  // So whichever of the two arrives first paints, and both clear the guard.
  // 100ms is slower than a frame and far faster than a person notices.
  // Each scheduling round gets its own ticket. A hidden tab's rAF callbacks
  // are not cancelled, only deferred -- they all fire at once when the tab is
  // shown again -- so a callback must be able to tell "I am the paint that was
  // scheduled" from "I am a straggler from three paints ago". Without that,
  // a late arrival clears the guard belonging to a paint still pending, and
  // the screen stops updating a second time.
  let ticket = 0;

  function paint() {
    if (painting) return;
    painting = true;
    const mine = ++ticket;

    const run = () => {
      if (mine !== ticket || !painting) return;  // stale, or already painted
      painting = false;
      if (timer !== null) { clearTimeout(timer); timer = null; }
      const [lines, changed, shift] = render();
      // After, not before: a caller following the output needs the DOM to
      // have its new height when it decides where to scroll. The line count
      // rides along so the caller can tell whether the height CAN have moved
      // without reading the layout to find out; `changed` says whether this
      // paint moved any ink at all, and `shift` whether it moved existing
      // rows to new indices -- a transcript scrolling, as opposed to
      // changing in place.
      if (options.onPaint) options.onPaint(lines, changed, shift);
    };

    // THE FRAME PACES THE VISIBLE TAB. A real terminal does not render per
    // chunk: it mutates a screen model as bytes arrive and samples it at the
    // display's own rhythm, which is why iTerm is smooth under the same
    // stream. An earlier version raced this rAF against a zero timer to
    // shave the keystroke echo, and the timer won every time -- so a scroll
    // burst, arriving as dozens of chunks a second, rebuilt the whole DOM at
    // macrotask rate and the pane visibly janked. Renders now wait for the
    // frame -- at most one per refresh, ~16ms worst case on the echo, which
    // is the same beat every native terminal draws on.
    //
    // The timer stays, at slower-than-a-frame, because rAF DOES NOT FIRE in
    // a hidden tab: without the backup, output received while hidden set the
    // `painting` guard, never painted, and the screen stayed frozen after
    // the tab came back -- cursor still blinking, because the blink is CSS.
    if (hasFrames) {
      requestAnimationFrame(run);
      timer = setTimeout(run, 40);
    } else {
      // With no frames at all -- node, a test -- callers expect the paint to
      // have happened by the time `write` returns.
      run();
    }
  }

  function render() {
    const withCursor = options.showCursor !== false && cursor.visible;

    if (dom) {
      // ONLY THE GRID, AND ONLY ITS DIRTY ROWS. History was rendered row by
      // row as it was banked and is never touched here; the live rows keep
      // their last serialization alongside, and a paint writes just the rows
      // whose HTML differs. The cost of a typical frame is one or two divs,
      // not twenty-four -- and `changed` (whether ANY row moved) is part of
      // the paint's story: the glide in app.js must fire on a repaint that
      // moved content and not on one that re-drew the same frame (a mouse
      // report echoed back as invisible CSI).
      const out = [];
      for (let r = 0; r < grid.length; r++) {
        out.push(rowHTML(grid[r], withCursor && r === cursor.row ? cursor.col : null));
      }
      // Blank lines at the bottom are noise, but the cursor's line must stay.
      let last = out.length - 1;
      while (last > cursor.row && out[last] === '') last--;
      const want = last + 1;
      // DID THE FRAME SCROLL? A program answering wheel reports moves
      // EXISTING rows to new indices; a status tick or a streaming token
      // changes rows in place. The distinction is the only trustworthy
      // consumption signal the wheel pacing in app.js has -- paints that
      // merely changed something turned out to fire constantly while an
      // agent works, and pacing on them flooded the pty (that story is
      // told at the wheel handler). Detected by the dominant row shift:
      // the d for which most non-empty new rows equal the old row d
      // further down, required to beat the rows that did NOT move so a
      // ticking status line or a near-uniform screen cannot fake it.
      let shift = 0;
      {
        let zero = 0;
        for (let r = 0; r < want; r++) {
          if (out[r] !== '' && liveHTML[r] === out[r]) zero++;
        }
        let best = 0, bestCount = 0;
        for (let d = -8; d <= 8; d++) {
          if (d === 0) continue;
          let count = 0;
          for (let r = 0; r < want; r++) {
            const prev = liveHTML[r + d];
            if (out[r] !== '' && prev !== undefined && prev === out[r]) count++;
          }
          if (count > bestCount) { bestCount = count; best = d; }
        }
        if (bestCount > zero && bestCount >= 3) shift = best;
      }
      let changed = false;
      while (liveDivs.length > want) {
        liveEl.removeChild(liveDivs.pop());
        liveHTML.pop();
        changed = true;
      }
      for (let r = 0; r < want; r++) {
        if (r >= liveDivs.length) {
          const div = doc.createElement('div');
          div.innerHTML = out[r];
          liveEl.appendChild(div);
          liveDivs.push(div);
          liveHTML.push(out[r]);
          changed = true;
        } else if (liveHTML[r] !== out[r]) {
          liveDivs[r].innerHTML = out[r];
          liveHTML[r] = out[r];
          changed = true;
        }
      }
      return [scrollback.length + want, changed, shift];
    }

    // Headless: the whole view as one string, exactly as before the split.
    const all = options.scrollbackVisible === false
      ? grid
      : scrollback.concat(grid);
    const cursorRow = scrollback.length + cursor.row;
    const out = [];
    for (let r = 0; r < all.length; r++) {
      out.push(rowHTML(all[r], withCursor && r === cursorRow ? cursor.col : null));
    }
    let last = out.length - 1;
    while (last > cursorRow && out[last] === '') last--;
    screen.innerHTML = out.slice(0, last + 1).join('\n');
    return [last + 1, true, 0];
  }

  function escapeHtml(text) {
    return text.replace(/[&<>]/g, (c) => (c === '&' ? '&amp;' : c === '<' ? '&lt;' : '&gt;'));
  }

  function resize(nextRows, nextCols) {
    if (nextRows === rows && nextCols === cols) return false;
    rows = Math.max(1, nextRows);
    cols = Math.max(1, nextCols);
    // Reflow by truncating or padding rather than rewrapping: the harness
    // redraws on SIGWINCH anyway, so any effort spent rewrapping is thrown
    // away a frame later.
    for (const row of grid) {
      while (row.length < cols) row.push(blank());
      row.length = cols;
    }
    while (grid.length < rows) grid.push(Array.from({ length: cols }, blank));
    while (grid.length > rows) bankRow(grid.shift());
    cursor.row = Math.min(cursor.row, rows - 1);
    cursor.col = Math.min(cursor.col, cols - 1);
    paint();
    return true;
  }

  return {
    write,
    resize,
    reset() {
      reset();
      scrollback = [];
      if (dom) {
        historyEl.innerHTML = '';
        liveEl.innerHTML = '';
        liveDivs = [];
        liveHTML = [];
      }
      mouse = { tracking: false, sgr: false };
      sync = false;
      if (syncTimer !== null) { clearTimeout(syncTimer); syncTimer = null; }
      paint();
    },
    get rows() { return rows; },
    get cols() { return cols; },
    // True when wheel events belong to the program, as SGR reports.
    get mouseReporting() { return mouse.tracking && mouse.sgr; },
    get cursor() { return { ...cursor }; },
    // Exposed for tests: the visible screen as plain text, one string per row.
    text() { return grid.map((row) => row.map((c) => c.ch).join('').replace(/\s+$/, '')); },
  };
}

// -- keyboard ----------------------------------------------------------------
// Turning a KeyboardEvent into the bytes a terminal program expects. This is
// the other half of the emulator and is mostly a lookup table.

export function keyToBytes(event) {
  const k = event.key;

  // The command key belongs to the browser, not the program: no terminal on a
  // Mac sends Cmd-anything to the pty. Claiming these -- and the keydown
  // handler preventDefaults whatever this claims -- is what silently ate
  // Cmd-V, because cancelling that keydown cancels the paste it triggers.
  if (event.metaKey) return '';

  // Ctrl-letter becomes the control code, which is how Ctrl-C reaches the
  // program as an interrupt rather than as the letter C.
  if (event.ctrlKey && k.length === 1) {
    const upper = k.toUpperCase();
    if (upper >= 'A' && upper <= 'Z') {
      return String.fromCharCode(upper.charCodeAt(0) - 64);
    }
    if (k === ' ') return '\x00';
  }

  // Alt sends the key prefixed with ESC, which is how meta bindings work.
  if (event.altKey && k.length === 1) return '\x1b' + k;

  switch (k) {
    case 'Enter': return '\r';
    case 'Backspace': return '\x7f';
    case 'Tab': return event.shiftKey ? '\x1b[Z' : '\t';
    case 'Escape': return '\x1b';
    case 'ArrowUp': return '\x1b[A';
    case 'ArrowDown': return '\x1b[B';
    case 'ArrowRight': return '\x1b[C';
    case 'ArrowLeft': return '\x1b[D';
    case 'Home': return '\x1b[H';
    case 'End': return '\x1b[F';
    case 'PageUp': return '\x1b[5~';
    case 'PageDown': return '\x1b[6~';
    case 'Delete': return '\x1b[3~';
    case 'Insert': return '\x1b[2~';
    default: break;
  }

  // A single printable character goes as itself. Anything longer is a named
  // key this table does not cover, and sending its name would type garbage.
  if (k.length === 1) return k;
  return '';
}
