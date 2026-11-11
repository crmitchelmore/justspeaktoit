// Renders the site's source pages. A page may start with one or more
// `<!-- @include name.html key="value" -->` lines; each is replaced by
// partials/name.html with its {{key}} placeholders filled in. Values are
// inserted as written, so they must already be HTML-escaped. The build, the
// preview server and the page tests all render through here, so they see the
// same HTML that ships.
import { readFile } from 'node:fs/promises';

const root = new URL('./', import.meta.url);
const includeLine = /^<!-- @include ([a-z0-9-]+\.html)((?: [a-z]+="[^"]*")*) -->\n/gm;

export const pages = ['index.html', 'privacy.html', 'support.html'];

export async function renderSource(source, base = root) {
  let html = source;
  for (const match of [...source.matchAll(includeLine)]) {
    const [line, name, attributes] = match;
    const values = Object.fromEntries([...attributes.matchAll(/ ([a-z]+)="([^"]*)"/g)].map(([, key, value]) => [key, value]));
    const partial = await readFile(new URL(`partials/${name}`, base), 'utf8');
    const used = new Set();
    const filled = partial.replace(/\{\{([a-z]+)\}\}/g, (_, key) => {
      if (!Object.hasOwn(values, key)) throw new Error(`${name} needs ${key}`);
      used.add(key);
      return values[key];
    });
    const unused = Object.keys(values).filter(key => !used.has(key));
    if (unused.length > 0) throw new Error(`${name} does not use ${unused.join(', ')}`);
    html = html.replace(line, () => filled);
  }
  return html;
}

export async function renderPage(name, base = root) {
  return renderSource(await readFile(new URL(name, base), 'utf8'), base);
}
