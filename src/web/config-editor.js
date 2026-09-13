export function configReader(panel, id, file) {
  const viewport = document.createElement('div');
  viewport.className = 'config-document';
  const status = document.createElement('div'); status.className = 'config-document-status';
  const rows = document.createElement('div'); rows.className = 'config-document-lines';
  viewport.append(status, rows); panel.body.append(viewport);
  let lines = [], dirty = false, stopped = false, timer, pending, revision = 0;
  function clean(value) {
    const out = Array.from(value || [], String);
    while (out.length && out[out.length - 1].trim() === '') out.pop();
    return out;
  }
  function draw() {
    rows.replaceChildren();
    lines.forEach((line, index) => {
      const row = document.createElement('div'); row.className = 'config-document-row';
      const input = document.createElement('input'); input.value = line; input.spellcheck = false;
      input.addEventListener('input', () => { lines[index] = input.value; dirty = true; ++revision; });
      input.addEventListener('keydown', event => { if (event.key === 'Enter') { event.preventDefault(); save(); } });
      const actions = document.createElement('span'); actions.className = 'config-document-actions';
      [['↑', 'insert-above'], ['↓', 'insert-below'], ['#', 'comment'], ['✕', 'delete']].forEach(([label, action]) => {
        const button = document.createElement('button'); button.type = 'button'; button.textContent = label;
        button.addEventListener('click', () => {
          pending?.abort();
          dirty = true; ++revision;
          if (action === 'comment') { const current = lines[index] || ''; lines[index] = current.trim().startsWith('#') ? current.replace(/^\s*# ?/, '') : '#' + current; commit(); }
          else if (action === 'delete') { lines.splice(index, 1); commit(); }
          else if (action === 'insert-above') { lines.splice(index, 0, ''); commit(); }
          else if (action === 'insert-below') { lines.splice(index + 1, 0, ''); commit(); }
          else commit(action, index);
        }); actions.append(button);
      });
      row.append(input, actions); rows.append(row);
    });
  }
  async function load() {
    if (stopped || dirty || panel.shut || document.hidden) return;
    const requestedRevision = revision;
    pending = new AbortController();
    const response = await fetch(`/config?k=${encodeURIComponent(window.TOKEN)}`, {
      method: 'POST', body: JSON.stringify({action: 'reload', index: -1, lines: [], file}), signal: pending.signal,
    });
    if (!response.ok) throw new Error('Unable to read configuration file');
    const result = await response.json();
    if (!result.lines) throw new Error(result.error || 'Unable to read configuration file');
    if (dirty || requestedRevision !== revision) return;
    const nextLines = clean(result.lines);
    if (nextLines.length === lines.length && nextLines.every((line, index) => line === lines[index])) {
      status.textContent = '';
      return;
    }
    lines = nextLines; draw(); status.textContent = '';
  }
  async function commit(action = 'run', index = -1) {
    if (stopped) return;
    const committedRevision = revision;
    try {
      const response = await fetch(`/config?k=${encodeURIComponent(window.TOKEN)}`, {
        method: 'POST', body: JSON.stringify({action, index, lines, file}),
      });
      if (!response.ok) throw new Error('Unable to save configuration file');
      const result = await response.json();
      if (!result.lines) throw new Error(result.error || 'Unable to save configuration file');
      if (committedRevision !== revision) return;
      lines = clean(result.lines); dirty = false; draw(); status.textContent = result.error || '';
    } catch (error) { status.textContent = error.message; }
  }
  const save = () => commit();
  async function refresh() {
    try { await load(); } catch (error) { if (!stopped && error.name !== 'AbortError') status.textContent = error.message; }
    if (!stopped) timer = setTimeout(refresh, 1000);
  }
  refresh();
  return { focus: () => rows.querySelector('input')?.focus({preventScroll: true}), stop() { stopped = true; clearTimeout(timer); pending?.abort(); viewport.remove(); } };
}
