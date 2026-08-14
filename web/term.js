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
                         underline: false, inverse: false });

  let grid = [];
  let cursor = { row: 0, col: 0, visible: true };
  let saved = null;
  // Pending attributes, applied to every cell written until they change.
  let attr = { fg: null, bg: null, bold: false, dim: false, underline: false,
               inverse: false };
  // Rows the harness has scrolled off the top. Kept so the pane can be
  // scrolled back, which a graph tool's user will expect even though a real
  // terminal in its default mode has no scrollback of its own.
  let scrollback = [];
  const scrollbackLimit = options.scrollback || 2000;

  function reset() {
    grid = [];
    for (let r = 0; r < rows; r++) {
      grid.push(Array.from({ length: cols }, blank));
    }
    cursor = { row: 0, col: 0, visible: true };
  }
  reset();

  function cell(r, c) {
    if (r < 0 || r >= rows || c < 0 || c >= cols) return null;
    return grid[r][c];
  }

  function scrollUp() {
    const gone = grid.shift();
    scrollback.push(gone);
    if (scrollback.length > scrollbackLimit) scrollback.shift();
    grid.push(Array.from({ length: cols }, blank));
  }

  function newline() {
    cursor.row++;
    if (cursor.row >= rows) {
      cursor.row = rows - 1;
      scrollUp();
    }
  }

  function putChar(ch) {
    // Wrap at the right edge rather than overwriting the last column, which
    // is what a terminal does and what the harnesses assume when they draw
    // a full-width box.
    if (cursor.col >= cols) {
      cursor.col = 0;
      newline();
    }
    const target = cell(cursor.row, cursor.col);
    if (target) {
      target.ch = ch;
      target.fg = attr.fg;
      target.bg = attr.bg;
      target.bold = attr.bold;
      target.dim = attr.dim;
      target.underline = attr.underline;
      target.inverse = attr.inverse;
    }
    cursor.col++;
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

      if (ch === '\n') { newline(); i++; continue; }
      if (ch === '\r') { cursor.col = 0; i++; continue; }
      if (ch === '\b') { cursor.col = Math.max(0, cursor.col - 1); i++; continue; }
      if (ch === '\t') {
        cursor.col = Math.min(cols - 1, (Math.floor(cursor.col / 8) + 1) * 8);
        i++;
        continue;
      }
      if (ch === '\x07') { i++; continue; }              // bell: nothing to ring
      if (ch < ' ' && ch !== '\x1b') { i++; continue; }  // other C0: ignored

      putChar(ch);
      i++;
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
      if (saved) { cursor.row = saved.row; cursor.col = saved.col; attr = { ...saved.attr }; }
      return 2;
    }
    if (next === 'M') {   // reverse index: up, scrolling if at the top
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
      // The private modes both harnesses use. Cursor visibility is the only
      // one with a visible effect here: bracketed paste (2004) and
      // synchronized output (2026) are promises to the program about how
      // input arrives and how frames are batched, and honouring them changes
      // nothing about what is drawn.
      if (final === 'h' || final === 'l') {
        if (p0 === 25) cursor.visible = final === 'h';
      }
      return;
    }

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
      render();
      // After, not before: a caller following the output needs the DOM to
      // have its new height when it decides where to scroll.
      if (options.onPaint) options.onPaint();
    };

    // The frame is the fast path and paints within ~16ms when the tab is
    // visible. The timer only exists to cover the case where no frame is
    // coming, so its delay must not become the thing a visible tab waits for
    // -- 100ms here was adding most of a tenth of a second to every keystroke
    // echo. Zero lets the browser coalesce the two naturally: whichever runs
    // first paints, and a visible tab almost always sees the frame.
    if (hasFrames) requestAnimationFrame(run);
    timer = setTimeout(run, 0);
    // With no frames at all -- node, a test -- a zero timeout is still
    // asynchronous, and callers expect the paint to have happened by the time
    // `write` returns. So do it now and let the timer find nothing to do.
    if (!hasFrames) run();
  }

  function render() {
    const out = [];
    const all = options.scrollbackVisible === false
      ? grid
      : scrollback.concat(grid);
    const cursorRow = scrollback.length + cursor.row;

    for (let r = 0; r < all.length; r++) {
      const row = all[r];
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
        const isCursor = options.showCursor !== false
          && cursor.visible && r === cursorRow && c === cursor.col;
        const style = styleOf(row[c]);
        if (isCursor) {
          flush();
          line += `<span class="cursor">${escapeHtml(row[c].ch)}</span>`;
          runStyle = null;
          continue;
        }
        if (style !== runStyle) { flush(); runStyle = style; }
        run += row[c].ch;
      }
      flush();
      // Trailing blanks are dropped: they render identically and a full-width
      // grid of spaces is most of the bytes on a mostly-empty screen.
      out.push(line.replace(/\s+$/, ''));
    }

    // Blank lines at the bottom are noise, but the cursor's line must stay.
    let last = out.length - 1;
    while (last > cursorRow && out[last] === '') last--;
    screen.innerHTML = out.slice(0, last + 1).join('\n');
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
    while (grid.length > rows) scrollback.push(grid.shift());
    cursor.row = Math.min(cursor.row, rows - 1);
    cursor.col = Math.min(cursor.col, cols - 1);
    paint();
    return true;
  }

  return {
    write,
    resize,
    reset() { reset(); scrollback = []; paint(); },
    get rows() { return rows; },
    get cols() { return cols; },
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
