import { pathToFileURL } from 'node:url';

// Keep the existing protected check name, but make it represent every gate.
// A skipped conditional job is acceptable only when path detection says so.
export function assessCIGates(needs, event) {
  const errors = [];
  const requireSuccess = id => {
    if (needs[id]?.result !== 'success') {
      errors.push(`${id}: expected success, got ${needs[id]?.result ?? 'missing'}`);
    }
  };
  for (const id of ['build-macos', 'build-ios', 'build-ios-keyboard-direct-capture', 'lint', 'release-paths']) {
    requireSuccess(id);
  }
  const outputs = needs['release-paths']?.outputs ?? {};
  for (const [flag, ids] of [
    ['package', ['release-validation']],
    ['core-journey', ['core-journey-e2e', 'core-journey-fixture-ui']],
  ]) {
    if (!['true', 'false'].includes(outputs[flag])) {
      errors.push(`release-paths: missing or invalid ${flag} output`);
    }
    // Pushes to main must run every gate even if path detection is misconfigured.
    const required = event !== 'pull_request' || outputs[flag] !== 'false';
    for (const id of ids) {
      if (required || needs[id]?.result !== 'skipped') requireSuccess(id);
    }
  }
  if (event === 'pull_request' || needs['api-compatibility']?.result !== 'skipped') {
    requireSuccess('api-compatibility');
  }
  return errors;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const errors = assessCIGates(JSON.parse(process.env.CI_GATE_NEEDS), process.env.GITHUB_EVENT_NAME);
  for (const error of errors) console.error(`::error::${error}`);
  if (errors.length) process.exitCode = 1;
  else console.log('All required CI gates passed (only path-excluded PR gates may skip).');
}
