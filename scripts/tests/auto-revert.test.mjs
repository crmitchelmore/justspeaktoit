import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { canAffect, classifyFailure, prNumber, redEpisode, revertedShas, selectCulprits, shouldRevert, TRAILER } from '../ci/auto-revert.mjs';
import { routeMatches } from '../ci/routing.mjs';

const script = fileURLToPath(new URL('../ci/auto-revert.mjs', import.meta.url));
const workflow = readFileSync(new URL('../../.github/workflows/auto-revert.yml', import.meta.url), 'utf8');
const sha = n => String(n).repeat(40).slice(0, 40);

test('test and journey failures are re-run once; lint, build and API failures are not', () => {
    const job = (name, steps = []) => ({ name, conclusion: 'failure', steps });
    const gate = { name: 'CI Gate', conclusion: 'failure' };
    assert.deepEqual(classifyFailure([job('Core Journey E2E', [{ name: 'Run journeys', conclusion: 'failure' }]), gate]),
        { failed: ['Core Journey E2E'], deterministic: false });
    assert.equal(classifyFailure([job('Lint')]).deterministic, true);
    assert.equal(classifyFailure([job('Public API compatibility')]).deterministic, true);
    assert.equal(classifyFailure([job('Build & Test (macOS Debug)', [{ name: 'Build', conclusion: 'failure' }])]).deterministic, true);
    assert.equal(classifyFailure([job('Build & Test (macOS Debug)', [{ name: 'Test (Debug)', conclusion: 'failure' }])]).deterministic, false);
    assert.deepEqual(classifyFailure([gate, { name: 'Build & Test (macOS)', conclusion: 'failure' }]).failed, [],
        'aggregates name no cause');
});

const apple = file => routeMatches('apple', file);

test('a commit can only be blamed by a job that reads its files', () => {
    assert.equal(canAffect(['Docs/x.md', 'android/a.kt'], ['Build iOS'], apple), false);
    assert.equal(canAffect(['README.md', 'landing-page/a.html', '.github/workflows/android.yml'], ['Lint'], apple), false);
    assert.equal(canAffect(['Sources/SpeakCore/A.swift'], ['Build iOS'], apple), true);
    assert.equal(canAffect(['Sources/SpeakCore/A.swift'], ['Paid Access Worker'], apple), false);
    assert.equal(canAffect(['workers/paid-access/src/a.ts'], ['Paid Access Worker'], apple), true);
});

