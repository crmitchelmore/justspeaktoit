import test from 'node:test';
import assert from 'node:assert/strict';
import {desktopDownloads, desktopWorkflows, latestDesktopRun, liveArtifact, reusableDesktopRun, desktopQualificationComplete, validateDesktopReceipt, verifyDesktopDownload} from '../desktop-release-lib.mjs';
const manifest = {source: 'a'.repeat(40), tag: 'stable-candidate-2', build: '202610281200'};
const run = {id: 3, head_sha: manifest.source, head_branch: manifest.tag,
    event: 'workflow_dispatch', status: 'completed', conclusion: 'success', created_at: '2026-10-28T12:00:01Z'};
const repo = 'crmitchelmore/justspeaktoit';
const receipt = () => ({...manifest, status: 'verified', runs: Object.fromEntries(desktopWorkflows.map(w => [w, {...run, repository: repo, path: `.github/workflows/${w}`}]))});
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

test('only completed main push evidence from the exact source/workflow/repository can be reused', () => {
    const workflow = desktopWorkflows[0];
    const main = {...run, event:'push', head_branch:'main', head_repository:{full_name:repo}, path:`.github/workflows/${workflow}`};
    assert.equal(reusableDesktopRun([main], manifest, workflow, repo), main);
    const proof = receipt(); proof.runs[workflow] = {...main, repository:repo};
    assert.equal(validateDesktopReceipt(manifest, proof), proof);
    for (const patch of [{event:'pull_request'}, {head_sha:'b'.repeat(40)}, {head_branch:'branch'},
        {head_repository:{full_name:'fork/repo'}}, {path:'.github/workflows/other.yml'},
        {conclusion:'failure'}, {status:'in_progress'}]) {
        assert.equal(reusableDesktopRun([{...main,...patch}],manifest,workflow,repo), undefined);
    }
    assert.equal(reusableDesktopRun([main,{...main,id:4,conclusion:'failure'}],manifest,workflow,repo),undefined);
});
test('missing or mismatched desktop evidence stays eligible for Alpha recovery', () => {
    const required = {...manifest, desktopQualification:1};
    assert.equal(desktopQualificationComplete(required, undefined), false);
    assert.equal(desktopQualificationComplete(required, {...receipt(),source:'b'.repeat(40)}), false);
    assert.equal(desktopQualificationComplete(required, receipt()), true);
    assert.equal(desktopQualificationComplete(manifest, undefined), true);
});

test('published downloads come only from qualifying workflows and match their own evidence', () => {
    const digest = 'c'.repeat(64);
    for (const spec of desktopDownloads) assert.ok(desktopWorkflows.includes(spec.workflow));
    assert.deepEqual(desktopDownloads.map(spec => spec.architecture), ['x64', 'arm64', 'x86_64']);
    const [x64, arm64, flatpak] = desktopDownloads;
    const bundle = architecture => ({application: {sourceCommit: manifest.source}, architecture,
        zip: {name: 'justspeaktoit-windows-developer.zip', sha256: digest}});
    assert.equal(verifyDesktopDownload(x64, manifest, bundle('x64'), digest), 'justspeaktoit-windows-developer.zip');
    assert.throws(() => verifyDesktopDownload(x64, manifest, bundle('arm64'), digest));
    assert.throws(() => verifyDesktopDownload(arm64, manifest, bundle('arm64'), 'd'.repeat(64)));
    assert.throws(() => verifyDesktopDownload(arm64, {...manifest, source: 'b'.repeat(40)}, bundle('arm64'), digest));
    assert.throws(() => verifyDesktopDownload(x64, manifest, {...bundle('x64'), zip: {name: '../x.zip', sha256: digest}}, digest));
    const provenance = {sourceSHA: manifest.source, builtRevision: manifest.source, bundleSHA256: digest};
    assert.equal(verifyDesktopDownload(flatpak, manifest, provenance, digest), 'JustSpeakToIt-x86_64.flatpak');
    assert.throws(() => verifyDesktopDownload(flatpak, manifest, {...provenance, builtRevision: 'b'.repeat(40)}, digest));
    assert.throws(() => verifyDesktopDownload(flatpak, manifest, provenance, 'd'.repeat(64)));
});
test('expired or ambiguous artifacts cannot supply a download', () => {
    assert.equal(liveArtifact([{name: 'a', expired: false}], 'a').name, 'a');
    assert.equal(liveArtifact([{name: 'a', expired: true}], 'a'), undefined);
    assert.equal(liveArtifact([{name: 'a', expired: false}, {name: 'a', expired: false}], 'a'), undefined);
    assert.equal(liveArtifact([], 'a'), undefined);
});
