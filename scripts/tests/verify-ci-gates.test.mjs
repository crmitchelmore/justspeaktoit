import assert from 'node:assert/strict';
import { test } from 'node:test';
import { assessCIGates } from '../verify-ci-gates.mjs';

function passing() {
  return Object.fromEntries([
    'build-macos', 'build-ios', 'build-ios-keyboard-direct-capture', 'lint',
    'release-paths', 'release-validation', 'core-journey-e2e',
    'core-journey-fixture-ui', 'api-compatibility',
  ].map(id => [id, { result: 'success', outputs: { package: 'true', 'core-journey': 'true' } }]));
}

test('accepts all successful pull-request gates', () => {
  assert.deepEqual(assessCIGates(passing(), 'pull_request'), []);
});

for (const id of Object.keys(passing())) {
  for (const status of ['failure', 'cancelled', 'skipped', undefined]) {
    test(`blocks ${id} when ${status ?? 'missing'}`, () => {
      const needs = passing();
      needs[id].result = status;
      assert.ok(assessCIGates(needs, 'pull_request').length > 0);
    });
  }
}

test('permits only path-excluded PR gates to skip', () => {
  const needs = passing();
  needs['release-paths'].outputs = { package: 'false', 'core-journey': 'false' };
  for (const id of ['release-validation', 'core-journey-e2e', 'core-journey-fixture-ui']) {
    needs[id].result = 'skipped';
  }
  assert.deepEqual(assessCIGates(needs, 'pull_request'), []);
  assert.ok(assessCIGates(needs, 'push').length > 0, 'main cannot skip gates');
  needs['core-journey-e2e'].result = 'failure';
  assert.ok(assessCIGates(needs, 'pull_request').length > 0);
});

test('blocks missing path detection outputs', () => {
  const needs = passing();
  needs['release-paths'].outputs = {};
  assert.ok(assessCIGates(needs, 'pull_request').length > 0);
});

test('permits API compatibility skip only on main push', () => {
  const needs = passing();
  needs['api-compatibility'].result = 'skipped';
  assert.deepEqual(assessCIGates(needs, 'push'), []);
  assert.ok(assessCIGates(needs, 'pull_request').length > 0);
});
