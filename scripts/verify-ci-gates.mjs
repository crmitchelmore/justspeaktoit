import { pathToFileURL } from 'node:url';

// Local diagnostic/test oracle for the explicit predicate in ci.yml.
// The protected aggregate does not execute this repository-controlled helper.
// A skipped conditional job is acceptable only when path detection says so.
// Docs, website, Android and Workers-only pull requests skip `apple`; Swift
// changes run Lint, the portable Linux graph and one macOS job; every other
// macOS gate runs only on merge batches, main and `ci:full` pull requests.
export const gateJobs = {
  apple: ['lint'],
  swift: ['build-macos', 'portable-linux'],
  full: [
    'build-ios', 'build-ios-swiftpm', 'build-ios-test-products', 'build-ios-keyboard', 'release-validation',
    'core-journey-e2e', 'core-journey-fixture-ui', 'api-compatibility',
  ],
};

export function assessCIGates(needs, event) {
  const errors = [];
  const requireSuccess = id => {
    if (needs[id]?.result !== 'success') {
      errors.push(`${id}: expected success, got ${needs[id]?.result ?? 'missing'}`);
    }
  };
  requireSuccess('release-paths');
  const outputs = needs['release-paths']?.outputs ?? {};
  for (const flag of ['apple', 'swift', 'full']) {
    if (!['true', 'false'].includes(outputs[flag])) errors.push(`release-paths: missing or invalid ${flag} output`);
  }
  if (event !== 'pull_request' && outputs.full !== 'true') errors.push('release-paths: batches and main must run every gate');
  for (const [flag, ids] of Object.entries(gateJobs)) {
    // Pushes (merge batches and main) must run every gate even if path detection is misconfigured.
    const required = event !== 'pull_request' || outputs[flag] !== 'false';
    for (const id of ids) {
      if (required || needs[id]?.result !== 'skipped') requireSuccess(id);
    }
  }
  return errors;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const errors = assessCIGates(JSON.parse(process.env.CI_GATE_NEEDS), process.env.GITHUB_EVENT_NAME);
  for (const error of errors) console.error(`::error::${error}`);
  if (errors.length) process.exitCode = 1;
  else console.log('All required CI gates passed (only path-excluded PR gates may skip).');
}
