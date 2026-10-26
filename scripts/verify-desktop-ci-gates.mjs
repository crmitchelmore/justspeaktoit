// Diagnostic oracle only. Terminal jobs evaluate inline expressions without
// checking out or executing repository-controlled code.
export const lanes = {
  'windows-native': { file: 'windows.yml', name: 'Windows x64 gate',
    required: ['local-runtime', 'windows', 'portable-macos', 'portable-linux'],
    entry: ['local-runtime', 'portable-macos', 'portable-linux'] },
  'windows-arm64': { file: 'windows-arm64.yml', name: 'Windows ARM64 gate',
    required: ['local-runtime', 'native', 'bundle', 'bundle-execute', 'package-lifecycle'], entry: ['local-runtime'] },
  'windows-proof': { file: 'windows-cross-proof.yml', name: 'Windows distribution gate',
    required: ['local-runtime', 'compile', 'execute', 'bundle-execute', 'package-lifecycle'], entry: ['local-runtime'] },
  'linux-desktop': { file: 'linux.yml', name: 'Linux desktop gate',
    required: ['local-runtime', 'linux-desktop'], entry: ['local-runtime'] },
  'linux-flatpak': { file: 'linux-flatpak.yml', name: 'Linux Flatpak gate',
    required: ['flatpak', 'retest'], entry: ['flatpak', 'retest'] },
};

export function acceptsDesktopGate(lane, needs, event) {
  const classifier = needs['desktop-paths'];
  const selected = classifier?.outputs?.selected;
  if (classifier?.result !== 'success' || !['true', 'false'].includes(selected)) return false;
  if (event !== 'pull_request' && selected !== 'true') return false;
  if (lane === 'linux-flatpak') {
    const mode = classifier.outputs.mode;
    if (!['build', 'retest'].includes(mode) || (mode === 'retest' && event !== 'workflow_dispatch')) return false;
    if (selected === 'false') return needs.flatpak?.result === 'skipped' && needs.retest?.result === 'skipped';
    const active = mode === 'retest' ? 'retest' : 'flatpak';
    const inactive = active === 'retest' ? 'flatpak' : 'retest';
    return needs[active]?.result === 'success' && needs[inactive]?.result === 'skipped';
  }
  return lanes[lane].required.every(id => needs[id]?.result === 'success' ||
    (selected === 'false' && needs[id]?.result === 'skipped'));
}
