import { cp, mkdir, rm } from 'node:fs/promises';

const output = new URL('./dist/', import.meta.url);
await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
// Keep preview builds complete, including clean privacy URLs and Apple associations.
for (const asset of [
  'index.html', 'privacy.html', 'site.css', 'site.js', 'favicon.svg',
  'download-architecture.js', 'images', '.well-known', '_headers', '_redirects',
]) {
  await cp(new URL(asset, import.meta.url), new URL(asset, output), { recursive: true });
}
