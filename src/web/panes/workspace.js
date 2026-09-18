import {createPaneFrame} from './frame.js';
import {createPaneLayout} from './layout.js';
import {createPanePersistence} from './persistence.js';
import {terminalContent} from '../terminal/content.js';
import {documentReader} from '../documents/document.js';
import {reportError} from '../shared/errors.js';
import * as transport from '../shared/transport.js';

export function createWorkspace({template, initial = [], positions = {}, labels = {}, documentOptions = {}, onSelect = () => {}}) {
  const panels = new Map();
  const closing = new Map();
  let remote = new Set(), selected = null, nextId = 1, topmost = 5;
  const all = () => [...panels.values()];
  const layout = createPaneLayout({getPanels: all, getSelected: () => selected, onChange: () => persistence.changed()});
  const persistence = createPanePersistence(all, layout);
  function changed() { layout.packRail(); persistence.changed(); }
  function selectPane(root) {
    if (selected?.root === root) return;
    selected?.root.classList.remove('picked');
    selected = all().find(panel => panel.root === root) || null;
    if (selected) { selected.root.classList.add('picked'); selected.root.style.zIndex = ++topmost; }
    layout.revealTab(selected); onSelect(selected);
  }
  async function saveLabel(id, text) {
    try {
      const response = await fetch(`/label?k=${encodeURIComponent(window.TOKEN)}`, {
        method: 'POST', body: JSON.stringify({id, text}),
      });
      if (!response.ok) throw new Error('could not save pane title');
    } catch (error) { reportError(error, {pane: id, phase: 'label'}); }
  }
  function closePanel(panel, remotely = false) {
    if (!panels.has(panel.id)) return;
    layout.removeFromRail(panel); panels.delete(panel.id);
    if (selected === panel) selectPane(all()[0]?.root);
    let finished = Promise.resolve();
    if (remotely) panel.detach();
    else {
      closing.set(panel.id, false);
      finished = panel.stop().finally(() => closing.set(panel.id, true));
    }
    panel.dispose(); panel.root.remove(); changed();
    return finished;
  }
  function createPane({id = String(++nextId), file, launch = {}, remote: hasSession = true, width, height, minWidth, minHeight, name} = {}) {
    id = String(id);
    if (panels.has(id)) return panels.get(id);
    const numeric = Number(id); if (Number.isFinite(numeric)) nextId = Math.max(nextId, numeric);
    const root = template.content.firstElementChild.cloneNode(true);
    root.id = /^(config|harness)$/.test(id) ? id : 'pane-' + id;
    document.body.append(root);
    let content = null, disposed = false, settling = Promise.resolve();
    const panel = createPaneFrame(root, {
      width: width || (file ? 'min(26rem, 92vw)' : 'min(52rem, 94vw)'),
      height: height || (file ? '22rem' : '24rem'), minWidth: minWidth || (file ? 240 : 360), minHeight: minHeight || (file ? 120 : 200),
      onRaise: () => { root.style.zIndex = ++topmost; }, onChange: changed,
      onDrag: layout.railDrag, onDrop: layout.railDrop,
      onResizeMove: layout.resizeMove, onResizeEnd: layout.resizeEnd,
      onClose: closePanel, onLabel: text => saveLabel(id, text),
      onOpen: () => content?.focus(), onShut: () => content?.shut?.(), onResize: () => content?.resize?.(),
    });
    panel.id = id;
    panels.set(id, panel);
    panel.showDocument = nextFile => {
      if (disposed || panel.documentFile === nextFile) return;
      settling = content?.settled?.() || settling;
      content?.detach?.(); content?.stop?.();
      panel.body.replaceChildren(); panel.documentFile = nextFile;
      root.classList.add('document-pane'); root.classList.remove('terminal-pane');
      root.querySelector('.state').textContent = '';
      root.querySelector('.name').textContent = nextFile.split('/').pop();
      content = documentReader(panel, id, nextFile, documentOptions);
      if (!panel.shut && selected === panel) content.focus();
    };
    panel.boot = () => disposed ? Promise.resolve(false) : content?.boot?.() || Promise.resolve(false);
    panel.type = text => content?.type?.(text);
    panel.detach = () => {
      if (disposed) return;
      disposed = true; settling = content?.settled?.() || settling;
      content?.detach?.(); content?.stop?.(); content = null;
    };
    panel.stop = async () => {
      panel.detach(); await settling;
      if (!hasSession) return;
      try { await transport.request(id, 'shutdown'); }
      catch (error) { reportError(error, {pane: id, phase: 'close'}); }
    };
    panel.setLabel(labels[id] || '');
    if (file) panel.showDocument(file);
    else {
      root.classList.add('terminal-pane');
      root.querySelector('.name').textContent = name || 'terminal ' + id;
      content = terminalContent(panel, id, launch);
    }
    return panel;
  }
  function syncPanes(ids, titles = {}, documents = {}) {
    labels = titles;
    const wanted = new Set(ids);
    for (const [id, finished] of closing) {
      if (finished && !wanted.has(id)) closing.delete(id);
      else wanted.delete(id);
    }
    for (const panel of all()) if (remote.has(panel.id) && !wanted.has(panel.id)) closePanel(panel, true);
    for (const id of wanted) if (!panels.has(id)) {
      const panel = createPane({id, file: documents[id], launch: {recover: true}});
      layout.addToRail(panel); panel.boot();
    }
    for (const panel of all()) {
      if (documents[panel.id]) panel.showDocument(documents[panel.id]);
      if (document.activeElement !== panel.label) panel.setLabel(labels[panel.id] || '');
    }
    remote = wanted;
  }
  function openTerminal(side = 'bottom') {
    const panel = createPane(); selectPane(panel.root); layout.addToRail(panel, undefined, side);
    panel.boot(); panel.open(); return panel;
  }
  function openFileTerminal(file, command, position) {
    const panel = createPane({launch: {node: file.name, file: file.file, command}});
    selectPane(panel.root); panel.open();
    panel.place(Math.max(6, Math.min(position.x, innerWidth - panel.root.offsetWidth - 6)),
      Math.max(6, Math.min(position.y, innerHeight - panel.root.offsetHeight - 6)));
    persistence.changed(); return panel;
  }
  document.addEventListener('pointerdown', event => {
    const root = event.target.closest?.('.panel'); if (root) selectPane(root);
  }, true);
  document.addEventListener('keydown', event => {
    if (event.key !== 'Escape' || !selected?.documentFile || selected.shut || !selected.root.contains(document.activeElement)) return;
    event.preventDefault(); document.activeElement.blur(); selected.toggle();
  });
  for (const description of initial) {
    const panel = createPane(description);
    layout.addToRail(panel, undefined, description.rail || 'bottom');
    if (description.open) panel.open();
    panel.boot();
  }
  persistence.restore(positions); persistence.start();
  selectPane(all()[0]?.root);
  const instance = {get: id => panels.get(id), get all() { return all(); }, ...layout,
    createPane, closePanel, selectPane, pickedPanel: () => selected, syncPanes, openTerminal, openFileTerminal};
  return instance;
}
