import { pane, wire as wireGraph, paint, repaint, fit, fitSoon, isTouched, hatchFolded } from './graph.js';
import {
  find, hits, wire as wireFind, placeArrow, redrawFind, anchorHit, restoreAnchor,
  forgetUnit,
} from './find.js';
import { moduleNames, hideEdge, wireEdges, keepEdgeLabel } from './hover.js';
import {
  configPanel, makeConfigPanel, rail, EDGES,
  selectPane, pickedPanel, revealTab, openTerminal, resnap,
  startRail, wire as wirePanes,
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

async function watchSource() {
  for (;;) {
    try {
      const r = await fetch(`/watch?k=${encodeURIComponent(window.TOKEN)}`, {
        method: 'POST',
        body: JSON.stringify({ generation: sourceGeneration }),
        signal: AbortSignal.timeout(35000),
      });
      const out = await r.json();
      const previous = sourceGeneration;
      const first = sourceGeneration === -1;
      sourceGeneration = out.generation;

      if (out.changed && !first) {
        status.textContent = 'source changed, redrawing...';
        const drawn = await send('run', -1, true);
        if (drawn && Number.isInteger(drawn.generation)) sourceGeneration = drawn.generation;
        else { sourceGeneration = previous; await new Promise(r => setTimeout(r, 50)); }


      }
    } catch (e) {
      await new Promise((r) => setTimeout(r, 2000));
    }
  }
}

const status = document.getElementById('status');
const panel = document.getElementById('config');
const bar = document.getElementById('bar');
const body = document.getElementById('body');
const grip = document.getElementById('grip');
const rows = document.getElementById('lines');
const problems = document.getElementById('problems');

let lines = [];

let faults = {};
let busy = false;

let picked = -1;

function icon(glyph, title, cls) {
  const b = document.createElement('button');
  b.textContent = glyph;
  b.title = title;
  b.className = cls;
  b.disabled = busy;
  return b;
}

function uncomment(text) {
  const at = text.indexOf('#');
  const head = text.slice(0, at);
  let rest = text.slice(at + 1);

  if (rest.startsWith(' ') && !rest.startsWith('  ')) rest = rest.slice(1);
  else if (rest.startsWith('\t')) rest = rest.slice(1);
  return head + rest;
}

function toggleComment(at) {
  const text = lines[at];
  if (text === undefined) return;
  lines[at] = text.trim().startsWith('#') ? uncomment(text) : '#' + text;
  send('run', at);
}

function draw() {

  if (picked >= lines.length) picked = lines.length - 1;
  if (!lines.length) picked = -1;
  rows.replaceChildren();
  lines.forEach((text, i) => {
    const row = document.createElement('div');
    const commented = text.trim().startsWith('#');
    row.className = 'row' + (commented ? ' comment' : '')
                          + (i === picked ? ' picked' : '');

    const hold = document.createElement('span');
    hold.className = 'hold';
    hold.textContent = '⋮⋮';
    hold.title = 'drag to reorder  (alt+h and alt+l carry the selected line)';

    const box = document.createElement('input');
    box.value = text;
    box.spellcheck = false;
    box.disabled = busy;

    box.oninput = () => { lines[i] = box.value; };

    box.addEventListener('beforeinput', (e) => {
      if (altDown) e.preventDefault();
    });

    box.onfocus = () => { pick(i, false); };
    box.onkeydown = (e) => {
      if (e.key === 'Enter') { e.preventDefault(); send('run', i); }
    };

    const up = icon('↑', `insert a line above  (alt+N on the selected line)`, 'up');
    up.onclick = () => send('insert-above', i);
    const down = icon('↓', `insert a line below  (alt+n on the selected line)`, 'down');
    down.onclick = () => send('insert-below', i);
    const hash = icon('#',
      (commented ? 'uncomment this line' : 'comment this line out')
        + '  (alt+c on the selected line)', 'hash');
    hash.onclick = () => toggleComment(i);
    const del = icon('✕', 'delete this line  (alt+d on the selected line)', 'del');
    del.onclick = () => send('delete', i);

    row.append(box, up, down, hash, del, hold);

    const slot = document.createElement('div');
    slot.className = 'slot';
    slot.appendChild(row);
    slot.dataset.at = i;
    if (!busy) hold.onpointerdown = (e) => lift(e, i, slot);

    if (faults[i]) {
      row.classList.add('bad');
      const why = document.createElement('div');
      why.className = 'why';
      why.textContent = faults[i];
      slot.appendChild(why);
    }
    rows.appendChild(slot);
  });

  if (!lines.length) {
    const row = document.createElement('div');
    row.className = 'row';
    const add = icon('+', 'add the first line', 'up');
    add.onclick = () => send('insert-below', -1);
    row.append(add);
    rows.appendChild(row);
  }
}

function lift(down, at, slot) {
  if (busy) return;
  down.preventDefault();

  const box = slot.getBoundingClientRect();
  const grabbedAt = down.clientY - box.top;

  const ghost = slot.cloneNode(true);
  ghost.className = 'slot ghost';
  ghost.style.width = box.width + 'px';
  ghost.style.left = box.left + 'px';
  ghost.style.top = box.top + 'px';
  document.body.appendChild(ghost);

  slot.classList.add('gap');
  slot.style.height = box.height + 'px';

  const others = [...rows.querySelectorAll('.slot')].filter(s => s !== slot);
  others.forEach(s => s.classList.add('sliding'));
  document.body.classList.add('carrying');
  let to = at;

  const anchors = others.map(s => {
    const r = s.getBoundingClientRect();
    return { at: Number(s.dataset.at), middle: r.top + r.height / 2 };
  });
  const height = box.height;

  const follow = (m) => {
    ghost.style.top = (m.clientY - grabbedAt) + 'px';

    const over = anchors.find(a => m.clientY < a.middle);
    to = over ? (over.at > at ? over.at - 1 : over.at) : lines.length - 1;
    to = Math.max(0, Math.min(lines.length - 1, to));

    for (const s of others) {
      const j = Number(s.dataset.at);
      const shifted = (j > at && j <= to) ? -height
                    : (j < at && j >= to) ? height : 0;
      s.style.transform = shifted ? `translateY(${shifted}px)` : '';
    }
  };

  const drop = () => {
    removeEventListener('pointermove', follow);
    removeEventListener('pointerup', drop);
    removeEventListener('pointercancel', drop);
    document.body.classList.remove('carrying');

    const rest = slot.getBoundingClientRect();
    ghost.classList.add('landing');
    ghost.style.top = (rest.top + (to - at) * height) + 'px';
    ghost.style.left = rest.left + 'px';
    let settled = false;
    const finish = () => {

      if (settled) return;
      settled = true;
      ghost.remove();
      slot.classList.remove('gap');
      slot.style.height = '';
      others.forEach(s => { s.classList.remove('sliding'); s.style.transform = ''; });
      if (to !== at) move(at, to);
      else draw();
    };
    ghost.addEventListener('transitionend', finish, { once: true });

    setTimeout(finish, 200);
  };

  addEventListener('pointermove', follow);
  addEventListener('pointerup', drop);
  addEventListener('pointercancel', drop);
}

function move(at, to) {
  const moved = lines.slice();
  moved.splice(to, 0, moved.splice(at, 1)[0]);
  lines = moved;

  picked = afterMove(picked, at, to);

  send('reorder', -1);
}

function afterMove(i, at, to) {
  if (i < 0) return i;
  if (i === at) return to;
  if (at < i && i <= to) return i - 1;
  if (to <= i && i < at) return i + 1;
  return i;
}

async function send(action, index, keepView) {
  if (busy) return;
  busy = true;
  draw();

  status.textContent = keepView ? 'drawing...' : 'saving...';
  const t0 = performance.now();
  try {

    const r = await fetch(`/config?k=${encodeURIComponent(window.TOKEN)}`, {
      method: 'POST',

      body: JSON.stringify({ action, index, lines, draw: !!keepView }),
    });
    const out = await r.json();

    if (!out.lines) {
      problems.textContent = out.error || 'request failed';
      status.textContent = 'error';
    } else {
      lines = out.lines;

      faults = {};
      for (const [at, why] of Object.entries(out.problems || {})) {
        faults[Number(at)] = why;
      }
      problems.textContent = out.error || '';
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
      const count = Object.keys(faults).length;
      const ms = Math.round(performance.now() - t0);

      status.textContent = count
        ? `saved, ${count} line${count > 1 ? 's' : ''} failed`
        : out.svg ? `drawn in ${ms}ms` : 'saved';
    }
    return out;
  } catch (e) {
    problems.textContent = e.message;
    status.textContent = 'error';
  } finally {
    busy = false;
    draw();
  }
}

const help = document.getElementById('help');
const helpOpen = document.getElementById('help-open');

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

helpOpen.addEventListener('click', openHelp);

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

function prefixesOf(name) {
  const parts = name.split('.');
  const out = [];
  for (let i = 1; i <= parts.length; i++) out.push(parts.slice(0, i).join('.'));
  return out;
}

function bindings() {
  const out = [];
  for (const line of lines) {

    for (const form of (line || '').match(/\([^)]*\)/g) || []) {
      const m = /^\(\s*prefix\s+(\S+)\s+(\S+?)\s*\)$/.exec(form);
      if (m) out.push([m[1], m[2]]);
    }
  }
  return out;
}

