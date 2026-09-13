export function prepareTables(article, file) {
  const occurrences = new Map();
  for (const table of article.querySelectorAll('table')) {
    const headers = [...table.querySelectorAll('thead tr:first-child th')];
    const signature = JSON.stringify(headers.map(cell => cell.textContent));
    const occurrence = occurrences.get(signature) || 0;
    occurrences.set(signature, occurrence + 1);
    const key = 'visualize:markdown-columns:' + JSON.stringify([file, signature, occurrence]);
    let widths = headers.map(() => null);
    try {
      const saved = JSON.parse(localStorage.getItem(key));
      if (Array.isArray(saved) && saved.length === widths.length) {
        widths = saved.map(value => Number.isFinite(value) && value >= 64 && value <= 4000 ? value : null);
      }
    } catch {}
    const scroll = document.createElement('div');
    scroll.className = 'markdown-table';
    scroll.tabIndex = 0;
    scroll.setAttribute('role', 'region');
    scroll.setAttribute('aria-label', 'Scrollable table');
    table.before(scroll);
    scroll.append(table);
    if (!headers.length) continue;
    const group = document.createElement('colgroup');
    const columns = headers.map(() => group.appendChild(document.createElement('col')));
    table.prepend(group);
    const handles = [];
    let measured = [];
    function apply(values) {
      table.classList.add('sized-columns');
      table.style.width = values.reduce((sum, value) => sum + value, 0) + 'px';
      columns.forEach((column, index) => {
        column.style.width = values[index] + 'px';
        handles[index]?.setAttribute('aria-valuenow', String(Math.round(values[index])));
      });
    }
    function layout() {
      table.classList.remove('sized-columns');
      table.style.width = '';
      columns.forEach(column => { column.style.width = ''; });
      measured = headers.map(cell => cell.getBoundingClientRect().width);
      if (widths.some(value => value !== null)) apply(measured.map((value, index) => widths[index] ?? value));
    }
    function save() {
      try {
        if (widths.every(value => value === null)) localStorage.removeItem(key);
        else localStorage.setItem(key, JSON.stringify(widths));
      } catch {}
    }
    headers.forEach((cell, index) => {
      const handle = document.createElement('span');
      handle.className = 'markdown-column-resize';
      handle.tabIndex = 0;
      handle.setAttribute('role', 'separator');
      handle.setAttribute('aria-orientation', 'vertical');
      handle.setAttribute('aria-label', 'Resize ' + (cell.textContent.trim() || 'column ' + (index + 1)));
      handle.setAttribute('aria-valuemin', '64');
      handle.setAttribute('aria-valuemax', '4000');
      handle.title = 'Drag to resize. Double-click to reset. Arrow keys adjust; Home resets.';
      cell.append(handle);
      handles.push(handle);
      function reset() {
        widths[index] = null;
        layout();
        save();
      }
      handle.addEventListener('dblclick', event => { event.preventDefault(); event.stopPropagation(); reset(); });
      handle.addEventListener('pointerdown', event => {
        if (event.button !== 0) return;
        event.preventDefault();
        event.stopPropagation();
        const start = event.clientX;
        const before = widths[index];
        const values = headers.map(header => header.getBoundingClientRect().width);
        const initial = values[index];
        handle.setPointerCapture(event.pointerId);
        handle.classList.add('dragging');
        const move = next => {
          values[index] = Math.max(64, Math.min(4000, initial + next.clientX - start));
          widths[index] = values[index];
          apply(values);
        };
        const finish = end => {
          handle.removeEventListener('pointermove', move);
          handle.removeEventListener('pointerup', finish);
          handle.removeEventListener('pointercancel', finish);
          handle.classList.remove('dragging');
          if (end.type === 'pointercancel') { widths[index] = before; layout(); }
          else save();
        };
        handle.addEventListener('pointermove', move);
        handle.addEventListener('pointerup', finish);
        handle.addEventListener('pointercancel', finish);
      });
      handle.addEventListener('keydown', event => {
        if (!['ArrowLeft', 'ArrowRight', 'Home'].includes(event.key)) return;
        event.preventDefault();
        event.stopPropagation();
        if (event.key === 'Home') { reset(); return; }
        const values = headers.map(header => header.getBoundingClientRect().width);
        values[index] = Math.max(64, Math.min(4000, values[index] + (event.key === 'ArrowLeft' ? -1 : 1) * (event.shiftKey ? 4 : 20)));
        widths[index] = values[index];
        apply(values);
        save();
      });
    });
    layout();
  }
}
