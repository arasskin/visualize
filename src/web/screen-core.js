const blank = Object.freeze({ char: 32, fg: 256, bg: 256, flags: 0, width: 1 });

function decodeLine(encoded) {
  const bytes = Uint8Array.from(atob(encoded), c => c.charCodeAt(0));
  if (bytes.length % 40) throw new Error('invalid terminal row');
  const view = new DataView(bytes.buffer);
  const cells = [];
  for (let offset = 0; offset < bytes.length; offset += 40) {
    const characters = [];
    for (let i = 0; i < 6; i++) {
      const codepoint = view.getUint32(offset + i * 4, true);
      if (!codepoint || codepoint === 0xffffffff) break;
      characters.push(codepoint);
    }
    const fg = view.getUint32(offset + 32, true);
    const bg = view.getUint32(offset + 36, true);
    const cell = { char: characters[0] || 32, fg: fg <= 256 ? fg : 256,
      bg: bg <= 256 ? bg : 256, flags: view.getUint32(offset + 28, true),
      width: view.getUint32(offset + 24, true) };
    if (characters.length > 1) cell.chars = String.fromCodePoint(...characters);
    if (fg > 256) cell.fgRgb = fg & 0xffffff;
    if (bg > 256) cell.bgRgb = bg & 0xffffff;
    cells.push(cell);
  }
  return cells;
}

export class ScreenCore {
  constructor() { this.reset(); }
  reset() {
    this.rows = 24; this.cols = 80; this.lines = []; this.history = new Map();
    this.historyStart = 0; this.historyCount = 0; this.dirty = new Set();
    this.cursor = { row: 0, col: 0, visible: false }; this.modes = [];
    this.alternate = false; this.title = '';
  }
  init(cols, rows) { this.cols = cols; this.rows = rows; }
  resize() {}
  apply(screen) {
    if (screen.version !== 1) throw new Error('unsupported terminal screen protocol');
    const resized = this.cols !== screen.cols || this.rows !== screen.rows;
    if (resized) { this.lines = []; for (let r = 0; r < screen.rows; r++) this.dirty.add(r); }
    this.rows = screen.rows; this.cols = screen.cols;
    this.dirty.add(this.cursor.row); this.dirty.add(screen.cursor.row);
    this.cursor = screen.cursor; this.modes = screen.modes;
    this.title = screen.title; this.alternate = screen.alternate;
    for (const [row, encoded] of screen.lines) { this.lines[row] = decodeLine(encoded); this.dirty.add(row); }
    const history = screen.history;
    this.historyStart = history.start; this.historyCount = history.count;
    for (const key of this.history.keys()) if (key < history.start || key >= history.start + history.count) this.history.delete(key);
    for (const [key, encoded] of history.lines) this.history.set(key, decodeLine(encoded));
  }
  getCell(row, col) { return this.lines[row]?.[col] || blank; }
  getRows() { return this.rows; }
  getCols() { return this.cols; }
  getCursor() { return this.cursor; }
  isDirtyRow(row) { return this.dirty.has(row); }
  clearDirty() { this.dirty.clear(); }
  getScrollbackCount() { return this.alternate ? 0 : this.historyCount; }
  getScrollbackDiscardedCount() { return this.historyStart; }
  historyLine(offset) { return this.history.get(this.historyStart + this.historyCount - 1 - offset); }
  getScrollbackCell(offset, col) { return this.historyLine(offset)?.[col] || blank; }
  getScrollbackLineLen(offset) { return this.historyLine(offset)?.length || 0; }
  cursorKeysApp() { return !!this.modes[0]; }
  bracketedPaste() { return !!this.modes[1]; }
  mouseTracking() { return [0, 1000, 1002, 1003][this.modes[2]] || 0; }
  mouseSgr() { return !!this.modes[3]; }
  focusEvents() { return !!this.modes[4]; }
  usingAltScreen() { return this.alternate; }
  kittyKeyboardFlags() { return 0; }
  getTitle() { return this.title; }
}
