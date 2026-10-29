#!/usr/bin/env node
import { createHash } from 'node:crypto';
import { copyFileSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { runReleaseCommand as run } from './release-command.mjs';
import { validateManifest } from './release-train-lib.mjs';
import { desktopDownloads, liveArtifact, validateDesktopReceipt, verifyDesktopDownload } from './desktop-release-lib.mjs';

const repo = process.env.GITHUB_REPOSITORY ?? 'crmitchelmore/justspeaktoit';
const gh = (...args) => run('gh', args);
const json = path => JSON.parse(readFileSync(path, 'utf8'));

// Copies each qualifying run's bundle onto the manifest release under a
// stable name, after checking its bytes against that run's own evidence.
export function publishDesktopDownloads(manifest, runs) {
    const directory = mkdtempSync(join(tmpdir(), 'desktop-downloads-'));
    try {
        const downloads = {};
        for (const spec of desktopDownloads) {
            const runID = runs[spec.workflow]?.id;
            const listed = JSON.parse(gh('api', `repos/${repo}/actions/runs/${runID}/artifacts?per_page=100`));
            if (!liveArtifact(listed.artifacts, spec.artifact)) throw Error(`${spec.workflow} run ${runID} has no live ${spec.artifact}`);
            const target = join(directory, spec.artifact);
            gh('run', 'download', String(runID), '--repo', repo, '--name', spec.artifact, '--dir', target);
            const evidence = json(join(target, spec.kind === 'windows' ? 'bundle-evidence.json' : 'build-provenance.json'));
            const fileName = spec.kind === 'windows' ? evidence.zip?.name : 'JustSpeakToIt-x86_64.flatpak';
            const bytes = readFileSync(join(target, fileName ?? ''));
            const sha256 = createHash('sha256').update(bytes).digest('hex');
            verifyDesktopDownload(spec, manifest, evidence, sha256);
            const published = join(directory, spec.asset);
            copyFileSync(join(target, fileName), published);
            gh('release', 'upload', manifest.tag, published, '--repo', repo, '--clobber');
            downloads[spec.asset] = {workflow: spec.workflow, run: runID, architecture: spec.architecture,
                bytes: bytes.length, sha256};
            console.log(`Published ${spec.asset} (${bytes.length} bytes, ${sha256}) from run ${runID}`);
        }
        return downloads;
    } finally {
        rmSync(directory, {recursive: true, force: true});
    }
}

// Backfill: node scripts/publish-desktop-downloads.mjs <manifest-tag>
if (import.meta.url === pathToFileURL(process.argv[1]).href) {
    const tag = process.argv[2];
    if (!/^(alpha-build|stable-candidate)-[1-9][0-9]*$/.test(tag ?? '')) throw Error('Immutable manifest tag required');
    const manifest = validateManifest(JSON.parse(run('git', ['for-each-ref', '--format=%(contents)', `refs/tags/${tag}`])));
    const directory = mkdtempSync(join(tmpdir(), 'desktop-receipt-'));
    try {
        gh('release', 'download', tag, '--repo', repo, '--pattern', 'desktop-qualification.json', '--dir', directory);
        const receipt = validateDesktopReceipt(manifest, json(join(directory, 'desktop-qualification.json')));
        publishDesktopDownloads(manifest, receipt.runs);
    } finally {
        rmSync(directory, {recursive: true, force: true});
    }
}
