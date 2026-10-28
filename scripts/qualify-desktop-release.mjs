#!/usr/bin/env node
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout } from 'node:timers/promises';
import { runReleaseCommand as run } from './release-command.mjs';
import { validateManifest } from './release-train-lib.mjs';
import { desktopWorkflows, latestDesktopRun, reusableDesktopRun, validateDesktopReceipt } from './desktop-release-lib.mjs';

const repo = process.env.GITHUB_REPOSITORY ?? 'crmitchelmore/justspeaktoit';
const tag = process.argv[2];
if (!/^(alpha-build|stable-candidate)-[1-9][0-9]*$/.test(tag ?? '')) throw Error('Immutable manifest tag required');
const manifest = validateManifest(JSON.parse(run('git', ['for-each-ref', '--format=%(contents)', `refs/tags/${tag}`])));
if (manifest.tag !== tag || run('git', ['rev-parse', `${tag}^{commit}`]) !== manifest.source) throw Error('Manifest source mismatch');
const gh = (...args) => run('gh', args);
const startedAt = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
// Separate runs keep existing native jobs, artifact names and signing environments
// intact. Tag refs make every checkout and nested runtime use the frozen source.
const pending = new Set(desktopWorkflows);
const runs = {};
const project = observed => ({...Object.fromEntries(
    ['id', 'head_sha', 'head_branch', 'event', 'status', 'conclusion', 'html_url', 'path'].map(key => [key, observed[key]])),
    repository: observed.head_repository?.full_name});
for (const workflow of desktopWorkflows) {
    const pages = JSON.parse(gh('api', '--paginate', '--slurp',
        `repos/${repo}/actions/workflows/${workflow}/runs?event=push&branch=main&head_sha=${manifest.source}&per_page=100`));
    const existing = reusableDesktopRun(pages.flatMap(page => page.workflow_runs), manifest, workflow, repo);
    if (existing) {
        runs[workflow] = project(existing);
        pending.delete(workflow);
        console.log(`Reused ${workflow}: ${existing.html_url}`);
    } else gh('workflow', 'run', workflow, '--repo', repo, '--ref', tag);
}
const deadline = Date.now() + 4 * 60 * 60 * 1000;
while (pending.size) {
    if (Date.now() >= deadline) throw Error(`Timed out waiting for desktop qualification: ${[...pending].join(', ')}`);
    for (const workflow of pending) {
        const pages = JSON.parse(gh('api', '--paginate', '--slurp',
            `repos/${repo}/actions/workflows/${workflow}/runs?event=workflow_dispatch&head_sha=${manifest.source}&per_page=100`));
        const observed = latestDesktopRun(pages.flatMap(page => page.workflow_runs), manifest, startedAt);
        if (!observed || observed.status !== 'completed') continue;
        if (observed.conclusion !== 'success') throw Error(`Desktop qualification failed: ${observed.html_url}`);
        runs[workflow] = project(observed);
        pending.delete(workflow);
        console.log(`Verified ${workflow}: ${observed.html_url}`);
    }
    if (pending.size) await setTimeout(30_000);
}
const receipt = validateDesktopReceipt(manifest, {status: 'verified', source: manifest.source,
    tag, build: manifest.build, checkedAt: new Date().toISOString(), runs});
const directory = mkdtempSync(join(tmpdir(), 'desktop-release-'));
const path = join(directory, 'desktop-qualification.json');
writeFileSync(path, JSON.stringify(receipt, null, 2) + '\n');
gh('release', 'upload', tag, path, '--repo', repo, '--clobber');
