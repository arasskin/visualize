import { wire } from './graph.js';
import { openFileTerminal } from './panes.js';

let prompt = null;
function dismiss() {
  prompt?.remove();
  prompt = null;
}

wire({ onFileClick(file, position) {
  dismiss();
  const form = document.createElement('form');
  form.id = 'file-command';
  const label = document.createElement('label');
  label.textContent = file.file;
  const input = document.createElement('input');
  input.type = 'text';
  input.placeholder = 'Terminal command…';
  input.setAttribute('aria-label', 'Command to run with this file');
  input.autocomplete = 'off';
  input.spellcheck = false;
  input.maxLength = 4096;
  label.append(input);
  form.append(label);
  document.body.append(form);
  form.style.left = Math.max(6, Math.min(position.x, innerWidth - form.offsetWidth - 6)) + 'px';
  form.style.top = Math.max(6, Math.min(position.y, innerHeight - form.offsetHeight - 6)) + 'px';
  form.addEventListener('submit', event => {
    event.preventDefault();
    const command = input.value.trim();
    if (!command) return;
    dismiss();
    openFileTerminal(file, command, position);
  });
  form.addEventListener('keydown', event => {
    event.stopPropagation();
    if (event.key === 'Escape') { event.preventDefault(); dismiss(); }
  });
  prompt = form;
  input.focus();
} });

document.addEventListener('pointerdown', event => {
  if (prompt && !prompt.contains(event.target)) dismiss();
});
