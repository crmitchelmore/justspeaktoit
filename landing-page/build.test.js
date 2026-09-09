import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { appendFile, cp, mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const source = fileURLToPath(new URL('.', import.meta.url));

test('deployed HTML gets a new stylesheet URL only when its CSS changes', async t => {
  const directory = await mkdtemp(path.join(tmpdir(), 'speak-website-build-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const fixture = path.join(directory, 'site');
  await cp(source, fixture, {
    recursive: true,
    filter: filename => !['dist', 'node_modules'].includes(path.relative(source, filename).split(path.sep)[0]),
  });
  const build = async () => {
    execFileSync(process.execPath, [path.join(fixture, 'build.mjs')]);
    const html = await readFile(path.join(fixture, 'dist/index.html'), 'utf8');
    const stylesheet = html.match(/href="\/(site\.[a-f0-9]{12}\.css)"/)?.[1];
    assert.ok(stylesheet, 'Production HTML must reference a fingerprinted stylesheet');
    assert.ok(!html.includes('href="/site.css"'), 'Do not reuse the stale stylesheet URL');
    assert.deepEqual(await readFile(path.join(fixture, 'dist', stylesheet)),
      await readFile(path.join(fixture, 'site.css')), 'The referenced asset must contain current CSS');
    return stylesheet;
  };

  const first = await build();
  assert.equal(await build(), first, 'Unchanged CSS should reuse its cache entry');
  await appendFile(path.join(fixture, 'site.css'), '\n/* A new design revision. */\n');
  assert.notEqual(await build(), first, 'A design change must invalidate the old cached URL');
});
