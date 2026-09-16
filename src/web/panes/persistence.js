import {reportError} from '../shared/errors.js';
import {refreshSession} from '../shared/transport.js';
export function createPanePersistence(getPanels, layout) {
  const {onRail, railSide, railPanels, addToRail, removeFromRail, packRailNow} = layout;
  let placementsReady = false;
  let placementTimer = null;
  let placementSaving = false;
  let placementDirty = false;

  function placementSnapshot() {
    return Object.fromEntries(getPanels()
      .filter(p => p.root.isConnected)
      .map(p => {
        const size = p.size.map(Math.round);
        const position = onRail(p)
          ? [railSide(p), railPanels(railSide(p)).indexOf(p), ...size]
          : ['floating', p.root.offsetLeft, p.root.offsetTop, ...size];
        if (p.root.classList.contains('unfaded')) position.push(true);
        return [p.id, position];
      }));
  }

  function savePlacementSoon() {
    if (!placementsReady || layout.dragging) return;
    placementDirty = true;
    clearTimeout(placementTimer);
    placementTimer = setTimeout(savePlacements, 100);
  }

  async function savePlacements() {
    if (!placementDirty || placementSaving) return;
    placementSaving = true;
    placementDirty = false;
    try {
      const response = await fetch('/panes/placements?k=' + encodeURIComponent(window.TOKEN), {
        method: 'POST', body: JSON.stringify(placementSnapshot()), keepalive: true,
      });
      if (response.status === 403) await refreshSession();
      if (!response.ok) throw new Error('could not save pane placement');
    } catch (error) {
      placementDirty = true;
      reportError(error, { phase: 'pane-placement' });
    } finally {
      placementSaving = false;
      if (placementDirty) placementTimer = setTimeout(savePlacements, 1000);
    }
  }

  function restorePlacements(positions = {}) {
    const saved = positions;
    for (const panel of getPanels()) {
      if (!panel.root.isConnected) continue;
      const position = saved[panel.id];
      if (!position) continue;
      panel.setUnfaded(position.at(-1) === true);
      const sizeAt = position[0] === 'floating' ? 3 : 2;
      if (position.length >= sizeAt + 2 && position[sizeAt] > 0 && position[sizeAt + 1] > 0) {
        panel.root.style.width = position[sizeAt] + 'px';
        panel.root.style.height = position[sizeAt + 1] + 'px';
      }
      if (position[0] === 'floating') {
        removeFromRail(panel);
        panel.open();
        panel.place(position[1], position[2]);
      } else addToRail(panel, undefined, position[0]);
    }
    for (const side of ['top', 'bottom']) {
      const ordered = railPanels(side).sort((a, b) =>
        (saved[a.id]?.[1] ?? Infinity) - (saved[b.id]?.[1] ?? Infinity));
      for (const panel of ordered) addToRail(panel, undefined, side);
    }
    packRailNow();
  }

  window.addEventListener('pagehide', () => {
    clearTimeout(placementTimer);
    savePlacements();
  });

  return {changed: savePlacementSoon, restore: restorePlacements, start() { placementsReady = true; savePlacementSoon(); }};

}
