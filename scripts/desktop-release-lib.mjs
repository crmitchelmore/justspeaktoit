export const desktopWorkflows = [
    'windows.yml', 'windows-arm64.yml', 'windows-cross-proof.yml', 'linux.yml', 'linux-flatpak.yml'
];

export function projectDesktopRun(observed, equivalentTo) {
    return {...Object.fromEntries(
        ['id', 'head_sha', 'head_branch', 'event', 'status', 'conclusion', 'html_url', 'path', 'run_attempt']
            .map(key => [key, observed[key]])), repository: observed.head_repository?.full_name,
        ...(equivalentTo && equivalentTo !== observed.head_sha ? {equivalentTo} : {})};
}

const manifestTag = /^(alpha-build|stable-candidate)-[1-9][0-9]*$/;
const sha = /^[0-9a-f]{40}$/;

// A run qualifies the manifest either at its exact source, or, when its tree
// matched the source on every path the workflow builds from, as `equivalentTo`
// that source. The second form reuses a main push or an earlier manifest's
// dispatch instead of rebuilding an unchanged desktop tree for every Alpha.
function qualifiesSource(run, manifest) {
    if (run.head_sha === manifest.source) {
        return (run.head_branch === manifest.tag && run.event === 'workflow_dispatch') ||
            (run.head_branch === 'main' && run.event === 'push');
    }
    return run.equivalentTo === manifest.source && sha.test(run.head_sha ?? '') &&
        ((run.head_branch === 'main' && run.event === 'push') ||
         (manifestTag.test(run.head_branch ?? '') && run.event === 'workflow_dispatch'));
}

export function validateDesktopReceipt(manifest, receipt, repo = process.env.GITHUB_REPOSITORY ?? 'crmitchelmore/justspeaktoit') {
    if (receipt.status !== 'verified' || receipt.source !== manifest.source || receipt.tag !== manifest.tag ||
        receipt.build !== manifest.build) throw Error('Desktop qualification does not match candidate');
    for (const workflow of desktopWorkflows) {
        const run = receipt.runs?.[workflow];
        if (!run || !Number.isSafeInteger(run.id) || run.id < 1 || !qualifiesSource(run, manifest) ||
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

// The `on.push.paths` list of a workflow file (the paths whose changes make it run on main).
export function workflowPushPaths(text) {
    const lines = text.split('\n');
    let inOn = false, inPush = false, pushIndent = -1, paths;
    for (const line of lines) {
        if (/^\S/.test(line)) { inOn = /^on:\s*$/.test(line); inPush = false; continue; }
        if (!inOn) continue;
        const indent = line.search(/\S/);
        if (indent < 0) continue;
        if (/^\s*push:\s*$/.test(line)) { inPush = true; pushIndent = indent; continue; }
        if (inPush && indent <= pushIndent) { inPush = false; if (paths) break; }
        if (!inPush) continue;
        if (/^\s*paths:\s*(&\S+)?\s*$/.test(line)) { paths = []; continue; }
        const item = line.match(/^\s*-\s*['"]?([^'"#\s]+)['"]?/);
        if (paths && item) paths.push(item[1]);
        else if (paths && paths.length) break;
    }
    return paths?.length ? paths : undefined;
}

// Pathspecs that decide whether two commits build the same desktop artifact:
// the workflow's own push paths plus the workflow file and shared composite actions.
export function equivalencePathspecs(workflow, pushPaths) {
    return [...new Set([...pushPaths, `.github/workflows/${workflow}`, '.github/actions/**'])]
        .map(path => `:(glob)${path}`);
}

// The newest completed main push, or earlier manifest dispatch, of this workflow
// whose tree is equivalent to the manifest source. A failed newer equivalent run
// supersedes an older success, exactly like an exact-source rerun.
export function equivalentDesktopRun(runs, manifest, workflow, repo, isEquivalent) {
    const candidates = runs.filter(run => run.head_repository?.full_name === repo &&
        run.path === `.github/workflows/${workflow}` && run.status === 'completed' && sha.test(run.head_sha ?? '') &&
        ((run.event === 'push' && run.head_branch === 'main') ||
         (run.event === 'workflow_dispatch' && manifestTag.test(run.head_branch ?? ''))))
        .sort((a, b) => b.id - a.id);
    for (const run of candidates) {
        if (!isEquivalent(run.head_sha)) continue;
        return run.conclusion === 'success' ? run : undefined;
    }
    return undefined;
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
// `built` is the commit the qualifying run built: the manifest source, or the
// equivalent commit the receipt records for a reused run.
export function desktopDownloadFile(spec, manifest, evidence, built = manifest.source) {
    if (spec.kind === 'windows') {
        if (evidence?.application?.sourceCommit !== built || evidence?.architecture !== spec.architecture ||
            !/^[0-9a-f]{64}$/.test(evidence?.zip?.sha256 ?? '') ||
            !/^[\w.-]+\.zip$/.test(evidence?.zip?.name ?? '')) {
            throw Error(`${spec.asset}: bundle evidence does not match ${built}`);
        }
        return evidence.zip.name;
    }
    if (evidence?.sourceSHA !== built || evidence?.builtRevision !== built ||
        !/^[0-9a-f]{64}$/.test(evidence?.bundleSHA256 ?? '')) {
        throw Error(`${spec.asset}: Flatpak provenance does not match ${built}`);
    }
    return 'JustSpeakToIt-x86_64.flatpak';
}

// Admit the evidence/name before opening a metadata-selected payload path.
export function verifyDesktopDownload(spec, manifest, evidence, sha256, built = manifest.source) {
    const fileName = desktopDownloadFile(spec, manifest, evidence, built);
    const expected = spec.kind === 'windows' ? evidence.zip.sha256 : evidence.bundleSHA256;
    if (!/^[0-9a-f]{64}$/.test(sha256 ?? '') || sha256 !== expected) {
        throw Error(`${spec.asset}: payload digest does not match evidence`);
    }
    return fileName;
}
