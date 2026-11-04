import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { cp, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { catalogueItems, loadCatalogue, parseResults } from './qa/manual-checks.mjs';
import { renderQaPage } from './qa/render.mjs';
import { formatResultsIssue, newIssueUrl } from './qa/results-format.mjs';

const source = fileURLToPath(new URL('.', import.meta.url));
const catalogueSource = await readFile(new URL('../Docs/manual-checks.yml', import.meta.url), 'utf8');
const catalogue = loadCatalogue(catalogueSource);

test('the build publishes a noindex checklist rendered from the catalogue', async t => {
  const directory = await mkdtemp(path.join(tmpdir(), 'speak-website-qa-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const fixture = path.join(directory, 'site');
  await cp(source, fixture, {
    recursive: true,
    filter: filename => !['dist', 'node_modules'].includes(path.relative(source, filename).split(path.sep)[0]),
  });
  await cp(path.join(source, '../Docs/manual-checks.yml'), path.join(directory, 'Docs/manual-checks.yml'));
  execFileSync(process.execPath, [path.join(fixture, 'build.mjs')]);
  const html = await readFile(path.join(fixture, 'dist/qa/index.html'), 'utf8');
  assert.match(html, /<meta name="robots" content="noindex, nofollow">/);
  for (const item of Object.values(catalogueItems(catalogue))) assert.ok(html.includes(`data-id="${item.id}"`), item.id);
  const data = JSON.parse(html.match(/<script id="qa-data" type="application\/json">([^<]*)<\/script>/)[1]);
  assert.equal(data.catalogue, catalogue.hash);
  assert.doesNotMatch(html, /<script[^>]+src="https?:/, 'No third-party scripts');
  for (const asset of ['qa.js', 'qa.css', 'results-format.js']) {
    assert.ok((await readFile(path.join(fixture, 'dist/qa', asset), 'utf8')).length > 0, asset);
  }
  const script = await readFile(path.join(fixture, 'dist/qa/qa.js'), 'utf8');
  assert.match(script, /from '\.\/results-format\.js'/);
  const headers = await readFile(path.join(fixture, 'dist/_headers'), 'utf8');
  assert.match(headers, /\/qa\/\*\n {2}X-Robots-Tag: noindex, nofollow/);

  // A catalogue error must fail the build rather than publish a broken page.
  await writeFile(path.join(directory, 'Docs/manual-checks.yml'), 'version: 2\n');
  assert.throws(() => execFileSync(process.execPath, [path.join(fixture, 'build.mjs')], { stdio: 'pipe' }));
});

test('catalogue text is escaped in markup and embedded data', () => {
  const hostile = loadCatalogue(catalogueSource.replace(/title: "[^"]*"/, 'title: "<img src=x onerror=alert(1)> </script>"'));
  const html = renderQaPage(hostile);
  assert.ok(!html.includes('<img src=x'));
  assert.equal((html.match(/<\/script>/g) || []).length, 2, 'Only the two real script elements close');
});

test('a submitted page produces an issue the workflow accepts', () => {
  const items = catalogueItems(catalogue);
  const results = Object.values(items).map((item, index) => (item.kind === 'decision'
    ? { id: item.id, choice: item.options.find(option => option.recommended).id }
    : index % 2 ? { id: item.id, result: 'fail', note: `Line one\nline \`two\` for ${item.id}` } : { id: item.id, result: 'pass' }));
  const issue = formatResultsIssue({ catalogue: catalogue.hash, results, items, date: '2026-11-04' });
  assert.match(issue.title, /^Manual QA results 2026-11-04 \(/);
  const parsed = parseResults(issue.body, catalogue);
  assert.equal(parsed.results.length, results.length);
  assert.equal(parsed.stale, false);
  const url = new URL(newIssueUrl(issue));
  assert.equal(url.searchParams.get('labels'), 'manual-qa-results');
  assert.equal(url.searchParams.get('body'), issue.body);
  const passes = results.map(entry => (entry.choice ? entry : { id: entry.id, result: 'pass' }));
  const compact = formatResultsIssue({ catalogue: catalogue.hash, results: passes, items, date: '2026-11-04', compact: true });
  assert.equal(parseResults(compact.body, catalogue).results.length, results.length);
  assert.ok(newIssueUrl(compact).length < 7500, 'A complete passing run fits in one link');
});
