#!/usr/bin/env node
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout } from 'node:timers/promises';
import { runReleaseCommand as run } from './release-command.mjs';
import { validateManifest } from './release-train-lib.mjs';
import { desktopDownloads, desktopWorkflows, equivalencePathspecs, equivalentDesktopRun, latestDesktopRun, liveArtifact,
    projectDesktopRun, reusableDesktopRun, validateDesktopReceipt, workflowPushPaths } from './desktop-release-lib.mjs';
import { publishDesktopDownloads } from './publish-desktop-downloads.mjs';

const repo = process.env.GITHUB_REPOSITORY ?? 'crmitchelmore/justspeaktoit';
const tag = process.argv[2];
if (!/^(alpha-build|stable-candidate)-[1-9][0-9]*$/.test(tag ?? '')) throw Error('Immutable manifest tag required');
const manifest = validateManifest(JSON.parse(run('git', ['for-each-ref', '--format=%(contents)', `refs/tags/${tag}`])));
if (manifest.tag !== tag || run('git', ['rev-parse', `${tag}^{commit}`]) !== manifest.source) throw Error('Manifest source mismatch');
const gh = (...args) => run('gh', args);
const succeeds = (command, args) => { try { run(command, args); return true; } catch { return false; } };
const startedAt = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
// Separate runs keep existing native jobs, artifact names and signing environments
// intact. Tag refs make every checkout and nested runtime use the frozen source.
const pending = new Set(desktopWorkflows);
const runs = {};
for (const workflow of desktopWorkflows) {
    const pages = JSON.parse(gh('api', '--paginate', '--slurp',
        `repos/${repo}/actions/workflows/${workflow}/runs?event=push&branch=main&head_sha=${manifest.source}&per_page=100`));
    let existing = reusableDesktopRun(pages.flatMap(page => page.workflow_runs), manifest, workflow, repo);
    // Path filters skip most main pushes, so the exact source rarely has a run. Reuse the newest
    // run whose tree matches the source on every path the workflow builds from.
    const pushPaths = existing ? undefined : workflowPushPaths(run('git', ['show', `${manifest.source}:.github/workflows/${workflow}`]));
    if (!existing && pushPaths) {
        const pathspecs = equivalencePathspecs(workflow, pushPaths);
        const recent = ['event=push&branch=main', 'event=workflow_dispatch'].flatMap(filter => JSON.parse(gh('api',
            `repos/${repo}/actions/workflows/${workflow}/runs?${filter}&status=completed&per_page=50`)).workflow_runs);
        existing = equivalentDesktopRun(recent, manifest, workflow, repo, sha =>
            succeeds('git', ['merge-base', '--is-ancestor', sha, manifest.source]) &&
            succeeds('git', ['diff', '--quiet', sha, manifest.source, '--', ...pathspecs]));
    }
    // Published downloads come from the qualifying run, so its bundle must not have expired.
    const download = desktopDownloads.find(spec => spec.workflow === workflow);
    if (existing && download && !liveArtifact(JSON.parse(gh('api',
        `repos/${repo}/actions/runs/${existing.id}/artifacts?per_page=100`)).artifacts, download.artifact)) existing = undefined;
    if (existing) {
        runs[workflow] = projectDesktopRun(existing, manifest.source);
        pending.delete(workflow);
        const basis = existing.head_sha === manifest.source ? '' : ` (equivalent tree at ${existing.head_sha.slice(0, 12)})`;
        console.log(`Reused ${workflow}: ${existing.html_url}${basis}`);
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
        runs[workflow] = projectDesktopRun(observed);
        pending.delete(workflow);
        console.log(`Verified ${workflow}: ${observed.html_url}`);
    }
    if (pending.size) await setTimeout(30_000);
}
const publication = publishDesktopDownloads(manifest, runs);
const receipt = validateDesktopReceipt(manifest, {status: 'verified', source: manifest.source,
    tag, build: manifest.build, checkedAt: new Date().toISOString(), ...publication});
const directory = mkdtempSync(join(tmpdir(), 'desktop-release-'));
const path = join(directory, 'desktop-qualification.json');
writeFileSync(path, JSON.stringify(receipt, null, 2) + '\n');
gh('release', 'upload', tag, path, '--repo', repo, '--clobber');
