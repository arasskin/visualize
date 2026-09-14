import { markdownReader } from './markdown.js';
import { sourceReader } from './source.js';
import { configReader } from '../config/editor.js';

export function documentReader(panel, id, file, options = {}) {
  if (/(^|[/\\])visualize_config$/.test(file)) return configReader(panel, id, file, options);
  return /\.(md|markdown|mdown)$/i.test(file) ? markdownReader(panel, id, file) : sourceReader(panel, id, file);
}
