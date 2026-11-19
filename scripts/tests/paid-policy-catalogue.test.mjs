import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import test from 'node:test';

const root = fileURLToPath(new URL('../../', import.meta.url));
const read = name => readFileSync(path.join(root, name), 'utf8');

// The paid Worker names its Best routes by catalogue id so the apps can show
// them. A catalogue rename or removal must fail here, not as an unknown model
// in the paid-access UI.
test('every paid Best route names a model in the SpeakCore catalogue', () => {
  const policy = read('workers/paid-access/src/policy.ts');
  const ids = [...policy.matchAll(/catalogueModelId:\s*'([^']+)'/g)].map(match => match[1]);
  assert.deepEqual(new Set(ids).size, 3, 'one route per paid operation');
  const catalogue = read('Sources/SpeakCore/ModelCatalog.swift');
  for (const id of ids) {
    assert.ok(catalogue.includes(`"${id}"`), `${id} is missing from ModelCatalog.swift`);
  }
});
