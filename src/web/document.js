import { markdownReader } from './markdown.js';
import { sourceReader } from './source.js';
import { configReader } from './config-editor.js';

export function documentReader(panel, id, file) {
  if (/[/\\]visualize\.conf$/i.test(file)) return configReader(panel, id, file);
  return /\.(md|markdown|mdown)$/i.test(file) ? markdownReader(panel, id, file) : sourceReader(panel, id, file);
}
