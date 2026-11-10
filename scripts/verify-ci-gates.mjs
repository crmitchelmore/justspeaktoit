import { pathToFileURL } from 'node:url';

// Local diagnostic/test oracle for the explicit predicate in ci.yml.
// The protected aggregate does not execute this repository-controlled helper.
// A skipped conditional job is acceptable only when path detection says so.
export function assessCIGates(needs, event) {
  const errors = [];
  const requireSuccess = id => {
    if (needs[id]?.result !== 'success') {
      errors.push(`${id}: expected success, got ${needs[id]?.result ?? 'missing'}`);
    }
  };
  requireSuccess('release-paths');
  const outputs = needs['release-paths']?.outputs ?? {};
  for (const [flag, ids] of [
    // Lint skips only for pull requests that change nothing outside the Android app.
    ['apple', ['lint']],
    // Swift build/test gates also skip for docs, site and Linux/Windows-only changes.
    ['apple-swift', ['build-macos', 'build-ios']],
    // Fast-tier pull requests run these heavy legs only when their inputs change.
    ['release', ['release-validation']],
    ['fixture-ui', ['core-journey-fixture-ui']],
    ['keyboard', ['build-ios-keyboard']],
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
  const apiSkipAllowed = event !== 'pull_request' || outputs['apple-swift'] === 'false';
  if (!apiSkipAllowed || needs['api-compatibility']?.result !== 'skipped') {
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
