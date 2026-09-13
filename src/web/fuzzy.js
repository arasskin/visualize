function normalize(text) {
  return text.toLowerCase().replace(/[_\s]+/gu, ' ').trim();
}

export function fuzzyScore(text, query) {
  const hay = normalize(text);
  const needle = normalize(query);
  if (!needle || hay === needle) return 0;
  const at = hay.indexOf(needle);
  if (at >= 0) return (at === 0 ? 1 : 2) + at / (hay.length + 1);

  let cursor = 0;
  let first = -1;
  let previous = -1;
  let gaps = 0;
  let interiors = 0;
  for (const character of needle.replace(/ /g, '')) {
    const position = hay.indexOf(character, cursor);
    if (position < 0) return Infinity;
    if (first < 0) first = position;
    if (previous >= 0) gaps += position - previous - 1;
    if (position > 0 && !/[ ./\\-]/u.test(hay[position - 1])) interiors++;
    previous = position;
    cursor = position + character.length;
  }
  const penalty = gaps * 2 + interiors + first / (hay.length + 1);
  return 3 + penalty / (penalty + 1);
}

export function fuzzyRank(candidates, query) {
  return candidates.map(text => ({ text, score: fuzzyScore(text, query) }))
    .filter(hit => Number.isFinite(hit.score))
    .sort((a, b) => a.score - b.score || a.text.length - b.text.length || a.text.localeCompare(b.text))
    .map(hit => hit.text);
}
