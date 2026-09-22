export function createPaneLayout({getPanels, getSelected, onChange}) {
  const TAB_GAP = 6;
  const LEFT_MARGIN = 7;
  const RAIL_GRAB = 56;

  const rail = [];
  const railStates = Object.fromEntries(['top', 'bottom'].map(side => [side, {
    scroll: 0, most: 0,
  }]));
  let linkedRails = false;
  let draggingPanel = null;
  let reveal = null;

  function onRail(panel) { return rail.includes(panel); }
  function railSide(panel) { return panel.root.dataset.rail || 'top'; }
  function railPanels(side) { return rail.filter(p => railSide(p) === side); }

  let frame = null;
  function packRail() { if (frame === null) frame = requestAnimationFrame(() => { frame = null; packRailNow(); }); }

  function arrangeRails() {
    const rows = ['top', 'bottom'].map(side => ({side, at: 0, x: LEFT_MARGIN,
      entries: railPanels(side).map(panel => {
        const box = panel.root.getBoundingClientRect();
        return {panel, position: box.left, width: box.width, height: box.height,
          spans: panel !== draggingPanel && !panel.shut && box.height >= innerHeight - .5};
      }),
    }));
    const placeNext = row => {
      const entry = row.entries[row.at++];
      entry.left = row.x;
      row.x += entry.width + TAB_GAP;
    };
    while (true) {
      const candidates = rows.flatMap(row => {
        let left = row.x;
        for (let index = row.at; index < row.entries.length; index++) {
          const entry = row.entries[index];
          if (entry.spans) return [{row, left, position: entry.position}];
          left += entry.width + TAB_GAP;
        }
        return [];
      }).sort((a, b) => a.position - b.position || a.left - b.left);
      if (!candidates.length) break;
      const next = candidates[0];
      for (const row of rows) {
        while (row.at < row.entries.length) {
          const entry = row.entries[row.at];
          if (entry.spans || (row !== next.row && row.x + entry.width + TAB_GAP > next.left)) break;
          placeNext(row);
        }
      }
      placeNext(next.row);
      for (const row of rows) row.x = Math.max(row.x, next.row.x);
    }
    for (const row of rows) while (row.at < row.entries.length) placeNext(row);
    return rows;
  }

  function packRailNow() {
    if (frame !== null) { cancelAnimationFrame(frame); frame = null; }
    unscrollPage();
    const rows = arrangeRails();
    const spanning = rows.flatMap(row => row.entries).find(entry => entry.spans);
    linkedRails = !!spanning;
    const sharedScroll = spanning && railStates[railSide(spanning.panel)].scroll;
    for (const row of rows) {
      const state = railStates[row.side];
      const total = linkedRails ? Math.max(...rows.map(row => row.x)) : row.x;
      state.most = Math.min(0, innerWidth - total);
      state.scroll = Math.max(state.most, Math.min(0, linkedRails ? sharedScroll : state.scroll));
    }
    for (const row of rows) {
      const state = railStates[row.side];
      const entry = row.entries.find(entry => entry.panel === reveal);
      if (entry && state.most < 0) {
        const left = entry.left + state.scroll;
        const visible = Math.min(entry.width, innerWidth - LEFT_MARGIN - TAB_GAP);
        if (left > innerWidth - TAB_GAP - visible) state.scroll -= left - (innerWidth - TAB_GAP - visible);
        else if (left + entry.width < LEFT_MARGIN + visible) state.scroll += LEFT_MARGIN + visible - left - entry.width;
        state.scroll = Math.max(state.most, Math.min(0, state.scroll));
        if (linkedRails) for (const other of Object.values(railStates)) other.scroll = state.scroll;
      }
    }
    for (const {side, entries} of rows) {
      for (const {panel, left, height} of entries) {
        panel.root.style.setProperty('--rail-tab-height', panel.bar.offsetHeight + 'px');
        if (panel !== draggingPanel) {
          panel.root.classList.toggle('bottom-docked', side === 'bottom');
          panel.place(left + railStates[side].scroll, side === 'bottom' ? innerHeight - height : 0, true);
        }
      }
    }
    reveal = null;
  }

  function unscrollPage() {
    if (window.scrollX !== 0 || window.scrollY !== 0) window.scrollTo(0, 0);
  }

  function revealTab(panel) {
    reveal = onRail(panel) ? panel : null;
    if (!reveal) return;
    unscrollPage();
    packRail();
  }

  window.addEventListener('wheel', e => {
    const side = e.clientY <= railHeight('top') ? 'top'
      : e.clientY >= innerHeight - railHeight('bottom') ? 'bottom' : null;
    if (!side) return;
    const state = railStates[side];
    const by = Math.abs(e.deltaX) > Math.abs(e.deltaY) ? -e.deltaX : -e.deltaY;
    const next = Math.max(state.most, Math.min(0, state.scroll + by));
    if (next === state.scroll) return;
    state.scroll = next;
    if (linkedRails) for (const other of Object.values(railStates)) other.scroll = next;
    packRail();
    e.preventDefault();
  }, { passive: false });

  window.addEventListener('resize', () => { resnap(); packRail(); });

  function addToRail(panel, at, side = 'bottom') {
    const old = rail.indexOf(panel);
    if (old >= 0) rail.splice(old, 1);
    const others = railPanels(side);
    const before = others[at === undefined ? others.length : at];
    rail.splice(before ? rail.indexOf(before) : rail.length, 0, panel);
    panel.root.dataset.rail = side;
    delete panel.root.dataset.snapped;
    if (panel === getSelected()) reveal = panel;
    packRail();
    onChange();
  }

  function removeFromRail(panel) {
    const at = rail.indexOf(panel);
    if (at < 0) return;
    const bar = panel.bar.getBoundingClientRect();
    rail.splice(at, 1);
    delete panel.root.dataset.rail;
    if (panel.root.classList.contains('bottom-docked')) {
      panel.root.classList.remove('bottom-docked');
      panel.place(bar.left, bar.top);
    }
    packRail();
  }

  const EDGE_GRAB = 48;

  const EDGES = {
    ceiling: {
      near: (box) => box.top <= EDGE_GRAB,
      fill: (box) => ({ top: 0, height: Math.min(box.bottom, innerHeight) }),
    },
    floor: {
      near: (box) => box.bottom >= innerHeight - EDGE_GRAB,

      fill: (box) => ({ height: innerHeight - box.top }),
    },
  };

  const edgeMarks = {};
  for (const name of Object.keys(EDGES)) {
    const mark = document.createElement('div');
    mark.id = name + '-mark';
    mark.className = 'edge-mark';
    mark.innerHTML = '<i></i>';
    document.body.appendChild(mark);
    edgeMarks[name] = mark;
  }

  function resnap() {
    let moved = false;
    for (const root of getPanels().map(panel => panel.root).filter(root => root.dataset.snapped)) {
      const names = root.dataset.snapped.split(' ').filter(Boolean);
      if (!names.length) continue;

      if (root.classList.contains('shut')) continue;

      const panel = getPanels().find(panel => panel.root === root);

      const box = root.getBoundingClientRect();
      const want = Object.assign({}, ...names.map((name) => EDGES[name] && EDGES[name].fill(box)));
      if (want.height === undefined) continue;

      const h = Math.max(panel?.minHeight || 120, want.height);

      const top = want.top ?? Math.min(box.top, Math.max(0, innerHeight - h));
      const wantsHeight = Math.abs(box.height - h) > 0.5;
      const wantsTop = Math.abs(box.top - top) > 0.5;
      if (!wantsHeight && !wantsTop) continue;

      if (wantsHeight) root.style.height = h + 'px';
      if (wantsTop) root.style.top = top + 'px';
      moved = true;

      if (panel && panel.resized) panel.resized();
    }
    return moved;
  }

  function nearEdges(root) {
    const box = root.getBoundingClientRect();
    const edge = root.classList.contains('bottom-docked') ? 'ceiling' : 'floor';
    return EDGES[edge].near(box) ? [edge] : [];
  }

  function showEdges(names) {
    for (const name of Object.keys(EDGES)) {
      edgeMarks[name].classList.toggle('near', names.includes(name));
    }
  }

  const railMarks = Object.fromEntries(['top', 'bottom'].map(side => {
    const mark = document.createElement('div');
    mark.className = 'rail-marks ' + side;
    mark.innerHTML = '<i></i><i></i>';
    document.body.appendChild(mark);
    return [side, mark];
  }));

  function railHeight(side) {
    const panels = railPanels(side);
    const panel = draggingPanel || panels[0] || getPanels()[0];
    if (!panel) return 28;
    const style = getComputedStyle(panel.root);
    return panel.bar.getBoundingClientRect().height
      + parseFloat(style.borderTopWidth) + parseFloat(style.borderBottomWidth);
  }

  function showRails(near) {
    for (const [side, mark] of Object.entries(railMarks)) {
      mark.style.height = railHeight(side) + 'px';
      mark.classList.toggle('near', side === near);
    }
  }

  function overRail(panel) {
    const bar = panel.bar.getBoundingClientRect();
    const top = Math.abs(bar.top);
    const bottom = Math.abs(bar.bottom - innerHeight);
    if (Math.min(top, bottom) > RAIL_GRAB) return null;
    return top <= bottom ? 'top' : 'bottom';
  }

  function slotFor(panel, side) {
    const bar = panel.bar.getBoundingClientRect();
    const mid = bar.left + bar.width / 2;
    const others = railPanels(side).filter(p => p !== panel);
    const at = others.findIndex(p => {
      const b = p.bar.getBoundingClientRect();
      return mid < b.left + b.width / 2;
    });
    return at < 0 ? others.length : at;
  }

  function railDrag(panel) {
    draggingPanel = panel;
    const near = overRail(panel);
    showRails(near);
    if (near) addToRail(panel, slotFor(panel, near), near);
  }

  function railDrop(panel) {
    const near = overRail(panel);
    draggingPanel = null;
    showRails(null);
    if (near) addToRail(panel, slotFor(panel, near), near);
    else removeFromRail(panel);
    packRail();
    onChange();
  }

  function resizeMove(panel) { showEdges(nearEdges(panel.root)); }
  function resizeEnd(panel) {
    const root = panel.root;
    const landing = nearEdges(root);
    if (landing.length) {
      const box = root.getBoundingClientRect();
      const want = Object.assign({}, ...landing.map(name => EDGES[name].fill(box)));
      if (want.height !== undefined) {
        const height = Math.max(panel.minHeight, want.height);
        root.style.height = height + 'px';
        root.style.top = (want.top ?? Math.min(box.top, Math.max(0, innerHeight - height))) + 'px';
      }
      if (!onRail(panel)) root.dataset.snapped = landing.join(' ');
      panel.resized();
    } else delete root.dataset.snapped;
    packRail();
    showEdges([]);
  }
  return {rail, onRail, railSide, railPanels, packRail, packRailNow, revealTab, addToRail, removeFromRail,
    resnap, railDrag, railDrop, resizeMove, resizeEnd, get dragging() { return !!draggingPanel; }};

}