function prefixCandidates() {
  const svg = pane.querySelector('svg');
  const names = [];
  if (svg) {
    for (const node of svg.querySelectorAll('g.node')) {
      const title = node.querySelector('title');
      if (title) names.push(title.textContent.trim());
    }
  }
  const seen = new Set();
  for (const name of names) for (const p of prefixesOf(name)) seen.add(p);

  for (const [alias, stands] of bindings()) {
    seen.add(alias);
    for (const p of seen.size ? [...seen] : []) {
      if (p === stands) continue;
      if (p.startsWith(stands + '.')) seen.add(alias + p.slice(stands.length));
    }
  }
  return [...seen];
}

function rank(candidates, typed) {
  const q = typed.toLowerCase();
  const hits = [];
  for (const c of candidates) {
    const at = c.toLowerCase().indexOf(q);
    if (at < 0) continue;
    hits.push({ text: c, at, len: c.length });
  }
  hits.sort((a, b) => (a.at - b.at) || (a.len - b.len) || a.text.localeCompare(b.text));
  return hits.map(h => h.text);
}

function wordAtCaret() {
  const text = composeInput.value;
  const caret = composeInput.selectionStart ?? text.length;
  const before = text.slice(0, caret);
  const start = before.lastIndexOf(' ') + 1;

  const slot = before.slice(0, start).split(/\s+/).filter(Boolean).length;
  return { word: before.slice(start), start, end: caret, slot };
}

