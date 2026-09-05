import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { assessCIGates as assessOracle } from '../verify-ci-gates.mjs';

const workflow = readFileSync(new URL('../../.github/workflows/ci.yml', import.meta.url), 'utf8');
const aggregate = workflow.slice(workflow.indexOf('\n  required-macos:'));
const predicate = aggregate.match(/name: Reject unsuccessful CI gates\n        if: >-\n([\s\S]*?)\n        env:/)?.[1];
assert.ok(predicate, 'must test the actual workflow rejection predicate');
// GitHub property names permit hyphens; adapt those paths for local evaluation.
// The predicate uses only boolean/string comparisons, with no Actions-specific
// coercions. This tests the shipped predicate against the diagnostic oracle.
const evaluatePredicate = new Function('needs', 'github', 'always', `return (${
  predicate.replace(/\bneeds((?:\.[a-zA-Z0-9_-]+)+)/g, (_, path) =>
    'needs' + path.split('.').slice(1).map(key => `?.[${JSON.stringify(key)}]`).join(''))
});`);

function assessCIGates(needs, event) {
  const errors = assessOracle(needs, event);
  assert.equal(evaluatePredicate(needs, { event_name: event }, () => true), errors.length > 0,
    'workflow predicate must agree with fixture expectations');
  return errors;
}

test('aggregate never checks out or executes repository helper code', () => {
  assert.doesNotMatch(aggregate, /uses:|run:.*scripts\//);
  assert.match(aggregate, /permissions: \{\}/);
  assert.match(aggregate, /exit 1/);
});

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
