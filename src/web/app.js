import { configCompletions } from './config-completion.js';
import './file-command.js';
import { refreshSession } from './transport.js';
import { pane, wire as wireGraph, paint, repaint, fit, fitSoon, isTouched, hatchFolded } from './graph.js';
import {
  find, hits, wire as wireFind, placeArrow, redrawFind, anchorHit, restoreAnchor,
  forgetUnit,
} from './find.js';
import { moduleNames, hideEdge, wireEdges, keepEdgeLabel } from './hover.js';
import {
  configPanel, makeConfigPanel, rail, EDGES,
  selectPane, pickedPanel, revealTab, openTerminal, resnap,
  startRail, syncPanes, wire as wirePanes,
} from './panes.js';

wireGraph({ onRepaint: () => placeArrow(), onNavigate: hideEdge });

fitSoon();
wireEdges();
hatchFolded();
window.addEventListener('load', fitSoon);

window.addEventListener('resize', () => {

  resnap();
  if (!isTouched()) fit();
});

let sourceGeneration = Number.isInteger(window.GRAPH_GENERATION) ? window.GRAPH_GENERATION : -1;
let pageLeaving = false;
window.addEventListener('pagehide', () => { pageLeaving = true; });
window.addEventListener('pageshow', () => { pageLeaving = false; });

async function watchSource() {
  for (;;) {
    try {
      const r = await fetch(`/watch?k=${encodeURIComponent(window.TOKEN)}`, {
        method: 'POST',
        body: JSON.stringify({ generation: sourceGeneration }),
        signal: AbortSignal.timeout(35000),
      });
      if (!r.ok) {
        if (r.status === 403) await refreshSession();
        throw new Error('source watch failed');
      }
      const out = await r.json();
      const previous = sourceGeneration;
      const first = sourceGeneration === -1;
      sourceGeneration = out.generation;

      if (out.changed && !first) {
        const drawn = await send('run', -1, true);
        if (drawn && Number.isInteger(drawn.generation)) sourceGeneration = drawn.generation;
        else { sourceGeneration = previous; await new Promise(r => setTimeout(r, 50)); }


      }
    } catch (e) {
      await new Promise((r) => setTimeout(r, 2000));
    }
  }
}

const panel = document.getElementById('config');
const bar = document.getElementById('bar');
const body = document.getElementById('body');
const grip = document.getElementById('grip');
let lines = [];
let busy = false;

async function send(action, index, keepView) {
  if (busy) return;
  busy = true;

  try {

    const r = await fetch(`/config?k=${encodeURIComponent(window.TOKEN)}`, {
      method: 'POST',

      body: JSON.stringify({ action, index, draw: !!keepView }),
    });
    const out = await r.json();

    if (!out.lines) {
      throw new Error(out.error || 'Unable to redraw graph');
    } else {
      lines = out.lines;

      if (out.svg) {

        hideEdge();

        const anchor = anchorHit();
        pane.innerHTML = out.svg;
        keepEdgeLabel();
        wireEdges();

        hatchFolded();

        forgetUnit();
        redrawFind();

        if (keepView && isTouched()) repaint(); else fit();

        restoreAnchor(anchor);
      }


    }
    return out;
  } catch (e) {
    if (!pageLeaving && e.name !== 'AbortError') console.error('Graph redraw failed', e);
  } finally {
    busy = false;
  }
}

const help = document.getElementById('help');

