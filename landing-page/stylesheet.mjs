// The site stylesheet, kept as one file per page section under styles/.
// build.mjs and serve.ts publish the sections concatenated as /site.css; this
// list is the cascade order, so a later section still overrides an earlier one.
import { readFile } from 'node:fs/promises';

export const styleSections = [
  'tokens', // design tokens and the light palette
  'base', // reset, typography, focus and skip link
  'header',
  'buttons',
  'furniture', // section spacing, eyebrows, section heads and cards
  'hero',
  'captures', // screenshots and clips
  'steps',
  'ownership',
  'providers',
  'mobile',
  'automation',
  'downloads',
  'footer',
  'display-modes', // HDR wordmark, print/forced colours and light-mode overrides
];

/** The published /site.css: every section in cascade order, one blank line apart. */
export async function renderStylesheet() {
  const sections = await Promise.all(styleSections.map(name =>
    readFile(new URL(`styles/${name}.css`, import.meta.url), 'utf8')));
  return sections.join('\n');
}
