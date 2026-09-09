import { createHash } from 'node:crypto';
import { deterministicNotes, filterCommitsForTrack, markdownToHTML } from './release-notes-lib.mjs';

export const digest = value => createHash('sha256').update(value).digest('hex');
export const surfaces = ['mac-direct', 'mac-store', 'ios'];
export function validateManifest(manifest) {
    if (manifest.schema !== 1 || !['alpha', 'stable'].includes(manifest.train)) throw Error('Invalid release manifest');
    if (!/^[a-f0-9]{40}$/.test(manifest.source)) throw Error('A full immutable source SHA is required');
    if (!/^(alpha-build|stable-candidate)-[1-9][0-9]*$/.test(manifest.tag)) throw Error('Invalid release tag');
    if (!manifest.tag.startsWith(manifest.train === 'alpha' ? 'alpha-build-' : 'stable-candidate-')) throw Error('Release tag/train mismatch');
    if (!/^\d+$/.test(manifest.build)) throw Error('Invalid upload build');
    if (!Number.isSafeInteger(manifest.ordinal) || manifest.ordinal < 1 || !manifest.tag.endsWith(`-${manifest.ordinal}`)) throw Error('Invalid allocation ordinal');
    if (!/^[a-f0-9]{64}$/.test(manifest.dependenciesHash)) throw Error('Missing frozen dependency hash');
    for (const surface of surfaces) {
        const item = manifest.surfaces[surface];
        if (!/^\d+(?:\.\d+){0,2}$/.test(item.build)) throw Error("Missing per-surface build number");
        if (surface === 'mac-direct' && item.build !== manifest.build) throw Error('Direct build does not match allocation');
        if (surface !== 'mac-direct' && !/^[1-9]\d{0,3}(?:\.\d{1,2}){0,2}$/.test(item.build)) throw Error('Invalid Apple upload build components');
        if (item.storeNotes.length > 4000) throw Error('Store notes exceed the frozen Apple text limit');
        if (!/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(item.version)) throw Error('Apple marketing versions must be numeric X.Y.Z');
        if (!/^[a-f0-9]{40}$/.test(item.baseline)) throw Error('Missing published baseline');
        if (digest(item.notes) !== item.notesHash) throw Error(`Notes hash mismatch: ${surface}`);
        if (digest(item.storeNotes) !== item.storeNotesHash) throw Error(`Store notes hash mismatch: ${surface}`);
    }
    return manifest;
}

// A revert and its reverted commit cancel only when both are within this range.
// Reverts of already-published behaviour remain visible in the release notes.
export function effectiveCommits(commits) {
    const removed = new Set();
    for (const commit of [...commits].reverse()) {
        if (removed.has(commit.sha)) continue;
        const target = commit.body.match(/This reverts commit ([a-f0-9]{40})\./)?.[1];
        if (target && commits.some(c => c.sha === target)) {
            removed.add(commit.sha); removed.add(target);
        }
    }
    const seen = new Set();
    return commits.filter(c => !removed.has(c.sha)).filter(c => {
        const key = c.sha;
        if (seen.has(key)) return false;
        seen.add(key); return true;
    });
}
export function notesFor(commits, platform, compareURL) {
    return deterministicNotes({commits: filterCommitsForTrack(effectiveCommits(commits), platform), compareURL});
}
export function notesHTML(manifest, surface) { return markdownToHTML(manifest.surfaces[surface].notes); }
export function canAdvance(current, incoming) { return !current || BigInt(incoming.build) > BigInt(current.build); }
export function nextAllocation(manifests, train, now = Date.now()) {
    const ordinal = 1 + Math.max(0, ...manifests.filter(m => m.train === train).map(m => m.ordinal));
    // Preserve the existing direct-Mac YYYYMMDDHHmm update ordering.
    // Apple uploads use a separate small counter in each surface entry.
    const timestamp = Number(new Date(now).toISOString().replace(/\D/g, "").slice(0,12));
    const build = String(Math.max(timestamp, ...manifests.map(m => Number(m.build) + 1)));
    return {ordinal, build};
}
