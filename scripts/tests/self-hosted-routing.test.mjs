import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { test } from 'node:test';

const directory = new URL('../../.github/workflows/', import.meta.url);
const workflows = Object.fromEntries(readdirSync(directory).filter((name) => name.endsWith('.yml'))
  .map((name) => [name, readFileSync(new URL(name, directory), 'utf8')]));

function jobs(source) {
  return Object.fromEntries([...source.matchAll(/^  ([a-zA-Z][a-zA-Z0-9_-]+):\n([\s\S]*?)(?=^  [a-zA-Z][a-zA-Z0-9_-]+:\n|(?![\s\S]))/gm)]
    .map(([, id, body]) => [id, body]));
}

function route(body, github, vars = {}) {
  const expression = body.match(/runs-on: \$\{\{ (.+) \}\}/)?.[1];
  assert.ok(expression, 'job must use guarded routing');
  return new Function('github', 'vars', 'fromJSON', `return (${expression});`)(github, vars, JSON.parse);
}

function context(event = 'pull_request', repository = 'crmitchelmore/justspeaktoit') {
  return {
    event_name: event, ref: 'refs/heads/main', sha: 'merge-sha', repository: 'crmitchelmore/justspeaktoit',
    event: { pull_request: { head: { sha: 'head-sha', repo: { full_name: repository } } } },
  };
}

const omarchy = ['self-hosted', 'Linux', 'X64', 'omarchy-local'];
const reviewedMacs = ['jsti-reviewed-local', 'macOS'];
const linuxJobs = {
  'ci.yml': { 'paid-access-worker': 'ubuntu-latest' },
  'dependabot-policy-checks.yml': { policy: 'ubuntu-latest' },
  'desktop-icons.yml': { resources: 'ubuntu-24.04' },
  'linux.yml': { 'linux-desktop': 'ubuntu-24.04' },
  'linux-local-runtime.yml': { runtime: 'ubuntu-24.04' },
  'windows.yml': { 'portable-linux': 'ubuntu-22.04' },
};
const macJobs = {
  'windows.yml': { 'portable-macos': 'macos-15' },
  'local-transcription-benchmark.yml': { 'benchmark-package': 'macos-latest' },
};

function assertGuarded(body, pool, fallback, label) {
  const hosted = [fallback];
  assert.deepEqual(route(body, context(), { JSTI_NATIVE_APPROVED_SHA: 'head-sha' }), pool, label);
  assert.deepEqual(route(body, context('push'), { JSTI_NATIVE_APPROVED_SHA: 'merge-sha' }), pool, label);
  assert.deepEqual(route(body, context()), hosted, `${label}: unset approval stays hosted`);
  assert.deepEqual(route(body, context(), { JSTI_NATIVE_APPROVED_SHA: 'merge-sha' }), hosted,
    `${label}: PR approval must match the head, not the merge commit`);
  assert.deepEqual(route(body, context('pull_request', 'fork/repo'), { JSTI_NATIVE_APPROVED_SHA: 'head-sha' }),
    hosted, `${label}: forks never reach self-hosted runners`);
  assert.deepEqual(route(body, { ...context('push'), ref: 'refs/heads/feature' },
    { JSTI_NATIVE_APPROVED_SHA: 'merge-sha' }), hosted, `${label}: only main pushes`);
  for (const event of ['workflow_dispatch', 'schedule', 'pull_request_target', 'workflow_call']) {
    assert.deepEqual(route(body, context(event), { JSTI_NATIVE_APPROVED_SHA: 'merge-sha' }), hosted,
      `${label}: ${event} stays hosted`);
  }
}

test('Linux workloads use Omarchy only for the approved same-repository source', () => {
  for (const [file, ids] of Object.entries(linuxJobs)) {
    const bodies = jobs(workflows[file]);
    for (const [id, fallback] of Object.entries(ids)) {
      const label = `${file}:${id}`;
      assertGuarded(bodies[id], omarchy, fallback, label);
      assert.deepEqual(route(bodies[id], context(), {
        JSTI_NATIVE_APPROVED_SHA: 'head-sha', JSTI_LINUX_RUNNER_LABELS: '["ubuntu-24.04"]',
      }), ['ubuntu-24.04'], `${label}: the Linux label variable is an independent kill switch`);
      assert.deepEqual(route(bodies[id], context(), {
        JSTI_NATIVE_APPROVED_SHA: 'head-sha', JSTI_NATIVE_RUNNER_LABELS: '["x"]',
      }), omarchy, `${label}: Mac pool labels never select Linux runners`);
    }
  }
});

