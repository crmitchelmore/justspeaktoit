// Pages are rendered from chrome.mjs: one header/footer source, clip markup
// projected from the clip list, and one named Stable display version.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { clips, pages, renderMarkup, renderPage, stable } from './chrome.mjs';

const rendered = Object.fromEntries(await Promise.all(pages.map(async page => [page, await renderPage(page)])));
const read = file => readFile(new URL(file, import.meta.url), 'utf8');
const between = (html, open, close) => {
  const start = html.indexOf(open);
  assert.notEqual(start, -1, `Missing ${open}`);
  return html.slice(start, html.indexOf(close, start) + close.length);
};

test('every page renders without leftover markers and keeps its chrome in chrome.mjs', async () => {
  for (const page of pages) {
    const source = await read(page);
    assert.doesNotMatch(rendered[page], /<!-- (partial|clip|stable):/, `${page} has no leftover markers`);
    assert.doesNotMatch(source, /<header\b|<footer\b|<nav\b|<video\b/, `${page} does not hand-write chrome or clips`);
    assert.equal((rendered[page].match(/<footer\b/g) || []).length, 1, `${page} has one footer`);
  }
});

test('privacy and support share one document chrome', () => {
  const chrome = html => [between(html, '<style>', '</style>'), between(html, '<nav', '</nav>'),
    between(html, '<footer', '</footer>')];
  assert.deepEqual(chrome(rendered['privacy.html']), chrome(rendered['support.html']));
});

test('every footer links the legal pages and states the same licence', () => {
  const footers = pages.map(page => between(rendered[page], '<footer', '</footer>'));
  for (const footer of footers) {
    assert.match(footer, /href="\/privacy"/);
    assert.match(footer, /href="\/support"/);
    assert.match(footer, /© 2026 Chris Mitchelmore · MIT licensed/);
  }
});

test('clip markup is generated for every listed clip in light/dark WebM and MP4 order', () => {
  const html = rendered['index.html'];
  const onPage = [...html.matchAll(/data-clip="([a-z]+)"/g)].map(match => match[1]);
  assert.deepEqual(onPage, Object.keys(clips), 'Every clip on the page comes from the clip list');
  for (const [name, clip] of Object.entries(clips)) {
    const video = between(html, `<video class="clip-video" controls playsinline preload="none" width="${clip.width}"`,
      '</video>');
    assert.match(video, new RegExp(`aria-label="${clip.label}" aria-describedby="clip-${name}-caption"`));
    assert.ok(html.includes(`id="clip-${name}-caption"`), `${name} keeps its own caption`);
    assert.deepEqual([...video.matchAll(/<source src="([^"]+)"/g)].map(match => match[1]),
      ['dark.webm', 'light.webm', 'dark.mp4', 'light.mp4'].map(variant => `/images/clips/${name}-${variant}`));
    assert.equal((video.match(/media="\(prefers-color-scheme: dark\)"/g) || []).length, 2);
    assert.match(video, new RegExp(`<track kind="captions" src="/images/clips/${name}\\.en\\.vtt"`));
    assert.match(video, new RegExp(`<a href="/images/clips/${name}-light\\.mp4" data-clip-download="${name}">`));
  }
});

test('the Stable display version names the GitHub Latest release the Mac downloads use', async () => {
  assert.match(stable.mac.version, /^\d+\.\d+\.\d+$/);
  assert.equal(stable.mac.tag, `mac-v${stable.mac.version}`);
  assert.ok(rendered['index.html'].includes(`Stable · v${stable.mac.version}</span>`));
  // Stable downloads and feeds resolve GitHub Latest statically; Alpha routes
  // resolve their own pointer in the Worker and never feed this label.
  const redirects = await read('_redirects');
  for (const route of ['/download/mac', '/download/mac-intel', '/appcast.xml']) {
    assert.match(redirects, new RegExp(`^${route.replaceAll('.', '\\.')}\\s+https://github\\.com/crmitchelmore/justspeaktoit/releases/latest/download/`, 'm'));
  }
  assert.doesNotMatch(redirects, /alpha/i);
});

test('an unknown marker fails the build instead of shipping', async () => {
  await assert.rejects(renderMarkup('<!-- partial:nope -->'), /Unknown partial: nope/);
  await assert.rejects(renderMarkup('  <!-- clip:nope -->'), /Unknown clip: nope/);
  await assert.rejects(renderMarkup('<p><!-- partial:site-header --></p>'), /Unrendered marker/);
});
