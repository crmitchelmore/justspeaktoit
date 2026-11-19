import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { test } from 'node:test';

const dir = new URL('../../.github/workflows/', import.meta.url);
const workflows = Object.fromEntries(readdirSync(dir).filter(name => name.endsWith('.yml'))
  .map(name => [name, readFileSync(new URL(name, dir), 'utf8')]));
const reviewed = readFileSync(new URL('../../.github/actionlint.yaml', import.meta.url), 'utf8')
  .match(/^ {4}- ([\w-]+)$/gm).map(line => line.trim().slice(2));
const generic = new Set(['self-hosted', 'macOS', 'Linux', 'X64', 'ARM64']);
const hosted = /^(ubuntu|macos|windows)-[\w.-]+$/;

test('every remote action is pinned to a full commit SHA with a version comment', () => {
  for (const [file, source] of Object.entries(workflows)) {
    for (const [line] of source.matchAll(/^\s*(?:- )?uses: (?!\.\/)[^\n]+$/gm)) {
      assert.match(line, /uses: [\w.-]+\/[\w./-]+@[0-9a-f]{40} # [vV]\d[\w.-]*$/, `${file}: ${line.trim()}`);
    }
  }
});

test('self-hosted label sets use only allowlisted labels and always include a reviewed one', () => {
  assert.deepEqual(reviewed, ['jsti-reviewed-local', 'omarchy-local', 'ios-device']);
  let seen = 0;
  for (const [file, source] of Object.entries(workflows)) {
    for (const [line] of source.matchAll(/^\s*runs-on: [^\n]+$/gm)) {
      for (const [, list] of line.matchAll(/\[([^\[\]]*)\]/g)) {
        const labels = list.split(',').map(label => label.trim().replace(/^["']|["']$/g, '')).filter(Boolean);
        if (labels.every(label => hosted.test(label))) continue;
        seen += 1;
        for (const label of labels) {
          assert.ok(generic.has(label) || reviewed.includes(label), `${file}: unreviewed runner label ${label}`);
        }
        assert.ok(labels.some(label => reviewed.includes(label)), `${file}: [${labels}] needs a reviewed label`);
      }
    }
  }
  assert.ok(seen > 0, 'expected the routed self-hosted label sets to be checked');
});
