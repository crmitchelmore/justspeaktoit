import test from 'node:test';
import assert from 'node:assert/strict';
import {desktopWorkflows, latestDesktopRun, validateDesktopReceipt} from '../desktop-release-lib.mjs';
const manifest = {source: 'a'.repeat(40), tag: 'stable-candidate-2', build: '202610281200'};
const run = {id: 3, head_sha: manifest.source, head_branch: manifest.tag,
    event: 'workflow_dispatch', status: 'completed', conclusion: 'success', created_at: '2026-10-28T12:00:01Z'};
const receipt = () => ({...manifest, status: 'verified', runs: Object.fromEntries(desktopWorkflows.map(w => [w, {...run}]))});
test('requires all native and packaged desktop workflows at the frozen source', () => {
    assert.equal(validateDesktopReceipt(manifest, receipt()).status, 'verified');
    for (const workflow of desktopWorkflows) {
        for (const patch of [{conclusion: 'failure'}, {conclusion: 'cancelled'}, {status: 'in_progress'},
            {head_sha: 'b'.repeat(40)}, {head_branch: 'main'}, {event: 'pull_request'}, {id: undefined}]) {
            const value = receipt(); Object.assign(value.runs[workflow], patch);
            assert.throws(() => validateDesktopReceipt(manifest, value));
        }
        const missing = receipt(); delete missing.runs[workflow];
        assert.throws(() => validateDesktopReceipt(manifest, missing));
    }
    assert.throws(() => validateDesktopReceipt(manifest, {...receipt(), build: 'old'}));
});
test('polling rejects old runs, other tags and sources; chooses the newest dispatched run', () => {
    const start = '2026-10-28T12:00:00Z';
    assert.equal(latestDesktopRun([{...run, id: 4}, run], manifest, start).id, 4);
    for (const patch of [{created_at: '2026-10-28T11:59:59Z'}, {head_branch: 'alpha-build-2'},
        {head_sha: 'b'.repeat(40)}, {event: 'push'}]) {
        assert.equal(latestDesktopRun([{...run, ...patch}], manifest, start), undefined);
    }
});
