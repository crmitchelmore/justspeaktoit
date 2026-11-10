import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, test } from 'node:test';

const hookSource = readFileSync(new URL('../runner-admission/job-started.sh', import.meta.url), 'utf8');
const work = mkdtempSync(join(tmpdir(), 'jsti-admission-'));
after(() => rmSync(work, { recursive: true, force: true }));

const git = (...args) => execFileSync('git', args, { cwd: work, encoding: 'utf8' }).trim();
// A local "GitHub": main has two commits; a feature branch has one more.
git('init', '-q', '-b', 'main', 'origin');
const inOrigin = (...args) => execFileSync('git', ['-C', join(work, 'origin'), '-c', 'user.name=t',
  '-c', 'user.email=t@example.com', ...args], { encoding: 'utf8' }).trim();
inOrigin('commit', '-q', '--allow-empty', '-m', 'one');
const older = inOrigin('rev-parse', 'HEAD');
inOrigin('commit', '-q', '--allow-empty', '-m', 'two');
const tip = inOrigin('rev-parse', 'HEAD');
inOrigin('checkout', '-q', '-b', 'feature');
inOrigin('commit', '-q', '--allow-empty', '-m', 'unmerged');
const unmerged = inOrigin('rev-parse', 'HEAD');
inOrigin('checkout', '-q', 'main');

const runner = join(work, 'runner');
execFileSync('mkdir', ['-p', runner]);
const hook = join(runner, 'job-started.sh');
// Only the remote URL is redirected to the local fixture; every check is unchanged.
writeFileSync(hook, hookSource.replace(/^REMOTE=.*$/m, `REMOTE="${join(work, 'origin')}"`));
chmodSync(hook, 0o755);
writeFileSync(join(runner, 'approved-shas'), `${'a'.repeat(40)}\n`);

function admit(overrides = {}, event = {}) {
  const eventPath = join(work, 'event.json');
  writeFileSync(eventPath, JSON.stringify(event));
  const env = {
    PATH: '/usr/bin:/bin', GITHUB_REPOSITORY: 'crmitchelmore/justspeaktoit', GITHUB_EVENT_NAME: 'push',
    GITHUB_REF: 'refs/heads/main', GITHUB_SHA: tip, GITHUB_JOB: 'lint', GITHUB_EVENT_PATH: eventPath,
    GITHUB_WORKFLOW_REF: 'crmitchelmore/justspeaktoit/.github/workflows/ci.yml@refs/heads/main', ...overrides,
  };
  const result = spawnSync(hook, { env, encoding: 'utf8' });
  return { ok: result.status === 0, output: result.stdout + result.stderr };
}

test('main push and schedule commits on main are admitted without a manual SHA', () => {
  assert.ok(admit().ok);
  assert.ok(admit({ GITHUB_SHA: older }).ok, 'a run queued behind newer merges is still main source');
  assert.ok(admit({ GITHUB_EVENT_NAME: 'schedule' }).ok);
});

test('non-main sources, refs, workflows and events are denied', () => {
  assert.match(admit({ GITHUB_SHA: unmerged }).output, /not on .* main/);
  assert.match(admit({ GITHUB_REF: 'refs/heads/feature' }).output, /ref refs\/heads\/feature/);
  assert.match(admit({ GITHUB_WORKFLOW_REF: 'crmitchelmore/justspeaktoit/.github/workflows/ci.yml@refs/heads/feature' })
    .output, /not defined on main/);
  assert.match(admit({ GITHUB_REPOSITORY: 'someone/fork' }).output, /repository someone\/fork/);
  for (const event of ['workflow_dispatch', 'workflow_run', 'pull_request_target', 'issue_comment']) {
    assert.equal(admit({ GITHUB_EVENT_NAME: event }).ok, false, event);
  }
  assert.equal(admit({ GITHUB_SHA: 'not-a-sha' }).ok, false);
});

test('pull requests still need the exact approved same-repository head', () => {
  const pr = (sha, repo = 'crmitchelmore/justspeaktoit') => ({ pull_request: { head: { sha, repo: { full_name: repo } } } });
  const env = { GITHUB_EVENT_NAME: 'pull_request', GITHUB_REF: 'refs/pull/1/merge' };
  assert.ok(admit(env, pr('a'.repeat(40))).ok);
  assert.match(admit(env, pr(tip)).output, /not in .*approved-shas/);
  assert.match(admit(env, pr('a'.repeat(40), 'fork/repo')).output, /fork pull request/);
});

test('an allowed-jobs list restricts which jobs a runner admits', () => {
  writeFileSync(join(runner, 'allowed-jobs'), 'lint\n');
  try {
    assert.ok(admit().ok);
    assert.match(admit({ GITHUB_JOB: 'sign' }).output, /job sign is not in/);
  } finally {
    rmSync(join(runner, 'allowed-jobs'));
  }
});

test('the hook resolves tools and policy from fixed paths, not job environment', () => {
  assert.match(hookSource, /^GIT="\/usr\/bin\/git"$/m);
  assert.match(hookSource, /^REMOTE="https:\/\/github\.com\/crmitchelmore\/justspeaktoit\.git"$/m);
  assert.doesNotMatch(hookSource, /\$\{?JSTI_|\$\{?PATH/);
});
