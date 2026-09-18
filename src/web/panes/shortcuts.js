export function paneShortcuts({rail, pickedPanel, selectPane, revealTab, openTerminal}, composeInput) {
  let altUsed = false;

  let altOpened = false;
  let altDown = false;

  let altAt = 0;

  let altCaret = null;

  let altWalked = null;

  let altPanel = null;

  let altPeeked = null;

  const ALT_HOLD_MS = 400;

  function altChord(e) {
    const walkLeft = e.code === 'KeyH' || e.code === 'ArrowLeft';
    const walkRight = e.code === 'KeyL' || e.code === 'ArrowRight';
    const newTab = e.code === 'Enter' || e.code === 'NumpadEnter';
    if (!walkLeft && !walkRight && !newTab) return false;
    e.preventDefault();
    if (newTab) openTerminal();
    else altWalk(walkRight ? 1 : -1);
    return true;
  }

  document.addEventListener('keydown', (e) => {
    if (e.key !== 'Alt') {

      if (altDown) {
        altUsed = true;

        if (altChord(e)) e.stopPropagation();
      }
      return;
    }

    if (altDown) return;
    altDown = true;
    altUsed = false;
    altWalked = null;
    altAt = performance.now();

    const el = document.activeElement;
    altCaret = (el === composeInput && typeof el.selectionStart === 'number')
      ? { el, start: el.selectionStart, end: el.selectionEnd }
      : null;

    altPanel = pickedPanel();
    altOpened = !!altPanel?.shut;

    if (altOpened) altPanel.open();
  }, true);

  function altWalk(by) {

    const ordered = ['bottom', 'top'].flatMap(side => rail.filter(p => (p.root.dataset.rail || 'top') === side));
    const here = ordered.indexOf(pickedPanel());
    if (ordered.length < (here < 0 ? 1 : 2)) return;

    const to = here < 0
      ? (by > 0 ? 0 : ordered.length - 1)
      : Math.max(0, Math.min(ordered.length - 1, here + by));
    if (to === here) return;
    const next = ordered[to];

    const leaving = altPeeked || (altOpened ? altPanel : null);
    if (leaving && leaving !== next) {
      leaving.toggle();
      altPeeked = null;
      altOpened = false;
    }
    selectPane(next.root);

    altWalked = next;

    altPanel = next;
    if (next.shut) {
      next.open();
      altPeeked = next;

      altOpened = false;
    } else {
      altOpened = false;
    }

    revealTab(next);
  }

  document.addEventListener('keyup', (e) => {
    if (e.key !== 'Alt') return;
    altDown = false;
    const held = altUsed || performance.now() - altAt >= ALT_HOLD_MS;

    const caret = altCaret;
    altCaret = null;

    const walked = altWalked;
    altWalked = null;
    const restore = () => {

      if (walked && !walked.shut) { walked.focus(); return; }
      if (!caret || !caret.el.isConnected) return;
      caret.el.focus();
      if (typeof caret.el.setSelectionRange === 'function') {
        caret.el.setSelectionRange(caret.start, caret.end);
      }
    };

    const target = altPanel;
    altPanel = null;

    const peeked = altPeeked;
    altPeeked = null;
    if (peeked) {
      peeked.toggle();
      restore();
      return;
    }
    if (held) {

      if (altOpened) target?.toggle();
      restore();
      return;
    }

    if (!altOpened) target?.toggle();
    restore();
  });

  window.addEventListener('blur', () => {
    if (altDown && altOpened && altPanel) altPanel.toggle();
    altPanel = null;
    altDown = false;
  });

}
