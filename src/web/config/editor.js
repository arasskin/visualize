import {completionList} from '../shared/completion-list.js';
import {refreshLoop} from '../shared/refresh.js';
import { configCompletions } from './completion.js';
import { svgViewport } from '../graph/viewport.js';
import { configSearch } from './search.js';

export function configReader(panel, id, file, {docs = [], colours = [], getPrefixes = () => []} = {}) {
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
  let lines = [], model = {nodes: []}, markup = null, stopped = false, busy = false;
  let completion = {items: []}, svg = null, actionError = '';
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
    closeRename(); refresh.invalidate();
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
  const suggestions = completionList(input, list, {take(value) {
    input.setRangeText(!completion.wholeLine && /\s/.test(value) ? JSON.stringify(value) : value, completion.start, completion.end, 'end');
    suggestions.close(); input.focus({preventScroll: true});
  }});
  const closeList = suggestions.close;
  function complete() {
    const prefixes = model.nodes.filter(node => node.kind === 'prefix').map(node => node.label);
    prefixes.push(...getPrefixes());
    completion = configCompletions(input.value, input.selectionStart ?? input.value.length, {docs, colours, prefixes, lines});
    suggestions.set(completion.items.slice(0, 12));
  }
  input.addEventListener('input', () => { actionError = ''; status.textContent = ''; complete(); });
  input.addEventListener('focus', closeList);
  input.addEventListener('blur', closeList);
  input.addEventListener('click', complete);
  input.addEventListener('keyup', event => {
    if (['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) complete();
  });
  input.addEventListener('keydown', event => {
    if (suggestions.key(event)) return;
    if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); closeList(); }
  });
  function draw(result) {
    const unchanged = markup === result.diagram && JSON.stringify(model) === JSON.stringify(result.graph || {nodes: []});
    const changedLines = JSON.stringify(lines) !== JSON.stringify(result.lines);
    lines = result.lines; model = result.graph || {nodes: []};
    if (changedLines && suggestions.visible && input.value.trimStart().startsWith('un')) complete();
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
  async function mutate(body) {
    if (stopped || busy) return;
    busy = true; refresh.invalidate(); viewport.classList.add('saving'); closeList();
    try {
      const result = await request(body);
      if (stopped) return;
      actionError = ''; draw(result);
      if (body.action === 'append' && input.value.trim() === body.command) input.value = '';
    } catch (error) {
      if (!stopped) {
        busy = false;
        try { await refresh.refresh(true); } catch {}
        actionError = error.message; status.textContent = actionError;
      }
    } finally { busy = false; viewport.classList.remove('saving'); }
  }
  toolbar.addEventListener('submit', event => {
    event.preventDefault();
    const command = input.value.trim(); if (command) mutate({action: 'append', command});
  });
  const refresh = refreshLoop({
    enabled: () => !busy && !renaming && !panel.shut && !document.hidden,
    load: signal => request({action: 'reload'}, signal),
    apply: draw,
    error: error => { status.textContent = error.message; },
  });
  return {focus() { input.focus({preventScroll: true}); closeList(); if (!svg) refresh.refresh(); }, stop() {
    stopped = true; refresh.stop(); closeRename(); navigation.stop(); search.stop(); viewport.remove();
  }};
}
