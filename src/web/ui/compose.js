import {completionList} from '../shared/completion-list.js';
import {configCompletions} from '../config/completion.js';
export function createCompose({getPrefixes, docs, colours, lines = [], pickedPanel, selectPane, beforeOpen}) {
  let busy = false;
  const compose = document.getElementById('compose');
  const composeInput = document.getElementById('compose-input');
  const composeFault = document.getElementById('compose-fault');

  function composing() { return !compose.classList.contains('shut'); }

  const composeList = document.getElementById('compose-list');

  function completionResult() {
    const prefixes = getPrefixes();
    return configCompletions(composeInput.value, composeInput.selectionStart ?? composeInput.value.length,
      {docs, colours, prefixes, lines});
  }

  function sizeCompose() { composeInput.style.width = Math.max(1, composeInput.value.length) + 'ch'; }
  const suggestions = completionList(composeInput, composeList, {preview: true,
    visibility: visible => compose.classList.toggle('listing', visible),
    take(text) {
      const {start, end} = completionResult();
      composeInput.setRangeText(text, start, end, 'end'); sizeCompose();
    },
  });
  function renderList() { suggestions.set(composing() ? completionResult().items : []); }
  const shutList = suggestions.close;

  let cameFrom = null;

  function openCompose(seed) {
    const already = composing();
    compose.classList.remove('shut');

    if (!already) {
      const was = pickedPanel();
      cameFrom = was;
    }
    composeFault.textContent = '';
    composeInput.value = seed || '';
    sizeCompose();
    composeInput.focus();
    renderList();

    const end = composeInput.value.length;
    composeInput.setSelectionRange(end, end);
  }

  function shutCompose() {
    compose.classList.add('shut');
    composeInput.value = '';
    composeFault.textContent = '';
    shutList();
    composeInput.blur();

    const back = cameFrom;
    cameFrom = null;
    if (back && back.root && back.root.isConnected) selectPane(back.root);
  }

  async function commitCompose() {
    const command = composeInput.value.trim();
    if (!command) { shutCompose(); return; }
    if (busy) return;
    busy = true;
    try {
      const response = await fetch('/config?k=' + encodeURIComponent(window.TOKEN), {
        method: 'POST', body: JSON.stringify({action: 'append', command}),
      });
      const result = await response.json();
      if (!response.ok || !result.lines) throw new Error(result.error || 'Unable to add command');
      lines = result.lines;
      shutCompose();
    } catch (error) { composeFault.textContent = error.message; }
    finally { busy = false; }
  }

  compose.addEventListener('mousemove', () => compose.classList.add('mousing'));
  composeInput.addEventListener('keydown', () => compose.classList.remove('mousing'));

  composeInput.addEventListener('input', () => {
    sizeCompose();

    renderList();
  });

  for (const ev of ['click', 'keyup']) {
    composeInput.addEventListener(ev, (e) => {

      if (e.type === 'keyup' && !['ArrowLeft','ArrowRight','Home','End'].includes(e.key)) return;
      renderList();
    });
  }

  composeInput.addEventListener('keydown', (e) => {
    if (suggestions.key(e, false)) return;
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); commitCompose(); }

    else if (e.key === 'Enter' && e.shiftKey) {
      e.preventDefault();
    }
    else if (e.key === 'Escape') {
      e.preventDefault();

      shutCompose();
    }

    else if (e.key === 'Backspace' && composeInput.value === '') shutCompose();
  });

  document.addEventListener('keydown', (e) => {
    if (composing()) return;
    if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA' || e.target.isContentEditable) return;
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    if (!compose.isConnected) return;

    if (e.key.length !== 1) return;
    if (e.key === ' ') return;

    if (e.defaultPrevented) return;
    e.preventDefault();

    beforeOpen();
    openCompose(e.key);
  });

  return {input: composeInput, isOpen: composing, close: shutCompose, updateLines(next) {
    if (JSON.stringify(lines) === JSON.stringify(next)) return;
    lines = next;
    if (composing() && composeInput.value.trimStart().startsWith('un')) renderList();
  }};
}
