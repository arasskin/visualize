import {documentFeed} from './feed.js';
import {addDocumentZoom} from './controls.js';
const cKeywords = new Set('auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while _Bool _Complex _Atomic'.split(' '));
const lispForms = new Set('def defn defmacro fn lambda let if cond case when unless do loop each for map reduce quote quasiquote unquote set import require use'.split(' '));
const pythonKeywords = new Set('and as assert async await break case class continue def del elif else except finally for from global if import in is lambda match nonlocal not or pass raise return try while with yield True False None'.split(' '));
const javascriptKeywords = new Set('as async await break case catch class const continue debugger default delete do else export extends finally for from function get if import in instanceof let new of return set static super switch this throw try typeof var void while with yield true false null undefined'.split(' '));

function languageFor(file) {
  const name = file.toLowerCase();
  if (/\.(lisp|lsp|cl|clj|cljs|cljd|janet|scm|ss)$/.test(name)) return 'lisp';
  if (/\.(py|pyw)$/.test(name)) return 'python';
  if (/\.(js|mjs|cjs|jsx)$/.test(name)) return 'javascript';
  return 'c';
}

function tokenClass(value, language, kind) {
  if (kind) return kind;
  if (/^\d/.test(value)) return 'number';
  if (language === 'lisp' && (value.startsWith(':') || lispForms.has(value))) return value.startsWith(':') ? 'keyword' : 'function';
  if (language === 'c' && cKeywords.has(value)) return 'keyword';
  if (language === 'python' && pythonKeywords.has(value)) return 'keyword';
  if (language === 'javascript' && javascriptKeywords.has(value)) return 'keyword';
  return '';
}

function scanLine(line, language, blockComment) {
  const parts = [];
  let i = 0;
  const push = (text, kind = '') => { if (text) parts.push({text, kind: tokenClass(text, language, kind)}); };
  while (i < line.length) {
    if (blockComment.value) {
      const end = line.indexOf('*/', i);
      if (end < 0) { push(line.slice(i), 'comment'); break; }
      push(line.slice(i, end + 2), 'comment'); i = end + 2; blockComment.value = false; continue;
    }
    if ((language === 'lisp' && line[i] === ';') || (language === 'python' && line[i] === '#') || ((language === 'c' || language === 'javascript') && line.startsWith('//', i))) { push(line.slice(i), 'comment'); break; }
    if ((language === 'c' || language === 'javascript') && line.startsWith('/*', i)) {
      const end = line.indexOf('*/', i + 2);
      if (end < 0) { push(line.slice(i), 'comment'); blockComment.value = true; break; }
      push(line.slice(i, end + 2), 'comment'); i = end + 2; continue;
    }
    if (line[i] === '"' || line[i] === "'" || (language === 'javascript' && line[i] === '`')) {
      const quote = line[i]; let j = i + 1;
      while (j < line.length) { if (line[j] === '\\') j += 2; else if (line[j++] === quote) break; }
      push(line.slice(i, j), 'string'); i = j; continue;
    }
    if ((language === 'c' || language === 'python') && line.slice(0, i).trim() === '' && line[i] === '#') { push(line.slice(i), 'directive'); break; }
    if (language === 'python' && line[i] === '@' && line.slice(0, i).trim() === '') {
      let j = i + 1; while (j < line.length && /[A-Za-z0-9_.]/.test(line[j])) j++;
      push(line.slice(i, j), 'decorator'); i = j; continue;
    }
    if (language === 'javascript' && line[i] === '/' && line[i + 1] !== '/' && line[i + 1] !== '*' && /[A-Za-z0-9[(=,:;!&|?{}]/.test(line.slice(0, i).trimEnd().slice(-1))) {
      let j = i + 1; let escaped = false;
      while (j < line.length) { if (!escaped && line[j] === '/') { j++; while (/[a-z]/i.test(line[j] || '')) j++; break; } escaped = !escaped && line[j] === '\\'; if (line[j] !== '\\') escaped = false; j++; }
      if (line[j - 1] === '/') { push(line.slice(i, j), 'regex'); i = j; continue; }
    }
    if (/[A-Za-z_:$]/.test(line[i])) {
      let j = i + 1;
      while (j < line.length && /[A-Za-z0-9_!?$-]/.test(line[j])) j++;
      push(line.slice(i, j)); i = j; continue;
    }
    if (/\d/.test(line[i])) {
      let j = i + 1; while (j < line.length && /[A-Za-z0-9_.]/.test(line[j])) j++;
      push(line.slice(i, j)); i = j; continue;
    }
    push(line[i]); i++;
  }
  return parts;
}

function render(code, text, language) {
  const blockComment = {value: false};
  for (const line of text.split('\n')) {
    const row = document.createElement('span'); row.className = 'source-line';
    if (language === 'text') { row.textContent = line; code.append(row); continue; }
    for (const part of scanLine(line, language, blockComment)) {
      const node = document.createElement('span');
      if (part.kind) node.className = 'source-' + part.kind;
      node.textContent = part.text; row.append(node);
    }
    code.append(row);
  }
}

export function sourceReader(panel, id, file) {
  const viewport = document.createElement('div'); viewport.className = 'source-viewport'; viewport.tabIndex = 0;
  viewport.setAttribute('aria-label', file);
  const status = document.createElement('div'); status.className = 'source-status'; status.setAttribute('role', 'status');
  const pre = document.createElement('pre'); pre.className = 'source-document';
  const code = document.createElement('code'); pre.append(code); viewport.append(status, pre); panel.body.append(viewport);
  addDocumentZoom(viewport, pre);
  const feed = documentFeed(panel, id, result => {
    const top = viewport.scrollTop; code.replaceChildren();
    render(code, result.text, result.language || languageFor(file)); viewport.scrollTop = top;
  }, status);
  return {focus() { viewport.focus({preventScroll: true}); feed.refresh(); }, stop() { feed.stop(); viewport.remove(); }};
}