function renderHelp() {
  const verbs = window.CONFIG_DOCS || [];
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

const compose = document.getElementById('compose');
const composeInput = document.getElementById('compose-input');
const composeFault = document.getElementById('compose-fault');

function composing() { return !compose.classList.contains('shut'); }

const composeList = document.getElementById('compose-list');

function completionResult() {
  const prefixes = [...pane.querySelectorAll('svg g.node > title')].map(title => title.textContent);
  return configCompletions(composeInput.value, composeInput.selectionStart ?? composeInput.value.length,
    {docs: window.CONFIG_DOCS, colours: window.CONFIG_COLOURS, prefixes});
}

function wordAtCaret() { return completionResult(); }
function completions() { return completionResult().items; }
function prefixCandidates() {
  const prefixes = [...pane.querySelectorAll('svg g.node > title')].map(title => title.textContent);
  return configCompletions('fold ', 5,
    {docs: window.CONFIG_DOCS, prefixes}).items;
}

function composeTarget() { return null; }

const COMPOSE_MAX_PX = 17;
const COMPOSE_MIN_PX = 12;
const COMPOSE_ROWS = 7;

const COMPOSE_INCHES = 6.3;
const COMPOSE_CAP_PX = Math.round(COMPOSE_INCHES * 96);

function refitCompose() {
  if (!compose.isConnected || compose.classList.contains('shut')) return;
  compose.classList.toggle('typing', !!composeTarget());

  renderList();
  sizeCompose();
}

function sizeCompose() { sizeFor(composeInput.value); }

function nextValue(e) {
  const v = composeInput.value;
  const a = composeInput.selectionStart, b = composeInput.selectionEnd;
  if (a === null || b === null) return null;
  switch (e.inputType) {
    case 'insertText':
    case 'insertFromPaste':
    case 'insertReplacementText':
      return v.slice(0, a) + (e.data ?? '') + v.slice(b);
    case 'insertLineBreak':
    case 'insertParagraph':
      return v.slice(0, a) + '\n' + v.slice(b);
    case 'deleteContentBackward':
      return a === b ? v.slice(0, Math.max(0, a - 1)) + v.slice(b) : v.slice(0, a) + v.slice(b);
    case 'deleteContentForward':
      return a === b ? v.slice(0, a) + v.slice(b + 1) : v.slice(0, a) + v.slice(b);
    case 'deleteByCut':
    case 'deleteWordBackward':
    case 'deleteWordForward':
      return null;
    default:
      return null;
  }
}

function sizeFor(value) {
  const term = composeTarget();
  if (!term) {

    composeInput.style.font = '';
    composeInput.style.width = Math.max(1, value.length) + 'ch';
    composeInput.style.height = '';
    composeInput.rows = 1;
    return;
  }

  const lines = value.split('\n');
  const longest = Math.max(1, ...lines.map(l => l.length));

  const em = charWidth();
  const capPx = Math.min(COMPOSE_CAP_PX, Math.round(innerWidth * 0.94));

  const wanted = longest * COMPOSE_MAX_PX * em;
  const px = lines.length > 1 ? COMPOSE_MIN_PX
    : wanted > capPx
      ? Math.max(COMPOSE_MIN_PX,
                 Math.min(COMPOSE_MAX_PX, Math.floor(capPx / (longest * em))))
      : COMPOSE_MAX_PX;

  const per = Math.max(1, Math.floor(capPx / (px * em)));
  const rows = Math.min(COMPOSE_ROWS,
                        lines.reduce((n, l) => n + Math.max(1, Math.ceil(l.length / per)), 0));

  const line = Math.round(px * 1.45);

  composeInput.style.font =
    `${px}px/${line}px ` + getComputedStyle(document.body).fontFamily;

  const width = px < COMPOSE_MAX_PX || rows > 1
    ? capPx
    : Math.min(capPx, Math.max(longest + 1, 24) * px * em);
  composeInput.style.width = Math.round(width) + 'px';
  composeInput.style.height = (rows * line) + 'px';
}

let charEm = 0;
function charWidth() {
  if (charEm) return charEm;
  const probe = document.createElement('span');
  probe.style.cssText =
    'position:absolute;visibility:hidden;white-space:pre;font:100px/1 ' +
    getComputedStyle(document.body).fontFamily;

  const sample = 'the quick brown fox jumps over the lazy dog 0123456789';
  probe.textContent = sample;
  document.body.appendChild(probe);
  charEm = probe.getBoundingClientRect().width / sample.length / 100;
  probe.remove();
  return charEm || 0.5;
}

let listAt = -1;
let listItems = [];

function renderList() {

  listItems = (composing() && !composeTarget()) ? completions() : [];
  renderRows();
}

function renderRows() {
  composeList.replaceChildren();
  if (!listItems.length) {
    compose.classList.remove('listing');
    listAt = -1;
    return;
  }
  compose.classList.add('listing');
  listItems.forEach((text, i) => {
    const li = document.createElement('li');
    li.textContent = text;
    li.setAttribute('role', 'option');
    li.setAttribute('aria-selected', String(i === listAt));
    if (i === listAt) li.className = 'at';

    li.addEventListener('mousedown', (e) => {
      e.preventDefault();
      takeCompletion(i);
    });
    composeList.appendChild(li);
  });

  if (listAt >= 0) composeList.children[listAt]?.scrollIntoView({ block: 'nearest' });
}

function takeCompletion(i) {
  const text = listItems[i];
  if (text === undefined) return;
  const { start, end } = wordAtCaret();
  const value = composeInput.value;
  composeInput.value = value.slice(0, start) + text + value.slice(end);
  const caret = start + text.length;
  composeInput.setSelectionRange(caret, caret);
  listAt = i;
  sizeCompose();
}

function moveList(step) {
  if (!listItems.length) return;

  if (listAt < 0) listAt = step > 0 ? 0 : listItems.length - 1;
  else listAt = ((listAt + step) % listItems.length + listItems.length) % listItems.length;
  takeCompletion(listAt);

  renderRows();
}

function shutList() {
  listItems = [];
  listAt = -1;
  composeList.replaceChildren();
  compose.classList.remove('listing');
}

let cameFrom = null;

function openCompose(seed) {
  const already = composing();
  compose.classList.remove('shut');

  if (!already) {
    const was = pickedPanel();
    cameFrom = (was && was !== configPanel) ? was : null;
  }
  selectPane(configPanel.root);
  composeFault.textContent = '';
  composeInput.value = seed || '';
  sizeCompose();
  composeInput.focus();
  listAt = -1;
  renderList();

  const end = composeInput.value.length;
  composeInput.setSelectionRange(end, end);
}

function shutCompose() {
  compose.classList.add('shut');
  composeInput.value = '';
  composeFault.textContent = '';
  shutList();
  composeInput.blur();

  const back = cameFrom;
  cameFrom = null;
  if (back && back.root && back.root.isConnected) selectPane(back.root);
}

async function commitCompose() {
  const command = composeInput.value.trim();
  if (!command) { shutCompose(); return; }
  if (busy) return;
  busy = true;
  try {
    const response = await fetch('/config?k=' + encodeURIComponent(window.TOKEN), {
      method: 'POST', body: JSON.stringify({action: 'append', command}),
    });
    const result = await response.json();
    if (!response.ok || !result.lines) throw new Error(result.error || 'Unable to add command');
    lines = result.lines;
    shutCompose();
  } catch (error) { composeFault.textContent = error.message; }
  finally { busy = false; }
}

compose.addEventListener('mousemove', () => compose.classList.add('mousing'));
composeInput.addEventListener('keydown', () => compose.classList.remove('mousing'));

composeInput.addEventListener('beforeinput', (e) => {
  if (!composeTarget()) return;
  const next = nextValue(e);
  if (next === null) return;
  sizeFor(next);
});

composeInput.addEventListener('input', () => {
  sizeCompose();

  listAt = -1;
  renderList();
});

for (const ev of ['click', 'keyup']) {
  composeInput.addEventListener(ev, (e) => {

    if (e.type === 'keyup' && !['ArrowLeft','ArrowRight','Home','End'].includes(e.key)) return;
    listAt = -1;
    renderList();
  });
}

composeInput.addEventListener('keydown', (e) => {

  if (e.ctrlKey && (e.key === 'n' || e.key === 'p') && listItems.length) {
    e.preventDefault();
    moveList(e.key === 'n' ? 1 : -1);
    return;
  }

  if ((e.key === 'ArrowDown' || e.key === 'ArrowUp') && listItems.length) {
    e.preventDefault();
    moveList(e.key === 'ArrowDown' ? 1 : -1);
    return;
  }
  if (e.key === 'Tab' && listItems.length) {

    e.preventDefault();
    if (listAt < 0) takeCompletion(0);
    renderList();
    return;
  }
  if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); commitCompose(); }

  else if (e.key === 'Enter' && e.shiftKey) {
    if (!composeTarget()) e.preventDefault();
  }
  else if (e.key === 'Escape') {
    e.preventDefault();

    if (listItems.length) shutList(); else shutCompose();
  }

  else if (e.key === 'Backspace' && composeInput.value === '') shutCompose();
});

