export function createPaneLayout({getPanels, getSelected, onChange}) {
  const TAB_GAP = 6;
  const LEFT_MARGIN = 7;
  const RAIL_GRAB = 56;

  const rail = [];
  const railStates = Object.fromEntries(['top', 'bottom'].map(side => [side, {
    scroll: 0,
  }]));
  let draggingPanel = null;
  let reveal = null;

  function onRail(panel) { return rail.includes(panel); }
  function railSide(panel) { return panel.root.dataset.rail || 'top'; }
  function railPanels(side) { return rail.filter(p => railSide(p) === side); }

  let frame = null;
  function packRail() { if (frame === null) frame = requestAnimationFrame(() => { frame = null; packRailNow(); }); }

  function packRailNow() {
    if (frame !== null) { cancelAnimationFrame(frame); frame = null; }
    unscrollPage();
    for (const side of ['top', 'bottom']) {
      const state = railStates[side], panels = railPanels(side);
      const widths = panels.map(p => p.root.getBoundingClientRect().width);
      const total = widths.reduce((sum, width) => sum + width + TAB_GAP, LEFT_MARGIN);
      const most = Math.min(0, innerWidth - total);
      state.scroll = Math.max(most, Math.min(0, state.scroll));
      const index = panels.indexOf(reveal);
      if (index >= 0 && most < 0) {
        const left = LEFT_MARGIN + state.scroll + widths.slice(0, index).reduce((sum, width) => sum + width + TAB_GAP, 0);
        const visible = Math.min(widths[index], innerWidth - LEFT_MARGIN - TAB_GAP);
        if (left > innerWidth - TAB_GAP - visible) state.scroll -= left - (innerWidth - TAB_GAP - visible);
        else if (left + widths[index] < LEFT_MARGIN + visible) state.scroll += LEFT_MARGIN + visible - left - widths[index];
        state.scroll = Math.max(most, Math.min(0, state.scroll));
      }
      let x = LEFT_MARGIN + state.scroll;
      panels.forEach((panel, index) => {
        panel.root.style.setProperty('--rail-tab-height', panel.bar.offsetHeight + 'px');
        if (panel !== draggingPanel) {
          panel.root.classList.toggle('bottom-docked', side === 'bottom');
          panel.place(x, side === 'bottom' ? innerHeight - panel.root.getBoundingClientRect().height : 0, true);
        }
        x += widths[index] + TAB_GAP;
      });
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
    const total = railPanels(side).reduce((sum, panel) => sum + panel.root.offsetWidth + TAB_GAP, LEFT_MARGIN);
    const by = Math.abs(e.deltaX) > Math.abs(e.deltaY) ? -e.deltaX : -e.deltaY;
    const next = Math.max(Math.min(0, innerWidth - total), Math.min(0, state.scroll + by));
    if (next === state.scroll) return;
    state.scroll = next;
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
    showEdges([]);
  }
  return {rail, onRail, railSide, railPanels, packRail, packRailNow, revealTab, addToRail, removeFromRail,
    resnap, railDrag, railDrop, resizeMove, resizeEnd, get dragging() { return !!draggingPanel; }};

}
