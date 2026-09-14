import {watch} from '../shared/watch.js';

export function graphUpdates(graph, search, hover, generation, onUpdate = () => {}) {
  return watch('/watch', generation, async (result, signal) => {
    if (!result.changed) return;
    const response = await fetch(`/config?k=${encodeURIComponent(window.TOKEN)}`, {
      method: 'POST', signal, body: JSON.stringify({action: 'run', index: -1, draw: true}),
    });
    const out = await response.json();
    if (signal.aborted) return;
    if (response.ok && Array.isArray(out.lines)) onUpdate(out);
    if (!response.ok || !out.svg) throw new Error(out.error || 'Unable to redraw graph');
    const anchor = search.anchorHit();
    hover.hideEdge(); graph.pane.innerHTML = out.svg;
    hover.keepEdgeLabel(); hover.wireEdges(); graph.hatchFolded();
    search.forgetUnit(); search.redrawFind();
    if (graph.isTouched()) graph.repaint(); else graph.fit();
    search.restoreAnchor(anchor);
    return out.generation;
  });
}
