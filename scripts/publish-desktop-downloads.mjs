#!/usr/bin/env node
import { createHash } from 'node:crypto';
import { copyFileSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { runReleaseCommand as run } from './release-command.mjs';
import { validateManifest } from './release-train-lib.mjs';
import { desktopDownloadFile, desktopDownloads, desktopWorkflows, liveArtifact, projectDesktopRun,
    validateDesktopReceipt, verifyDesktopDownload } from './desktop-release-lib.mjs';

const repo = process.env.GITHUB_REPOSITORY ?? 'crmitchelmore/justspeaktoit';
const json = path => JSON.parse(readFileSync(path, 'utf8'));

function receiptFor(manifest, runs) {
    return {status: 'verified', source: manifest.source, tag: manifest.tag, build: manifest.build, runs};
}

function currentDesktopRuns(manifest, runs, command) {
    validateDesktopReceipt(manifest, receiptFor(manifest, runs), repo);
    const current = {};
    for (const workflow of desktopWorkflows) {
        const stored = runs[workflow];
        const observed = JSON.parse(command('gh', ['api', `repos/${repo}/actions/runs/${stored.id}`]));
        if (observed.id !== stored.id || !Number.isSafeInteger(observed.run_attempt) || observed.run_attempt < 1 ||
            (stored.run_attempt !== undefined && stored.run_attempt !== observed.run_attempt)) {
            throw Error(`Desktop qualification run changed: ${workflow}`);
        }
        current[workflow] = projectDesktopRun(observed);
    }
    return validateDesktopReceipt(manifest, receiptFor(manifest, current), repo).runs;
}

// Copies each qualifying run's bundle onto the manifest release under a
// stable name, after checking its bytes against that run's own evidence.
export function publishDesktopDownloads(manifest, runs, command = run) {
    const gh = (...args) => command('gh', args);
    // Admit every current workflow before any download or release write. Old
    // receipts without attempt numbers are upgraded from fresh successful runs.
    const current = currentDesktopRuns(manifest, runs, command);
    const directory = mkdtempSync(join(tmpdir(), 'desktop-downloads-'));
    try {
        const downloads = {};
        for (const spec of desktopDownloads) {
            const runID = current[spec.workflow].id;
            const listed = JSON.parse(gh('api', `repos/${repo}/actions/runs/${runID}/artifacts?per_page=100`));
            if (!liveArtifact(listed.artifacts, spec.artifact)) throw Error(`${spec.workflow} run ${runID} has no live ${spec.artifact}`);
            const target = join(directory, spec.artifact);
            gh('run', 'download', String(runID), '--repo', repo, '--name', spec.artifact, '--dir', target);
            const evidence = json(join(target, spec.kind === 'windows' ? 'bundle-evidence.json' : 'build-provenance.json'));
            const fileName = desktopDownloadFile(spec, manifest, evidence);
            const bytes = readFileSync(join(target, fileName));
            const sha256 = createHash('sha256').update(bytes).digest('hex');
            verifyDesktopDownload(spec, manifest, evidence, sha256);
            const published = join(directory, spec.asset);
            copyFileSync(join(target, fileName), published);
            downloads[spec.asset] = {workflow: spec.workflow, run: runID, architecture: spec.architecture,
                bytes: bytes.length, sha256};
        }
        // Stage and validate all three bundles before publishing any of them.
        for (const spec of desktopDownloads) {
            gh('release', 'upload', manifest.tag, join(directory, spec.asset), '--repo', repo, '--clobber');
            console.log(`Published ${spec.asset} from run ${downloads[spec.asset].run}`);
        }
        return {runs: current, downloads};
    } finally {
        rmSync(directory, {recursive: true, force: true});
    }
}

// Backfill: node scripts/publish-desktop-downloads.mjs <manifest-tag>
export function backfillDesktopDownloads(tag, command = run) {
    const gh = (...args) => command('gh', args);
    if (!/^(alpha-build|stable-candidate)-[1-9][0-9]*$/.test(tag ?? '')) throw Error('Immutable manifest tag required');
    const manifest = validateManifest(JSON.parse(command('git', ['for-each-ref', '--format=%(contents)', `refs/tags/${tag}`])));
    if (manifest.tag !== tag || command('git', ['rev-parse', `${tag}^{commit}`]) !== manifest.source) {
        throw Error('Manifest source mismatch');
    }
    const directory = mkdtempSync(join(tmpdir(), 'desktop-receipt-'));
    try {
        gh('release', 'download', tag, '--repo', repo, '--pattern', 'desktop-qualification.json', '--dir', directory);
        const path = join(directory, 'desktop-qualification.json');
        const previousBytes = readFileSync(path);
        const receipt = validateDesktopReceipt(manifest, JSON.parse(previousBytes), repo);
        const publication = publishDesktopDownloads(manifest, receipt.runs, command);
        const updated = validateDesktopReceipt(manifest, {...receipt, ...publication, checkedAt: new Date().toISOString()}, repo);
        writeFileSync(path, JSON.stringify(updated, null, 2) + '\n');
        try {
            gh('release', 'upload', tag, path, '--repo', repo, '--clobber');
        } catch (uploadError) {
            // A failed replacement may leave the original or a concurrent
            // writer's receipt intact. Never delete either during recovery.
            try {
                const release = JSON.parse(gh('release', 'view', tag, '--repo', repo, '--json', 'assets'));
                if (!Array.isArray(release.assets)) throw Error('Cannot inspect desktop receipt assets');
                if (!release.assets.some(asset => asset.name === 'desktop-qualification.json')) {
                    writeFileSync(path, previousBytes);
                    // Create only: a concurrent upload after the read must win.
                    gh('release', 'upload', tag, path, '--repo', repo);
                }
            } catch (restoreError) {
                throw new AggregateError([uploadError, restoreError], 'Desktop receipt upload and restoration failed');
            }
            throw uploadError;
        }
        return updated;
    } finally {
        rmSync(directory, {recursive: true, force: true});
    }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) backfillDesktopDownloads(process.argv[2]);
