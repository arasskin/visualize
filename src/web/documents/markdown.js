import {documentFeed} from './feed.js';
import { prepareTables } from './markdown-tables.js';
import { addDocumentZoom } from './controls.js';

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
  const feed = documentFeed(panel, id, result => {
    const top = viewport.scrollTop;
    article.innerHTML = parser.render(result.text);
    prepareTables(article, file);
    for (const link of article.querySelectorAll('a[href]')) {
      if (link.getAttribute('href').startsWith('#')) continue;
      link.target = '_blank';
      link.rel = 'noopener noreferrer';
    }
    viewport.scrollTop = top;

  }, status);
  return {
    focus() { viewport.focus({preventScroll: true}); feed.refresh(); },
    stop() { feed.stop(); viewport.remove(); },
  };
}
