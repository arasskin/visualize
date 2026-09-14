function normalize(text) {
  return text.toLowerCase().replace(/[_\s]+/gu, ' ').trim();
}

export function matchesText(text, query) {
  return normalize(text).includes(normalize(query));
}
