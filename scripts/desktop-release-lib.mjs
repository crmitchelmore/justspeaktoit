export const desktopWorkflows = [
    'windows.yml', 'windows-arm64.yml', 'windows-cross-proof.yml', 'linux.yml', 'linux-flatpak.yml'
];

export function validateDesktopReceipt(manifest, receipt, repo = process.env.GITHUB_REPOSITORY ?? 'crmitchelmore/justspeaktoit') {
    if (receipt.status !== 'verified' || receipt.source !== manifest.source || receipt.tag !== manifest.tag ||
        receipt.build !== manifest.build) throw Error('Desktop qualification does not match candidate');
    for (const workflow of desktopWorkflows) {
        const run = receipt.runs?.[workflow];
        if (!run || !Number.isSafeInteger(run.id) || run.id < 1 || run.head_sha !== manifest.source ||
            !((run.head_branch === manifest.tag && run.event === 'workflow_dispatch') ||
              (run.head_branch === 'main' && run.event === 'push')) ||
            run.repository !== repo || run.path !== `.github/workflows/${workflow}` ||
            run.status !== 'completed' || run.conclusion !== 'success') {
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
