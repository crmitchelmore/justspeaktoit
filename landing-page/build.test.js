import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { appendFile, cp, mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const source = fileURLToPath(new URL('.', import.meta.url));

test('deployed styles and motion get new URLs only when their content changes', async t => {
  const directory = await mkdtemp(path.join(tmpdir(), 'speak-website-build-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const fixture = path.join(directory, 'site');
  await cp(source, fixture, {
    recursive: true,
    filter: filename => !['dist', 'node_modules'].includes(path.relative(source, filename).split(path.sep)[0]),
  });
  await cp(path.join(source, '../Docs/manual-checks.yml'), path.join(directory, 'Docs/manual-checks.yml'));
  const build = async () => {
    execFileSync(process.execPath, [path.join(fixture, 'build.mjs')]);
    const html = await readFile(path.join(fixture, 'dist/index.html'), 'utf8');
    const stylesheet = html.match(/href="\/(site\.[a-f0-9]{12}\.css)"/)?.[1];
    assert.ok(stylesheet, 'Production HTML must reference a fingerprinted stylesheet');
    assert.ok(!html.includes('href="/site.css"'), 'Do not reuse the stale stylesheet URL');
    assert.deepEqual(await readFile(path.join(fixture, 'dist', stylesheet)),
      await readFile(path.join(fixture, 'site.css')), 'The referenced asset must contain current CSS');
    assert.equal((html.match(/class="brand-wordmark"/g) || []).length, 2, 'Only the existing header/footer wordmarks are accented');
    assert.deepEqual(await readFile(path.join(fixture, 'dist/images/wordmark-white-1.5x.jpg')),
      await readFile(path.join(fixture, 'images/wordmark-white-1.5x.jpg')), 'Preserve the HDR gain map byte-for-byte');
    const motion = html.match(/src="\/(voice-motion\.[a-f0-9]{12}\.js)"/)?.[1];
    assert.ok(motion, 'Production HTML must reference fingerprinted motion');
    assert.ok(!html.includes('src="/voice-motion.js"'), 'Do not reuse a stale script URL');
    assert.deepEqual(await readFile(path.join(fixture, 'dist', motion)),
      await readFile(path.join(fixture, 'voice-motion.js')), 'The deployed script must contain current motion');
    return { stylesheet, motion };
  };

  const first = await build();
  assert.deepEqual(await build(), first, 'Unchanged assets should reuse their cache entries');
  await appendFile(path.join(fixture, 'site.css'), '\n/* A new design revision. */\n');
  const next = await build();
  assert.notEqual(next.stylesheet, first.stylesheet, 'A design change must invalidate the old cached URL');
  assert.equal(next.motion, first.motion, 'A CSS change should not invalidate the script');
  await appendFile(path.join(fixture, 'voice-motion.js'), '\n// A new motion revision.\n');
  const last = await build();
  assert.notEqual(last.motion, next.motion, 'A motion change must invalidate the old script URL');
  assert.equal(last.stylesheet, next.stylesheet, 'A script change should not invalidate CSS');
});


// Read nested CSS blocks by their actual brace boundaries, not comments or EOF.
function cssBlock(css, prelude) {
  const start = css.indexOf(prelude);
  assert.notEqual(start, -1, `Missing CSS rule: ${prelude}`);
  const opening = css.indexOf('{', start + prelude.length);
  let depth = 1;
  for (let i = opening + 1; i < css.length; i += 1) {
    if (css[i] === '{') depth += 1;
    if (css[i] === '}' && --depth === 0) return css.slice(opening + 1, i);
  }
  assert.fail(`Unclosed CSS rule: ${prelude}`);
}

test('HDR wordmarks are narrowly gated and retain readable fallbacks', async () => {
  const css = await readFile(path.join(source, 'site.css'), 'utf8');
  const media = cssBlock(css, '@media screen and (dynamic-range: high) and (prefers-color-scheme: dark) and (forced-colors: none)');
  const supports = cssBlock(media, '@supports ((background-clip: text) or (-webkit-background-clip: text))');
  const wordmark = cssBlock(supports, '.brand-wordmark ');
  assert.match(wordmark, /background-color: var\(--text\)/);
  assert.match(wordmark, /background-image: url\("\/images\/wordmark-white-1\.5x\.jpg"\)/);
  assert.match(wordmark, /padding: \.12em \.08em/);
  assert.match(wordmark, /background-clip: text/);
  assert.match(wordmark, /-webkit-text-fill-color: transparent/);
  const selection = cssBlock(supports, '.brand-wordmark::selection');
  assert.match(selection, /background: Highlight/);
  assert.match(selection, /color: HighlightText/);
  assert.match(selection, /-webkit-text-fill-color: HighlightText/);
  const fallbackMedia = cssBlock(css, '@media print, (forced-colors: active)');
  const fallback = cssBlock(fallbackMedia, '.brand-wordmark ');
  assert.match(fallback, /background: none/);
  assert.match(fallback, /color: inherit/);
  assert.match(fallback, /-webkit-text-fill-color: currentColor/);
  // Assert every selector inside the HDR gates, so hero/body rules cannot slip in.
  assert.deepEqual([...supports.matchAll(/([^{}]+)\{/g)].map(match => match[1].trim()),
    ['.brand-wordmark', '.brand-wordmark::selection']);
});

test('every clip on the page ships narrated light and dark variants with posters and captions', async () => {
  const html = await readFile(path.join(source, 'index.html'), 'utf8');
  const names = [...html.matchAll(/data-clip="([a-z]+)"/g)].map(match => match[1]);
  assert.ok(names.length >= 4, 'The hero and at least three feature clips are on the page');
  for (const name of names) {
    for (const variant of ['light', 'dark']) {
      for (const suffix of ['.mp4', '.webm', '-poster.webp']) {
        await readFile(path.join(source, 'images/clips', `${name}-${variant}${suffix}`));
      }
      assert.ok(html.includes(`/images/clips/${name}-${variant}.webm`), `${name} offers its ${variant} WebM`);
    }
    assert.match(await readFile(path.join(source, 'images/clips', `${name}.en.vtt`), 'utf8'), /^WEBVTT/);
  }
  const videos = html.match(/<video class="clip-video"[^>]*>/g);
  assert.ok(videos.every(tag => tag.includes('preload="none"') && !/\bautoplay\b/.test(tag)), 'Clips never preload or autoplay');
});
