#!/usr/bin/env node
// Red-main responder (.github/workflows/auto-revert.yml).
//
//   plan [--run <id>]   decide skip | rerun | fix | revert for main's state
//   verify              check HEAD is an exact revert of the main commits it names
//
// Pull requests merge on their pre-pr record, and main runs every build and
// test after the merge. When main goes red, the commits between the last green
// run and the first red one are the suspects. A flake-prone failure (tests,
// journeys, UI) is re-run once first. Otherwise main is fixed forward: the
// responder files the attribution on the `CI failing on main` issue for an
// agent to fix. If main is still red REVERT_AFTER_MINUTES after it turned red,
// or REVERT_AFTER_MERGES more commits have merged on top, the suspects are
// reverted instead, so breakages cannot stack. Suspects are narrowed by what
// the failed jobs can see: a docs-only commit cannot fail a macOS job.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

export const TRAILER = 'Auto-revert-of:';
export const MAX_REVERTED_COMMITS = 8;
export const REVERT_AFTER_MINUTES = 120;
export const REVERT_AFTER_MERGES = 3;
const MAX_RANGE = 25;
// Aggregates and reporters fail because another job did; they name no cause.
const AGGREGATE_JOBS = new Set(['CI Gate', 'Build & Test (macOS)', 'Report merge-batch or main CI failure']);
// Jobs whose failure reproduces on a rerun: re-running only delays the revert.
const DETERMINISTIC_JOBS = new Set(['Lint', 'Portable Swift (Linux)', 'Public API compatibility',
    'Paid Access Worker', 'Detect Release-Relevant Changes', 'Pre-PR evidence (blocking)']);
const DETERMINISTIC_STEP = /^(Build|Compile)\b/i;
// Paths no Apple, Linux or Windows CI job reads (ci.yml's `apple` filter).
const NON_APPLE = [/^android\//, /^Docs\//, /\.md$/, /^landing-page\//, /^workers\//,
    /^\.github\/workflows\/(android|deploy-landing-page)\.yml$/];

export function classifyFailure(jobs) {
    const failed = jobs.filter(job => job.conclusion === 'failure' && !AGGREGATE_JOBS.has(job.name));
    const deterministic = failed.some(job => DETERMINISTIC_JOBS.has(job.name)
        || (job.steps ?? []).some(step => step.conclusion === 'failure' && DETERMINISTIC_STEP.test(step.name)));
    return { failed: failed.map(job => job.name), deterministic };
}

export function canAffect(files, failedJobs) {
    return failedJobs.some(job => job === 'Paid Access Worker'
        ? files.some(file => file.startsWith('workers/'))
        : files.some(file => !NON_APPLE.some(pattern => pattern.test(file))));
}

export function revertedShas(message) {
    return [...message.matchAll(new RegExp(`^${TRAILER}\\s*(.+)$`, 'gm'))]
        .flatMap(([, list]) => list.trim().split(/\s+/)).filter(sha => /^[0-9a-f]{40}$/.test(sha));
}

// commits: newest first, {sha, message, files}. Returns the shas to revert.
export function selectCulprits(commits, failedJobs, alreadyReverted = new Set()) {
    const reverted = new Set(alreadyReverted);
    for (const commit of commits) for (const sha of revertedShas(commit.message)) reverted.add(sha);
    const suspects = commits.filter(commit => revertedShas(commit.message).length === 0 && !reverted.has(commit.sha));
    const narrowed = suspects.filter(commit => canAffect(commit.files, failedJobs));
    return (narrowed.length ? narrowed : suspects).map(commit => commit.sha);
}

// runs: completed main CI runs. Returns the newest decided run, the newest
// green run before it and the first red run after that green one.
export function redEpisode(runs) {
    const decided = runs.filter(r => r.status === 'completed' && ['success', 'failure'].includes(r.conclusion))
        .sort((a, b) => Date.parse(a.created_at) - Date.parse(b.created_at));
    const latest = decided.at(-1);
    if (!latest || latest.conclusion === 'success') return { latest, red: false };
    const greenIndex = decided.findLastIndex(r => r.conclusion === 'success');
    return { latest, red: true, green: decided[greenIndex], firstRed: decided[greenIndex + 1] };
}

export function shouldRevert(redSinceMs, nowMs, mergedSince) {
    return nowMs - redSinceMs >= REVERT_AFTER_MINUTES * 60_000 || mergedSince >= REVERT_AFTER_MERGES;
}

