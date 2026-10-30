export const desktopWorkflows = [
    'windows.yml', 'windows-arm64.yml', 'windows-cross-proof.yml', 'linux.yml', 'linux-flatpak.yml'
];

export function projectDesktopRun(observed) {
    return {...Object.fromEntries(
        ['id', 'head_sha', 'head_branch', 'event', 'status', 'conclusion', 'html_url', 'path', 'run_attempt']
            .map(key => [key, observed[key]])), repository: observed.head_repository?.full_name};
}

export function validateDesktopReceipt(manifest, receipt, repo = process.env.GITHUB_REPOSITORY ?? 'crmitchelmore/justspeaktoit') {
    if (receipt.status !== 'verified' || receipt.source !== manifest.source || receipt.tag !== manifest.tag ||
        receipt.build !== manifest.build) throw Error('Desktop qualification does not match candidate');
    for (const workflow of desktopWorkflows) {
        const run = receipt.runs?.[workflow];
        if (!run || !Number.isSafeInteger(run.id) || run.id < 1 || run.head_sha !== manifest.source ||
            !((run.head_branch === manifest.tag && run.event === 'workflow_dispatch') ||
              (run.head_branch === 'main' && run.event === 'push')) ||
            run.repository !== repo || run.path !== `.github/workflows/${workflow}` ||
            run.status !== 'completed' || run.conclusion !== 'success' ||
            (run.run_attempt !== undefined && (!Number.isSafeInteger(run.run_attempt) || run.run_attempt < 1))) {
            throw Error(`Desktop qualification missing or failed: ${workflow}`);
        }
    }
    return receipt;
}

export function latestDesktopRun(runs, manifest, startedAt) {
    return runs.filter(run => run.head_sha === manifest.source && run.head_branch === manifest.tag &&
        run.event === 'workflow_dispatch' && Date.parse(run.created_at) >= Date.parse(startedAt))
        .sort((a, b) => b.id - a.id)[0];
}

export function desktopQualificationComplete(manifest, receipt) {
    if (manifest.desktopQualification !== 1) return true;
    try { validateDesktopReceipt(manifest, receipt); return true; }
    catch { return false; }
}

// Only a successful main push is reusable. PR merge refs, fork executions and
// other workflow definitions never qualify a release. A failed newer rerun
// supersedes older success for the same source.
export function reusableDesktopRun(runs, manifest, workflow, repo) {
    const newest = runs.filter(run => run.head_sha === manifest.source && run.head_branch === 'main' &&
        run.event === 'push' && run.head_repository?.full_name === repo &&
        run.path === `.github/workflows/${workflow}`).sort((a,b) => b.id - a.id)[0];
    return newest?.status === 'completed' && newest.conclusion === 'success' ? newest : undefined;
}

// Verified developer downloads copied from the qualifying runs. Workflow
// artifacts expire, so the release keeps the exact bytes the runs proved.
export const desktopDownloads = [
    {workflow: 'windows-cross-proof.yml', artifact: 'windows-runtime-bundle', kind: 'windows',
        architecture: 'x64', asset: 'JustSpeakToIt-windows-x64-developer.zip'},
    {workflow: 'windows-arm64.yml', artifact: 'windows-runtime-bundle-arm64', kind: 'windows',
        architecture: 'arm64', asset: 'JustSpeakToIt-windows-arm64-developer.zip'},
    {workflow: 'linux-flatpak.yml', artifact: 'justspeaktoit-flatpak-x86_64', kind: 'flatpak',
        architecture: 'x86_64', asset: 'JustSpeakToIt-linux-x86_64.flatpak'},
];

export function liveArtifact(artifacts, name) {
    const matches = artifacts.filter(artifact => artifact.name === name && !artifact.expired);
    return matches.length === 1 ? matches[0] : undefined;
}

// `evidence` is the run's own record; `sha256` is computed locally from the
// downloaded bytes. Returns the file name inside the artifact to publish.
export function desktopDownloadFile(spec, manifest, evidence) {
    if (spec.kind === 'windows') {
        if (evidence?.application?.sourceCommit !== manifest.source || evidence?.architecture !== spec.architecture ||
            !/^[0-9a-f]{64}$/.test(evidence?.zip?.sha256 ?? '') ||
            !/^[\w.-]+\.zip$/.test(evidence?.zip?.name ?? '')) {
            throw Error(`${spec.asset}: bundle evidence does not match ${manifest.source}`);
        }
        return evidence.zip.name;
    }
    if (evidence?.sourceSHA !== manifest.source || evidence?.builtRevision !== manifest.source ||
        !/^[0-9a-f]{64}$/.test(evidence?.bundleSHA256 ?? '')) {
        throw Error(`${spec.asset}: Flatpak provenance does not match ${manifest.source}`);
    }
    return 'JustSpeakToIt-x86_64.flatpak';
}

// Admit the evidence/name before opening a metadata-selected payload path.
export function verifyDesktopDownload(spec, manifest, evidence, sha256) {
    const fileName = desktopDownloadFile(spec, manifest, evidence);
    const expected = spec.kind === 'windows' ? evidence.zip.sha256 : evidence.bundleSHA256;
    if (!/^[0-9a-f]{64}$/.test(sha256 ?? '') || sha256 !== expected) {
        throw Error(`${spec.asset}: payload digest does not match evidence`);
    }
    return fileName;
}
