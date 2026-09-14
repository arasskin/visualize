import {refreshLoop} from '../shared/refresh.js';

export function documentFeed(panel, id, update, status) {
  let revision = null;
  return refreshLoop({
    enabled: () => panel.root.isConnected && !panel.shut && !document.hidden,
    async load(signal) {
      const response = await fetch(`/document?k=${encodeURIComponent(window.TOKEN)}`, {
        method: 'POST', body: JSON.stringify({id, revision}), signal,
      });
      if (!response.ok) throw new Error('Unable to read document file');
      return response.json();
    },
    apply(result) {
      if (typeof result.text === 'string') { update(result); revision = result.revision; }
      status.textContent = '';
    },
    error: error => { status.textContent = error.message; },
  });
}