test('additional Apple jobs share the reviewed Mac pool', () => {
  for (const [file, ids] of Object.entries(macJobs)) {
    const bodies = jobs(workflows[file]);
    for (const [id, fallback] of Object.entries(ids)) assertGuarded(bodies[id], reviewedMacs, fallback, `${file}:${id}`);
  }
});

test('critical-path gates stay on parallel hosted runners, not the single Omarchy runner', () => {
  for (const [file, id] of [['ci.yml', 'release-paths'], ['ci.yml', 'required-macos'], ['codeql.yml', 'changes']]) {
    assert.match(jobs(workflows[file])[id], /^    runs-on: ubuntu-latest$/m, `${file}:${id}`);
  }
});

test('no default routes to the owner Mac or unreviewed self-hosted labels', () => {
  for (const [file, source] of Object.entries(workflows)) {
    assert.doesNotMatch(source, /mac-mini-3/, file);
    assert.doesNotMatch(source, /'\["jsti-macos-build"/, `${file}: jsti-macos-build also labels the owner Mac`);
  }
});

test('root containers return the persistent self-hosted work tree to the runner user', () => {
  const containerJobs = [['linux.yml', 'linux-desktop'], ['linux-local-runtime.yml', 'runtime'],
    ['windows.yml', 'portable-linux']];
  for (const [file, id] of containerJobs) {
    const body = jobs(workflows[file])[id];
    const steps = body.slice(body.indexOf('    steps:\n'));
    assert.match(steps, /^    steps:\n(?:      #.*\n)*      - name: Record host work-tree owner\n        if: runner\.environment == 'self-hosted'\n/,
      `${file}:${id}: record the owner before anything runs as container root`);
    const restore = steps.lastIndexOf('      - name: Restore host work-tree ownership');
    assert.ok(restore > 0, `${file}:${id}: must restore ownership`);
    assert.equal(steps.indexOf('      - ', restore + 1), -1, `${file}:${id}: restore must be the final step`);
    assert.match(steps.slice(restore), /if: always\(\) && runner\.environment == 'self-hosted'/);
    assert.match(steps.slice(restore), /chown -R "\$owner" \/__w/);
  }
});

test('privileged, secret-bearing and UI jobs stay on disposable hosted runners', () => {
  for (const id of ['flatpak', 'retest']) {
    const body = jobs(workflows['linux-flatpak.yml'])[id];
    assert.match(body, /^    runs-on: ubuntu-24\.04$/m, id);
    assert.match(body, /options: --privileged/, id);
  }
  for (const [file, id] of [['codeql.yml', 'analyze'], ['windows-cross-proof.yml', 'compile'],
    ['windows-arm64.yml', 'bundle'], ['site-media.yml', 'capture']]) {
    assert.doesNotMatch(jobs(workflows[file])[id], /JSTI_|self-hosted/, `${file}:${id}`);
  }
  for (const [file, source] of Object.entries(workflows)) {
    if (!/JSTI_(?:NATIVE|LINUX)_RUNNER_LABELS/.test(source)) continue;
    assert.doesNotMatch(source, /^  pull_request_target:/m, file);
    for (const [id, body] of Object.entries(jobs(source))) {
      if (!/JSTI_(?:NATIVE|LINUX)_RUNNER_LABELS/.test(body)) continue;
      assert.doesNotMatch(body, /secrets\./, `${file}:${id}: self-hosted jobs receive no secrets`);
    }
  }
});

test('native benchmark never overwrites the shared home SwiftPM cache', () => {
  const body = jobs(workflows['local-transcription-benchmark.yml'])['benchmark-package'];
  assert.match(body, /- name: Cache Swift dependency sources\n        if: runner\.environment != 'self-hosted'\n/);
});
