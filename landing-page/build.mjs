import { createHash } from 'node:crypto';
import { cp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { loadCatalogue } from './qa/manual-checks.mjs';
import { renderQaPage } from './qa/render.mjs';

const output = new URL('./dist/', import.meta.url);
await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
// Keep preview builds complete, including clean privacy URLs and Apple associations.
// Only Alpha endpoints invoke the Worker; Stable routes stay on static Pages.
for (const asset of [
  '_worker.js', '_routes.json', 'index.html', 'privacy.html', 'support.html', 'site.css', 'favicon.svg', 'favicon-32.png', 'apple-touch-icon.png',
  'icon-192.png', 'icon-512.png', 'site.webmanifest',
  'download-architecture.js', 'voice-motion.js', 'clips.js', 'images', '.well-known', '_headers', '_redirects',
]) {
  await cp(new URL(asset, import.meta.url), new URL(asset, output), { recursive: true });
}

// New URLs prevent older CDN/browser styles or motion being paired with new HTML.
// Keep source previews simple while making every production build cache-safe.
const index = new URL('index.html', output);
let html = await readFile(index, 'utf8');
for (const [name, extension, attribute] of [['site', 'css', 'href'], ['voice-motion', 'js', 'src'], ['clips', 'js', 'src']]) {
  const bytes = await readFile(new URL(`${name}.${extension}`, output));
  const filename = `${name}.${createHash('sha256').update(bytes).digest('hex').slice(0, 12)}.${extension}`;
  await writeFile(new URL(filename, output), bytes);
  const reference = `${attribute}="/${name}.${extension}"`;
  if (!html.includes(reference)) throw new Error(`Missing source asset link: ${reference}`);
  html = html.replace(reference, `${attribute}="/${filename}"`);
}
await writeFile(index, html);

// The owner's manual QA checklist is rendered from the repository catalogue so
// the page and the results workflow always share one source of truth.
const catalogueSource = await readFile(new URL('../Docs/manual-checks.yml', import.meta.url), 'utf8');
const qa = new URL('qa/', output);
await mkdir(qa, { recursive: true });
await writeFile(new URL('index.html', qa), renderQaPage(loadCatalogue(catalogueSource)));
for (const [source, target] of [['qa.js', 'qa.js'], ['qa.css', 'qa.css'], ['results-format.mjs', 'results-format.js']]) {
  await cp(new URL(`qa/${source}`, import.meta.url), new URL(target, qa));
}
