function undoCommands(lines, docs) {
  const commands = new Set();
  for (const line of lines) {
    const match = /^\s*([a-z]+)((?:[ \t]+(?:"[^"]*"|[^\s()"#]+))*)[ \t]*(?:#.*)?$/.exec(line);
    if (!match) continue;
    const spec = docs.find(item => item.name === match[1]);
    if (!spec) continue;
    const parameters = spec.args || [];
    const args = (match[2].match(/"[^"]*"|[^\s"]+/g) || []).map(value => value.replace(/^"|"$/g, ''));
    if (args.length < parameters.filter(arg => !arg.endsWith('?')).length || args.length > parameters.length) continue;
    commands.add(['un' + spec.name, ...args.map(value => /[\s()#"]/.test(value) || !value ? `"${value}"` : value)].join(' '));
  }
  return [...commands];
}

export function configCompletions(text, caret, {docs = [], colours = [], prefixes = [], lines = []} = {}) {
  const before = text.slice(0, caret);
  if (before.trimStart().startsWith('un')) {
    const normalize = value => value.replaceAll('"', '').replace(/\s+/g, ' ').trimStart().toLowerCase();
    const query = normalize(before);
    const items = undoCommands(lines, docs).filter(value => normalize(value).includes(query)).sort((a, b) =>
      a.length - b.length || a.localeCompare(b));
    return {start: 0, end: text.length, items, wholeLine: true};
  }
  const match = /(?:"[^"]*"|[^\s"]+|"[^"]*)$/.exec(before);
  const start = match ? match.index : caret;
  const word = before.slice(start).replace(/^"/, '');
  const words = before.slice(0, start).match(/"[^"]*"|\S+/g) || [];
  const slot = words.length;
  const verb = words[0]?.startsWith('un') ? words[0].slice(2) : words[0];
  const spec = docs.find(item => item.name === verb);
  const kind = spec?.args?.[slot - 1]?.replace(/\?$/, '');
  const names = new Set();
  for (const name of prefixes) {
    const parts = name.split('.');
    for (let i = 1; i <= parts.length; i++) names.add(parts.slice(0, i).join('.'));
  }
  const pool = slot === 0 ? [...docs.map(item => item.name), ...new Set(undoCommands(lines, docs).map(line => line.split(' ')[0]))]
    : kind === 'color' ? colours : kind === 'name' ? [...names] : [];
  const query = word.toLowerCase();
  const items = pool.filter(value => value.toLowerCase().includes(query)).sort((a, b) =>
    a.toLowerCase().indexOf(query) - b.toLowerCase().indexOf(query) || a.length - b.length || a.localeCompare(b));
  return {start, end: caret, items};
}
