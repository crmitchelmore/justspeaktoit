import { createHash } from 'node:crypto';
import { cp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';

const output = new URL('./dist/', import.meta.url);
await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
// Keep preview builds complete, including clean privacy URLs and Apple associations.
// _routes.json is intentionally excluded: its legacy "routes"/"headers" shape
// is not Cloudflare's Functions routing schema. Static cache policy is in _headers.
for (const asset of [
  'index.html', 'privacy.html', 'site.css', 'favicon.svg', 'favicon-32.png', 'apple-touch-icon.png',
  'icon-192.png', 'icon-512.png', 'site.webmanifest',
  'download-architecture.js', 'images', '.well-known', '_headers', '_redirects',
]) {
  await cp(new URL(asset, import.meta.url), new URL(asset, output), { recursive: true });
}

// A new URL prevents an older CDN/browser stylesheet being paired with new HTML.
// Keep source previews simple while making every production build cache-safe.
const css = await readFile(new URL('site.css', output));
const stylesheet = `site.${createHash('sha256').update(css).digest('hex').slice(0, 12)}.css`;
await writeFile(new URL(stylesheet, output), css);
const index = new URL('index.html', output);
const html = await readFile(index, 'utf8');
if (!html.includes('href="/site.css"')) throw new Error('Missing source stylesheet link');
await writeFile(index, html.replace('href="/site.css"', `href="/${stylesheet}"`));