function poolFor(slot) {
  const text = composeInput.value;
  const verb = text.trimStart().split(/\s+/)[0] || '';
  if (slot === 0) return (window.CONFIG_DOCS || []).map(d => d.name);

  const spec = (window.CONFIG_DOCS || []).find(d => d.name === verb);
  if (!spec) return [];

  const kind = (spec.args || [])[slot - 1];
  if (!kind) return [];
  switch (kind.replace(/\?$/, '')) {
    case 'color': return window.CONFIG_COLOURS || [];

    case 'name': return prefixCandidates();
    default: return [];
  }
}

function completions() {
  const { word, slot } = wordAtCaret();
  return rank(poolFor(slot), word);
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

async function checkLines(candidate, at) {
  try {
    const r = await fetch(`/config?k=${encodeURIComponent(window.TOKEN)}`, {
      method: 'POST',
      body: JSON.stringify({ action: 'check', index: -1, lines: candidate }),
    });
    const out = await r.json();
    return (out.problems || {})[String(at)] || '';
  } catch (_) {

    return '';
  }
}

async function commitCompose() {

  const text = composeInput.value.trim();
  if (!text) { shutCompose(); return; }
  if (busy) return;

  const call = `(${text})`;
  const at = picked >= 0 && picked < lines.length ? picked : lines.length;
  const base = (lines[at] ?? '').trim();
  const merged = base ? `${base} ${call}` : call;
  const candidate = lines.slice(0, at).concat([merged], lines.slice(at + 1));

  composeFault.textContent = '';
  const why = await checkLines(candidate, at);
  if (why) {
    composeFault.textContent = why;
    composeInput.focus();
    composeInput.setSelectionRange(text.length, text.length);
    return;
  }

  lines = candidate;
  picked = at;
  await send('run', -1);
  shutCompose();
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

function pick(at, focus = true) {
  if (!lines.length) { picked = -1; return; }

  picked = ((at % lines.length) + lines.length) % lines.length;
  const slots = [...rows.children];
  slots.forEach((slot, i) => {
    slot.querySelector('.row')?.classList.toggle('picked', i === picked);
  });
  const box = slots[picked]?.querySelector('input');
  if (box) {

    box.scrollIntoView({ block: 'nearest' });
    if (focus) box.focus();
  }
}

function altChord(e) {

  const down = e.code === 'KeyJ' || e.code === 'ArrowDown';
  const up = e.code === 'KeyK' || e.code === 'ArrowUp';
  const del = e.code === 'KeyD';
  const comment = e.code === 'KeyC';

  const walkLeft = e.code === 'KeyH' || e.code === 'ArrowLeft';
  const walkRight = e.code === 'KeyL' || e.code === 'ArrowRight';

  const fresh = e.code === 'KeyN';

  const newTab = e.code === 'Enter' || e.code === 'NumpadEnter';
  if (!down && !up && !del && !comment && !fresh && !walkLeft && !walkRight
      && !newTab) {
    return false;
  }
  e.preventDefault();

  if (newTab) {
    openTerminal();
    return true;
  }

  if (walkLeft || walkRight) {
    altWalk(walkRight ? 1 : -1);
    return true;
  }

  const nothingPicked = picked < 0 || picked >= lines.length;

  if (configPanel.shut) configPanel.open();

  if (down || up) {
    pick(picked < 0 ? (down ? 0 : -1) : picked + (down ? 1 : -1));
    return true;
  }

  if (busy) return true;

  if (fresh) {

    const at = nothingPicked ? lines.length : picked + (e.shiftKey ? 0 : 1);
    lines = lines.slice(0, at).concat([''], lines.slice(at));
    picked = at;
    send('run', at);
    return true;
  }

  if (nothingPicked) return true;
  if (del) send('delete', picked);
  else toggleComment(picked);
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

  const off = rail.indexOf(pickedPanel()) < 0;
  if (rail.length < (off ? 1 : 2)) return;

  const here = rail.indexOf(pickedPanel());

  const to = here < 0
    ? (by > 0 ? 0 : rail.length - 1)
    : Math.max(0, Math.min(rail.length - 1, here + by));
  if (to === here) return;
  const next = rail[to];

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

  const boxes = body.querySelectorAll('input');
  (boxes[picked >= 0 ? picked : 0])?.focus();
});

wirePanes({
  refitCompose: () => refitCompose(),
});

lines = window.CONFIG_LINES || [];
for (const [at, why] of Object.entries(window.CONFIG_PROBLEMS || {})) {
  faults[Number(at)] = why;
}
draw();

if (Object.keys(faults).length) requestAnimationFrame(() => bar.click());

startRail();

watchSource();

wireFind({
  moduleNames,
  help,
  shutHelp,
  rank,
  prefixCandidates,
});
