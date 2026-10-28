export const desktopWorkflows = [
    'windows.yml', 'windows-arm64.yml', 'windows-cross-proof.yml', 'linux.yml', 'linux-flatpak.yml'
];

export function validateDesktopReceipt(manifest, receipt) {
    if (receipt.status !== 'verified' || receipt.source !== manifest.source || receipt.tag !== manifest.tag ||
        receipt.build !== manifest.build) throw Error('Desktop qualification does not match candidate');
    for (const workflow of desktopWorkflows) {
        const run = receipt.runs?.[workflow];
        if (!run || !Number.isSafeInteger(run.id) || run.id < 1 || run.head_sha !== manifest.source ||
            run.head_branch !== manifest.tag || run.event !== 'workflow_dispatch' ||
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
