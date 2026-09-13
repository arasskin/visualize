import { configCompletions } from './config-completion.js';
import { svgViewport } from './graph-viewport.js';
import { configSearch } from './config-search.js';

export function configReader(panel, id, file) {
  const viewport = document.createElement('div'); viewport.className = 'config-document';
  const controls = document.createElement('div'); controls.className = 'config-toolbar';
  const toolbar = document.createElement('form'); toolbar.className = 'config-command';
  const input = document.createElement('input');
  input.placeholder = 'Add a command…'; input.spellcheck = false; input.autocomplete = 'off';
  input.setAttribute('aria-label', 'Add a configuration command'); input.setAttribute('role', 'combobox');
  input.setAttribute('aria-autocomplete', 'list'); input.setAttribute('aria-expanded', 'false');
  const list = document.createElement('ul'); list.className = 'config-completions'; list.hidden = true;
  list.id = `config-completions-${id}`; list.setAttribute('role', 'listbox'); input.setAttribute('aria-controls', list.id);
  const status = document.createElement('div'); status.className = 'config-document-status'; status.setAttribute('role', 'status');
  const canvas = document.createElement('div'); canvas.className = 'config-diagram';
  toolbar.append(input, list); controls.append(toolbar); viewport.append(controls, status, canvas); panel.body.append(viewport);
  let search = null, renaming = null;
  const navigation = svgViewport(canvas, {onPaint: () => { search?.placeArrow(); placeRename(); }});
  search = configSearch(controls, canvas, navigation);
  viewport.addEventListener('keydown', event => {
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'f') {
      event.preventDefault(); event.stopPropagation(); search.focus();
    }
  });
  let lines = [], model = {nodes: []}, markup = null, stopped = false, busy = false, timer, pending, epoch = 0;
  let completion = {items: []}, selected = -1, svg = null, actionError = '';
  function placeRename() {
    if (!renaming) return;
    const box = renaming.label.getBoundingClientRect(), area = canvas.getBoundingClientRect();
    const width = Math.min(canvas.clientWidth, Math.max(160, box.width + 32));
    Object.assign(renaming.input.style, {
      width: `${width}px`, left: `${Math.max(0, Math.min(canvas.clientWidth - width, box.x + box.width / 2 - area.x - width / 2))}px`,
      top: `${Math.max(0, Math.min(canvas.clientHeight - 32, box.y + box.height / 2 - area.y - 16))}px`,
    });
  }
  function closeRename(focus = false) {
    if (!renaming) return;
    const previous = renaming; renaming = null;
    previous.label.style.visibility = ''; previous.input.remove();
    if (focus) canvas.focus({preventScroll: true});
  }
  function rename(node, label) {
    if (busy || stopped) return;
    closeRename(); ++epoch; pending?.abort();
    actionError = ''; status.textContent = '';
    const editor = document.createElement('input'); editor.className = 'config-rename';
    editor.value = node.id.slice(2).split('.').at(-1); editor.spellcheck = false; editor.autocomplete = 'off';
    editor.setAttribute('aria-label', `Rename final segment of ${node.label}`);
    const base = [...lines];
    renaming = {input: editor, label}; canvas.append(editor); placeRename(); label.style.visibility = 'hidden';
    editor.addEventListener('keydown', event => {
      event.stopPropagation();
      if (event.isComposing) return;
      if (event.key === 'Escape') { event.preventDefault(); closeRename(true); }
      if (event.key === 'Enter') {
        event.preventDefault(); const value = editor.value; closeRename(true);
        mutate({action: 'rename-prefix', node: node.id, label: value, base});
      }
    });
    editor.addEventListener('blur', () => closeRename());
    editor.focus({preventScroll: true}); editor.select();
  }
  function closeList() {
    list.hidden = true; selected = -1; input.setAttribute('aria-expanded', 'false'); input.removeAttribute('aria-activedescendant');
  }
  function complete() {
    const prefixes = model.nodes.filter(node => node.kind === 'prefix').map(node => node.label);
    document.querySelectorAll('#graph svg g.node > title').forEach(title => prefixes.push(title.textContent));
    completion = configCompletions(input.value, input.selectionStart ?? input.value.length,
      {docs: window.CONFIG_DOCS, colours: window.CONFIG_COLOURS, prefixes});
    completion.items = completion.items.slice(0, 12); selected = -1;
    list.replaceChildren();
    completion.items.forEach((value, index) => {
      const item = document.createElement('li'); item.textContent = value; item.id = `${list.id}-${index}`;
      item.setAttribute('role', 'option'); item.setAttribute('aria-selected', 'false');
      item.addEventListener('pointerdown', event => { event.preventDefault(); take(index); }); list.append(item);
    });
    list.hidden = !completion.items.length; input.setAttribute('aria-expanded', String(!list.hidden));
  }
  function take(index) {
    const value = completion.items[index]; if (value === undefined) return;
    const text = /\s/.test(value) ? JSON.stringify(value) : value;
    input.setRangeText(text, completion.start, completion.end, 'end'); closeList(); input.focus({preventScroll: true});
  }
  input.addEventListener('input', () => { actionError = ''; status.textContent = ''; complete(); });
  input.addEventListener('focus', closeList);
  input.addEventListener('blur', closeList);
  input.addEventListener('click', complete);
  input.addEventListener('keyup', event => {
    if (['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) complete();
  });
  input.addEventListener('keydown', event => {
    const next = event.key === 'ArrowDown' || (event.ctrlKey && event.key.toLowerCase() === 'n');
    const previous = event.key === 'ArrowUp' || (event.ctrlKey && event.key.toLowerCase() === 'p');
    if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); closeList(); return; }
    if (event.key === 'Tab' && !list.hidden) { event.preventDefault(); take(Math.max(0, selected)); return; }
    if ((next || previous) && !list.hidden) {
      event.preventDefault(); event.stopPropagation();
      selected = selected < 0 ? (next ? 0 : completion.items.length - 1)
        : (selected + (next ? 1 : -1) + completion.items.length) % completion.items.length;
      [...list.children].forEach((item, index) => item.setAttribute('aria-selected', String(index === selected)));
      input.setAttribute('aria-activedescendant', list.children[selected].id);
      list.children[selected].scrollIntoView({block: 'nearest'});
    }
    if (event.key === 'Enter' && selected >= 0 && !list.hidden) { event.preventDefault(); take(selected); }
  });
  function draw(result) {
    const unchanged = markup === result.diagram && JSON.stringify(model) === JSON.stringify(result.graph || {nodes: []});
    lines = result.lines; model = result.graph || {nodes: []};
    const faults = Object.values(result.problems || {});
    status.textContent = actionError || result.error || faults.join('\n');
    if (unchanged) return;
    closeRename();
    const anchor = search.capture();
    markup = result.diagram;
    const parsed = new DOMParser().parseFromString(markup, 'image/svg+xml');
    svg = document.importNode(parsed.documentElement, true);
    if (svg.localName !== 'svg') throw new Error('Unable to render the configuration graph');
    svg.setAttribute('aria-label', 'Configuration dependencies');
    const byId = new Map(model.nodes.map(node => [node.id, node]));
    for (const group of svg.querySelectorAll('g.node')) {
      const node = byId.get(group.querySelector('title')?.textContent); if (!node) continue;
      group.dataset.node = node.id; group.classList.toggle('commented', node.commented);
      group.classList.toggle('invalid', !!node.invalid && !node.commented);
      const labels = [...group.querySelectorAll('text')];
      const oval = group.querySelector('ellipse');
      const cx = oval.cx.baseVal.value, cy = oval.cy.baseVal.value;
      for (const label of labels.slice(0, -2)) {
        label.setAttribute('x', cx); label.setAttribute('y', cy);
        label.setAttribute('text-anchor', 'middle'); label.setAttribute('dominant-baseline', 'central');
        if (node.kind === 'prefix') {
          label.classList.add('config-node-label'); label.setAttribute('role', 'button'); label.setAttribute('tabindex', '0');
          label.setAttribute('aria-label', `Rename prefix ${node.label}`);
          label.addEventListener('click', event => { event.stopPropagation(); rename(node, label); });
          label.addEventListener('keydown', event => {
            if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); event.stopPropagation(); rename(node, label); }
          });
        }
      }
      [['subtree-comment', node.commented ? 'Uncomment' : 'Comment out'], ['subtree-delete', 'Delete']].forEach(([action, verb], index) => {
        const label = labels[labels.length - 2 + index];
        label.setAttribute('x', cx + (index === 0 ? -16 : 16)); label.setAttribute('y', cy + 23);
        label.setAttribute('text-anchor', 'middle');
        const button = document.createElementNS('http://www.w3.org/2000/svg', 'g');
        const hit = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
        hit.setAttribute('x', Number(label.getAttribute('x')) - 12); hit.setAttribute('y', Number(label.getAttribute('y')) - 17);
        hit.setAttribute('width', '24'); hit.setAttribute('height', '24'); hit.setAttribute('fill', 'transparent');
        label.replaceWith(button); button.append(hit, label);
        button.classList.add('config-node-action'); button.setAttribute('role', 'button'); button.setAttribute('tabindex', '0');
        button.dataset.action = action; button.setAttribute('aria-label', `${verb} ${node.text || node.label} and its subtree`);
        button.addEventListener('click', event => { event.stopPropagation(); mutate({action, node: node.id, base: lines}); });
        button.addEventListener('keydown', event => {
          if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); event.stopPropagation(); mutate({action, node: node.id, base: lines}); }
        });
      });
    }
    canvas.replaceChildren(svg);
    if (!model.nodes.length) {
      const empty = document.createElement('p'); empty.className = 'config-empty'; empty.textContent = 'Add a command to begin.'; canvas.append(empty);
    }
    navigation.setSvg(svg);
    search.update(model, svg, anchor);
  }
  async function request(body, signal) {
    const response = await fetch(`/config?k=${encodeURIComponent(window.TOKEN)}`, {
      method: 'POST', body: JSON.stringify({...body, file, diagram: true}), signal,
    });
    const result = await response.json();
    if (!response.ok || !Array.isArray(result.lines)) throw new Error(result.error || 'Unable to update configuration');
    return result;
  }
  async function load(force = false) {
    if (stopped || busy || (!force && (renaming || panel.shut || document.hidden))) return;
    const requested = epoch; pending?.abort(); pending = new AbortController();
    const result = await request({action: 'reload'}, pending.signal);
    if (!stopped && !busy && requested === epoch) draw(result);
  }
  async function mutate(body) {
    if (stopped || busy) return;
    busy = true; ++epoch; pending?.abort(); viewport.classList.add('saving'); closeList();
    try {
      const result = await request(body);
      if (stopped) return;
      actionError = ''; draw(result);
      if (body.action === 'append' && input.value.trim() === body.command) input.value = '';
    } catch (error) {
      if (!stopped) {
        busy = false;
        try { await load(true); } catch {}
        actionError = error.message; status.textContent = actionError;
      }
    } finally { busy = false; viewport.classList.remove('saving'); }
  }
  toolbar.addEventListener('submit', event => {
    event.preventDefault();
    const command = input.value.trim(); if (command) mutate({action: 'append', command});
  });
  let refreshing = false;
  async function refresh() {
    if (stopped || refreshing) return;
    clearTimeout(timer); refreshing = true;
    try { await load(); } catch (error) { if (!stopped && error.name !== 'AbortError') status.textContent = error.message; }
    refreshing = false;
    if (!stopped) timer = setTimeout(refresh, 1000);
  }
  refresh();
  return {focus() { input.focus({preventScroll: true}); closeList(); if (!svg) refresh(); }, stop() {
    stopped = true; ++epoch; clearTimeout(timer); pending?.abort(); closeRename(); navigation.stop(); search.stop(); viewport.remove();
  }};
}