document.addEventListener('keydown', (e) => {
  if (composing()) return;
  if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') return;
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  if (!compose.isConnected) return;

  if (e.key.length !== 1) return;
  if (e.key === ' ') return;

  if (e.defaultPrevented) return;
  e.preventDefault();

  if (!help.classList.contains('shut')) shutHelp();
  openCompose(e.key);
});

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
  if (newTab) openTerminal('top');
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
  altOpened = altPanel.shut;

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

  const target = altPanel || configPanel;
  altPanel = null;

  const peeked = altPeeked;
  altPeeked = null;
  if (peeked) {
    peeked.toggle();
    restore();
    return;
  }
  if (held) {

    if (altOpened) target.toggle();
    restore();
    return;
  }

  if (!altOpened) target.toggle();
  restore();
});

window.addEventListener('blur', () => {
  if (altDown && altOpened && altPanel) altPanel.toggle();
  altPanel = null;
  altDown = false;
});

makeConfigPanel(panel, () => {

  body.querySelector('.config-command input')?.focus({preventScroll: true});
});

const configPaneSaved = !!(window.PANE_POSITIONS && window.PANE_POSITIONS.config);
if (window.START_EMPTY || configPaneSaved) configPanel.showDocument?.(window.CONFIG_FILE);
else { configPanel.dispose(); configPanel.root.remove(); }

wirePanes({
  refitCompose: () => refitCompose(),
});

lines = window.CONFIG_LINES || [];

startRail();

watchSource();
(async () => {
  let generation = -1;
  for (;;) {
    try {
      const response = await fetch('/panes/watch?k=' + encodeURIComponent(window.TOKEN), {
        method: 'POST', body: JSON.stringify({ generation }), signal: AbortSignal.timeout(35000),
      });
      if (!response.ok) {
        if (response.status === 403) { await refreshSession(); generation = -1; }
        throw new Error('pane watch failed');
      }
      const out = await response.json();
      syncPanes(out.ids, out.labels, out.documents);
      generation = out.generation;
    } catch (_) { await new Promise(resolve => setTimeout(resolve, 2000)); }
  }
})();

wireFind({
  moduleNames,
  help,
  shutHelp,
  prefixCandidates,
});