test('verify runs from a lone copy of the script, so it imports no sibling module statically', () => {
    const source = readFileSync(new URL('../ci/auto-revert.mjs', import.meta.url), 'utf8');
    assert.doesNotMatch(source, /^import .* from '\.\.?\//m);
});

test('suspects narrow to relevant commits, fall back to all, and skip earlier reverts', () => {
    const commits = [
        { sha: sha(1), message: 'docs: x (#3)', files: ['Docs/a.md'] },
        { sha: sha(2), message: 'feat: y (#2)', files: ['Sources/A.swift'] },
        { sha: sha(3), message: `revert: auto-revert #1\n\n${TRAILER} ${sha(4)}`, files: ['Sources/B.swift'] },
        { sha: sha(4), message: 'feat: z (#1)', files: ['Sources/B.swift'] },
    ];
    assert.deepEqual(selectCulprits(commits, ['Build iOS'], apple), [sha(2)]);
    assert.deepEqual(selectCulprits(commits.slice(0, 1), ['Build iOS'], apple), [sha(1)], 'nothing relevant: blame every suspect');
    assert.deepEqual(selectCulprits(commits.slice(1, 2), ['Lint'], apple, new Set([sha(2)])), [], 'already reverted later on main');
    assert.deepEqual(revertedShas(`x\n\n${TRAILER} ${sha(5)} ${sha(6)}\n`), [sha(5), sha(6)]);
    assert.equal(prNumber('feat: y (#1234)'), '1234');
    assert.equal(prNumber('feat: y'), null);
});

test('main is red from the first failure after the last green run', () => {
    const run = (id, conclusion, minute) => ({ id, conclusion, status: 'completed', created_at: `2026-11-10T10:${minute}:00Z` });
    assert.equal(redEpisode([run(1, 'failure', '00'), run(2, 'success', '10')]).red, false);
    const episode = redEpisode([run(1, 'success', '00'), run(2, 'failure', '10'), run(3, 'cancelled', '15'),
        run(4, 'failure', '20')]);
    assert.equal(episode.red, true);
    assert.equal(episode.green.id, 1);
    assert.equal(episode.firstRed.id, 2);
    assert.equal(episode.latest.id, 4);
    assert.equal(redEpisode([run(1, 'failure', '00')]).green, undefined, 'no green run to bisect from');
});

test('fix forward first; revert after two hours or three more merges', () => {
    const t0 = Date.parse('2026-11-10T10:00:00Z');
    assert.equal(shouldRevert(t0, t0 + 119 * 60_000, 2), false);
    assert.equal(shouldRevert(t0, t0 + 120 * 60_000, 0), true);
    assert.equal(shouldRevert(t0, t0 + 5 * 60_000, 3), true);
});

function repo() {
    const dir = mkdtempSync(join(tmpdir(), 'auto-revert-test-'));
    const run = (...args) => execFileSync('git', args, { cwd: dir, encoding: 'utf8' }).trim();
    run('init', '--quiet', '-b', 'main');
    run('config', 'user.name', 't'); run('config', 'user.email', 't@invalid');
    const commit = (file, text) => { writeFileSync(join(dir, file), text); run('add', file); run('commit', '--quiet', '-m', `change ${file}`); return run('rev-parse', 'HEAD'); };
    commit('a', '1');
    const bad = commit('b', 'bad');
    const other = commit('c', 'fine');
    run('update-ref', 'refs/remotes/origin/main', 'HEAD');
    return { dir, run, bad, other, commit };
}
const verify = dir => spawnSync('node', [script, 'verify'], { cwd: dir, encoding: 'utf8' });

test('the gate admits an exact revert of main commits', () => {
    const { dir, run, bad } = repo();
    run('revert', '--no-commit', bad);
    run('commit', '--quiet', '-m', `revert: auto-revert\n\n${TRAILER} ${bad}`);
    const result = verify(dir);
    assert.equal(result.status, 0, result.stderr);
});

test('the gate rejects any extra change, a missing trailer or a non-main commit', () => {
    let { dir, run, bad } = repo();
    run('revert', '--no-commit', bad);
    writeFileSync(join(dir, 'smuggled'), 'x'); run('add', 'smuggled');
    run('commit', '--quiet', '-m', `revert: auto-revert\n\n${TRAILER} ${bad}`);
    assert.notEqual(verify(dir).status, 0, 'extra file');

    ({ dir, run, bad } = repo());
    run('revert', '--no-commit', bad);
    run('commit', '--quiet', '-m', 'revert: no trailer');
    assert.notEqual(verify(dir).status, 0, 'no trailer');

    const fresh = repo();
    fresh.run('checkout', '--quiet', '-b', 'side');
    const side = fresh.commit('d', 'side');
    fresh.run('revert', '--no-commit', side);
    fresh.run('commit', '--quiet', '-m', `revert\n\n${TRAILER} ${side}`);
    assert.notEqual(verify(fresh.dir).status, 0, 'reverted commit is not on main');
});

test('the workflow keeps its trust boundary', () => {
    assert.match(workflow, /^  gate:\n    name: CI Gate\n    if: github\.event_name == 'workflow_dispatch' && startsWith\(github\.ref, 'refs\/heads\/auto-revert\/'\)$/m);
    assert.match(workflow, /git show origin\/main:scripts\/ci\/auto-revert\.mjs/, 'the verifier comes from main');
    const gate = workflow.split('\n  gate:\n')[1];
    assert.doesNotMatch(gate, /permissions:\s*\n\s+contents: write|secrets\./);
    assert.match(workflow, /github\.event\.workflow_run\.head_repository\.full_name == github\.repository/);
    assert.match(workflow, /vars\.JSTI_AUTO_REVERT != 'off'/);
    assert.match(workflow, /cron: '\*\/15 \* \* \* \*'/, 'the time limit applies even when no run completes');
    assert.match(workflow, /if: steps\.plan\.outputs\.action == 'fix'/);
    assert.match(workflow, /gh workflow run ci\.yml --ref main/, 'a token merge starts no push run');
    assert.doesNotMatch(workflow, /--admin|secrets\./, 'no admin override or personal token');
});
