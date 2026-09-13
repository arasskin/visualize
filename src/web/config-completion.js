export function configCompletions(text, caret, {docs = [], colours = [], prefixes = []} = {}) {
  const before = text.slice(0, caret);
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
  const pool = slot === 0 ? docs.flatMap(item => [item.name, `un${item.name}`])
    : kind === 'color' ? colours : kind === 'name' ? [...names] : [];
  const query = word.toLowerCase();
  const items = pool.filter(value => value.toLowerCase().includes(query)).sort((a, b) =>
    a.toLowerCase().indexOf(query) - b.toLowerCase().indexOf(query) || a.length - b.length || a.localeCompare(b));
  return {start, end: caret, items};
}
