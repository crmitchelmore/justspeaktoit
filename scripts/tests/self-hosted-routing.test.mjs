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

function context(event = 'pull_request', repository = 'crmitchelmore/justspeaktoit',
  { actor = 'crmitchelmore', author = 'crmitchelmore' } = {}) {
  return {
    event_name: event, ref: 'refs/heads/main', sha: 'merge-sha', repository: 'crmitchelmore/justspeaktoit',
    actor, triggering_actor: actor,
    event: { pull_request: { user: { login: author }, head: { sha: 'head-sha', repo: { full_name: repository } } } },
  };
}

const reviewedMacs = ['jsti-reviewed-local', 'macOS'];
// The pool is one serial MacBook, so only light, independent jobs use it and
// everything else runs in parallel on hosted runners.
const nativeJobs = {
  'ci.yml': { lint: 'macos-latest', 'api-compatibility': 'macos-26-intel' },
  'local-transcription-benchmark.yml': { 'benchmark-package': 'macos-latest' },
};
const hostedJobs = {
  'ci.yml': {
    'build-macos': 'macos-26-intel', 'core-journey-e2e': 'macos-26-intel', 'release-validation': 'macos-latest',
    'build-ios-swiftpm': 'macos-latest', 'build-ios-keyboard': 'macos-latest', 'paid-access-worker': 'ubuntu-latest',
  },
  'dependabot-policy-checks.yml': { policy: 'ubuntu-latest' },
  'desktop-icons.yml': { resources: 'ubuntu-24.04' },
  'linux.yml': { 'linux-desktop': 'ubuntu-24.04' },
  'linux-local-runtime.yml': { runtime: 'ubuntu-24.04' },
  'windows.yml': { 'portable-macos': 'macos-15', 'portable-linux': 'ubuntu-22.04' },
};

function assertGuarded(body, pool, fallback, label) {
  const hosted = [fallback];
  const bot = 'dependabot[bot]';
  assert.deepEqual(route(body, context()), pool, label);
  assert.deepEqual(route(body, context('push')), pool, label);
  assert.deepEqual(route(body, context('pull_request', undefined, { actor: 'bravostation', author: 'bravostation' })),
    pool, label);
  assert.deepEqual(route(body, context(), { JSTI_LOCAL_RUNNERS: 'off' }), hosted, `${label}: master kill switch`);
  assert.deepEqual(route(body, context('pull_request', 'fork/repo')), hosted,
    `${label}: forks never reach self-hosted runners`);
  assert.deepEqual(route(body, context('pull_request', undefined, { actor: bot, author: bot })), hosted,
    `${label}: bot-authored pull requests stay hosted`);
  assert.deepEqual(route(body, context('pull_request', undefined, { author: bot })), hosted,
    `${label}: owner pushes to bot-authored pull requests stay hosted`);
  assert.deepEqual(route(body, context('push', undefined, { actor: bot })), hosted, `${label}: bot pushes stay hosted`);
  assert.deepEqual(route(body, { ...context('push'), ref: 'refs/heads/feature' }), hosted, `${label}: only main pushes`);
  for (const event of ['workflow_dispatch', 'schedule', 'pull_request_target', 'workflow_call']) {
    assert.deepEqual(route(body, context(event)), hosted, `${label}: ${event} stays hosted`);
  }
}

test('only the selected light Mac jobs share the reviewed Mac pool', () => {
  for (const [file, ids] of Object.entries(nativeJobs)) {
    const bodies = jobs(workflows[file]);
    for (const [id, fallback] of Object.entries(ids)) {
      const label = `${file}:${id}`;
      assertGuarded(bodies[id], reviewedMacs, fallback, label);
      assert.deepEqual(route(bodies[id], context(), { JSTI_NATIVE_RUNNER_LABELS: '["jsti-reviewed-local","macOS","X64"]' }),
        ['jsti-reviewed-local', 'macOS', 'X64'], `${label}: the pool label variable selects the runner`);
    }
  }
  const routed = [];
  for (const [file, source] of Object.entries(workflows)) {
    for (const [id, body] of Object.entries(jobs(source))) {
      if (/JSTI_NATIVE_RUNNER_LABELS/.test(body)) routed.push(`${file}:${id}`);
    }
  }
  assert.deepEqual(routed.sort(), Object.entries(nativeJobs)
    .flatMap(([file, ids]) => Object.keys(ids).map((id) => `${file}:${id}`)).sort(),
  'adding a job to the serial MacBook needs its admission hook updated too');
});

test('Linux and long Mac jobs run on parallel hosted runners', () => {
  for (const [file, ids] of Object.entries(hostedJobs)) {
    const bodies = jobs(workflows[file]);
    for (const [id, label] of Object.entries(ids)) {
      assert.match(bodies[id], new RegExp(`^    runs-on: ${label.replaceAll('.', '\\.')}$`, 'm'), `${file}:${id}`);
    }
  }
  for (const [file, source] of Object.entries(workflows)) {
    assert.doesNotMatch(source, /JSTI_LINUX_RUNNER_LABELS|omarchy-local/, `${file}: no self-hosted Linux routing`);
  }
});

test('critical-path gates stay on parallel hosted runners', () => {
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
    if (!/JSTI_NATIVE_RUNNER_LABELS/.test(source)) continue;
    assert.doesNotMatch(source, /^  pull_request_target:/m, file);
    for (const [id, body] of Object.entries(jobs(source))) {
      if (!/JSTI_NATIVE_RUNNER_LABELS/.test(body)) continue;
      assert.doesNotMatch(body, /secrets\./, `${file}:${id}: self-hosted jobs receive no secrets`);
    }
  }
});

test('native benchmark never overwrites the shared home SwiftPM cache', () => {
  const body = jobs(workflows['local-transcription-benchmark.yml'])['benchmark-package'];
  assert.match(body, /- name: Cache Swift dependency sources\n        if: runner\.environment != 'self-hosted'\n/);
});
