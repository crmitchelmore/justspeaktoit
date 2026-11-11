import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { glob, routeMatches } from '../ci/routing.mjs';

// The Python truth table (test_ci_routing.py) records what the workflow filters select per path.
const table = JSON.parse(readFileSync(new URL('./fixtures/ci-routing-truth-table.json', import.meta.url), 'utf8'));

test('the Node evaluator routes every truth-table path exactly as the workflows do', () => {
    for (const { path, workflows } of table) {
        for (const [route, selected] of Object.entries(workflows)) {
            assert.equal(routeMatches(route, path), selected, `${route}: ${path}`);
        }
    }
});

test('globs follow GitHub path-filter rules', () => {
    assert.equal(glob('Sources/A/B.swift', 'Sources/**'), true);
    assert.equal(glob('scripts/collect-macos-a/b.py', 'scripts/collect-macos-*.py'), false);
    assert.equal(glob('README.md', '**/*.md'), true);
    assert.equal(glob('a+b.md', 'a+b.md'), true);
    assert.equal(glob('aab.md', 'a+b.md'), false);
});