export function prNumber(subject) {
    return subject.match(/\(#(\d+)\)\s*$/)?.[1] ?? null;
}

const git = (...args) => execFileSync('git', args, { encoding: 'utf8', maxBuffer: 64 << 20 }).trim();
const gh = (...args) => execFileSync('gh', args, { encoding: 'utf8', maxBuffer: 64 << 20 }).trim();
const api = path => JSON.parse(gh('api', path));
const isAncestor = (a, b) => { try { git('merge-base', '--is-ancestor', a, b); return true; } catch { return false; } };

function output(values) {
    const lines = Object.entries(values).map(([key, value]) => `${key}=${value}`).join('\n') + '\n';
    if (process.env.GITHUB_OUTPUT) writeFileSync(process.env.GITHUB_OUTPUT, lines, { flag: 'a' });
    process.stdout.write(lines);
}

function plan(repo, runId) {
    const skip = reason => { output({ action: 'skip', reason }); console.log(`::notice::${reason}`); };
    const runs = [];
    for (let page = 1; page <= 3; page++) {
        const batch = api(`repos/${repo}/actions/workflows/ci.yml/runs?branch=main&status=completed&per_page=100&page=${page}`).workflow_runs;
        runs.push(...batch.filter(r => ['push', 'workflow_dispatch'].includes(r.event) && r.head_repository?.full_name === repo));
        if (batch.length < 100) break;
    }
    const { latest, red, green, firstRed } = redEpisode(runs);
    if (!red) return skip('Main CI is green.');
    if (runId && String(latest.id) !== String(runId)) return skip(`Run ${runId} is not main's newest decided run.`);
    const jobsOf = run => api(`repos/${repo}/actions/runs/${run.id}/attempts/${run.run_attempt}/jobs?per_page=100`).jobs;
    const latestFailure = classifyFailure(jobsOf(latest));
    if (runId && latest.run_attempt === 1 && latestFailure.failed.length && !latestFailure.deterministic) {
        output({ action: 'rerun', run: latest.id, failed: latestFailure.failed.join(', ') });
        return;
    }
    if (!green || !firstRed) return skip('No earlier green main run to bisect from; a human must fix main.');
    // Blame the commits that turned main red. If they are all reverted and main
    // is still red, the newer failure came from commits merged since.
    const attribute = (from, run) => {
        const { failed } = classifyFailure(jobsOf(run));
        const range = git('rev-list', '--first-parent', `${from}..${run.head_sha}`).split('\n').filter(Boolean);
        if (!failed.length || range.length > MAX_RANGE) return { failed, culprits: [], range };
        const commits = range.map(sha => ({
            sha, message: git('log', '-1', '--format=%B', sha),
            files: git('diff-tree', '--no-commit-id', '--name-only', '-r', '--root', sha).split('\n').filter(Boolean),
        }));
        const since = git('log', '--first-parent', '--format=%B', `${run.head_sha}..origin/main`);
        return { failed, range, culprits: selectCulprits(commits, failed, new Set(revertedShas(since))) };
    };
    let { failed, culprits, range } = attribute(green.head_sha, firstRed);
    let blamed = firstRed;
    if (!culprits.length && latest.id !== firstRed.id) {
        ({ failed, culprits, range } = attribute(firstRed.head_sha, latest));
        blamed = latest;
    }
    const head = blamed.head_sha;
    if (!failed.length) return skip('No job failed on its own (only aggregates); nothing to attribute.');
    if (range.length > MAX_RANGE) return skip(`${range.length} commits since the last green run; too many to revert safely.`);
    if (!culprits.length) return skip('Every suspect is already reverted; the failure is not from a merged change.');
    if (culprits.length > MAX_REVERTED_COMMITS) return skip(`${culprits.length} suspects; too many to revert safely.`);
    const prs = culprits.map(sha => prNumber(git('log', '-1', '--format=%s', sha))).filter(Boolean);
    const mergedSince = Number(git('rev-list', '--first-parent', '--count', `${head}..origin/main`));
    const redSince = blamed.updated_at;
    const action = shouldRevert(Date.parse(redSince), Date.now(), mergedSince) ? 'revert' : 'fix';
    output({ action, red_sha: head, red_run_id: blamed.id, red_run: blamed.html_url, red_since: redSince, merged_since: mergedSince,
        base: green.head_sha, shas: culprits.join(' '), prs: prs.join(' '), failed: failed.join(', ') });
}

function verify() {
    const head = git('rev-parse', 'HEAD');
    const parents = git('rev-list', '--parents', '-n', '1', head).split(' ').slice(1);
    if (parents.length !== 1) throw Error('An auto-revert is exactly one commit on main.');
    const [parent] = parents;
    if (!isAncestor(parent, 'origin/main')) throw Error('The revert must start from a main commit.');
    const shas = revertedShas(git('log', '-1', '--format=%B', head));
    if (!shas.length) throw Error(`No ${TRAILER} trailer names the reverted commits.`);
    for (const sha of shas) {
        if (!isAncestor(sha, parent)) throw Error(`${sha} is not a commit on main.`);
    }
    const dir = mkdtempSync(join(tmpdir(), 'auto-revert-'));
    try {
        git('worktree', 'add', '--detach', dir, parent);
        execFileSync('git', ['-C', dir, 'revert', '--no-commit', ...shas], { stdio: 'inherit' });
        const expected = execFileSync('git', ['-C', dir, 'write-tree'], { encoding: 'utf8' }).trim();
        if (expected !== git('rev-parse', `${head}^{tree}`)) throw Error('HEAD is not an exact revert of the named commits.');
    } finally {
        try { git('worktree', 'remove', '--force', dir); } catch { rmSync(dir, { recursive: true, force: true }); }
    }
    console.log(`Verified: ${head.slice(0, 12)} exactly reverts ${shas.map(s => s.slice(0, 12)).join(', ')} on ${parent.slice(0, 12)}.`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
    const [command, ...args] = process.argv.slice(2);
    const option = name => args[args.indexOf(`--${name}`) + 1];
    const repo = process.env.GITHUB_REPOSITORY ?? 'crmitchelmore/justspeaktoit';
    if (command === 'plan') plan(repo, args.includes('--run') ? option('run') : null);
    else if (command === 'verify') verify();
    else { console.error('usage: auto-revert.mjs plan [--run <id>] | verify'); process.exit(2); }
}
