import { pathToFileURL } from 'node:url';

// Local diagnostic/test oracle for the explicit predicate in ci.yml.
// The protected aggregate does not execute this repository-controlled helper.
// A skipped conditional job is acceptable only when path detection says so.
// A pull request with a trusted pre-pr record (same repository, not
// Dependabot) skips every build and test: they run on main after the merge.
// Untrusted pull requests (Dependabot, forks) run the Workers package; Lint
// unless only docs, the website, Android or Workers changed; and, for Swift
// changes, the portable Linux graph and one macOS job. Every other macOS gate
// runs only on merge batches, main and `ci:full` pull requests.
// The macOS lanes are reusable workflows (ci-*.yml); each lane job fails when
// any job inside it does, so the gate checks lanes, not their jobs.
export const gateJobs = {
  workers: ['paid-access-worker'],
  apple: ['lint'],
  swift: ['macos-debug', 'portable-linux'],
  full: ['ios', 'macos-release', 'journey-ui'],
};

export function assessCIGates(needs, event) {
  const errors = [];
  const requireSuccess = id => {
    if (needs[id]?.result !== 'success') {
      errors.push(`${id}: expected success, got ${needs[id]?.result ?? 'missing'}`);
    }
  };
  requireSuccess('release-paths');
  // Pre-PR evidence always runs; it passes straight through on pushes and bots.
  requireSuccess('pre-pr-evidence');
  const outputs = needs['release-paths']?.outputs ?? {};
  // `api` selects the pull-request API step inside build-macos; it must be explicit.
  for (const flag of ['apple', 'swift', 'api', 'full', 'workers']) {
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
