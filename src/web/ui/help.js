export function createHelp({docs, composing, shutCompose}) {
  const help = document.getElementById('help');

  function renderHelp() {
    const verbs = docs;
    const into = document.getElementById('help-verbs');
    for (const verb of verbs) {
      const row = document.createElement('div');
      row.className = 'help-verb';

      const usage = document.createElement('code');
      usage.className = 'help-usage';
      usage.textContent = verb.usage;
      row.appendChild(usage);

      const blurb = document.createElement('p');
      blurb.textContent = verb.blurb;
      row.appendChild(blurb);

      into.appendChild(row);
    }
  }

  let helpCloseTarget = null;

  function openHelp() {

    if (composing()) shutCompose();
    help.classList.remove('shut');
    helpCloseTarget = document.activeElement;
    help.focus();
  }

  function shutHelp() {
    help.classList.add('shut');
    if (helpCloseTarget && helpCloseTarget.focus) helpCloseTarget.focus();
    helpCloseTarget = null;
  }

  help.addEventListener('click', (e) => { if (e.target === help) shutHelp(); });
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && !help.classList.contains('shut')) {
      shutHelp();
      return;
    }

    if (composing()) return;

    if (e.key === '?' &&
        (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA' ||
         e.target.isContentEditable)) return;
    if (e.key === '?' || e.key === 'F1') {
      e.preventDefault();

      if (help.classList.contains('shut')) openHelp(); else shutHelp();
    }
  });

  renderHelp();

  return {root: help, close: shutHelp};
}
