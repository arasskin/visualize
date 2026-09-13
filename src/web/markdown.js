import { prepareTables } from './markdown-tables.js';
import { addDocumentZoom } from './document-controls.js';

export function markdownReader(panel, id, file) {
  const viewport = document.createElement('div');
  viewport.className = 'markdown-viewport';
  viewport.tabIndex = 0;
  viewport.setAttribute('aria-label', file);
  const article = document.createElement('article');
  article.className = 'markdown-document';
  const status = document.createElement('div');
  status.className = 'markdown-status';
  status.setAttribute('role', 'status');
  viewport.append(status, article);
  panel.body.append(viewport);
  addDocumentZoom(viewport, article);
  const parser = window.markdownit({html: false});
  let revision = null;
  let stopped = false;
  let timer;
  let pending;
  async function refresh() {
    if (stopped || !panel.root.isConnected) return;
    try {
      if (!panel.shut && !document.hidden) {
        pending = new AbortController();
        const response = await fetch('/document?k=' + encodeURIComponent(window.TOKEN), {
          method: 'POST', body: JSON.stringify({id, revision}), signal: pending.signal,
        });
        if (!response.ok) throw new Error('Unable to read document file');
        const result = await response.json();
        if (stopped) return;
        if (typeof result.text === 'string') {
          const top = viewport.scrollTop;
          article.innerHTML = parser.render(result.text);
          prepareTables(article, file);
          for (const link of article.querySelectorAll('a[href]')) {
            if (link.getAttribute('href').startsWith('#')) continue;
            link.target = '_blank';
            link.rel = 'noopener noreferrer';
          }
          viewport.scrollTop = top;
          revision = result.revision;
        }
        status.textContent = '';
      }
    } catch (error) {
      if (!stopped) status.textContent = error.message;
    } finally {
      if (!stopped) timer = setTimeout(refresh, 1000);
    }
  }
  refresh();
  return {
    focus: () => viewport.focus({preventScroll: true}),
    stop() { stopped = true; clearTimeout(timer); pending?.abort(); viewport.remove(); },
  };
}
