import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import {
  existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, readlinkSync, rmSync, writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
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
const omarchy = ['self-hosted', 'Linux', 'X64', 'omarchy-local'];
// Dedicated MacBook pool (two runners): the Debug critical path plus light,
// cache-friendly jobs. Each needs the MacBook admission hook to accept it.
const nativeJobs = {
  'ci.yml': { 'build-macos': 'macos-26-intel', lint: 'macos-latest', 'api-compatibility': 'macos-26-intel' },
  'local-transcription-benchmark.yml': { 'benchmark-package': 'macos-latest' },
  'windows.yml': { 'portable-macos': 'macos-15' },
};
// Dedicated Omarchy pool (two runners): Linux builds that gain from a warm
// build directory. Each needs the Omarchy admission hook to accept it.
const linuxJobs = {
  'linux.yml': { 'linux-desktop': 'ubuntu-24.04' },
  'linux-local-runtime.yml': { runtime: 'ubuntu-24.04' },
  'windows.yml': { 'portable-linux': 'ubuntu-22.04' },
};
// iOS, keyboard, Release and journey jobs stay hosted so they run in parallel;
// tiny Linux jobs gain nothing from a warm cache.
const hostedJobs = {
  'ci.yml': {
    'core-journey-e2e': 'macos-26-intel', 'release-validation': 'macos-latest',
    'build-ios-swiftpm': 'macos-latest', 'build-ios-keyboard': 'macos-latest', 'paid-access-worker': 'ubuntu-latest',
  },
  'dependabot-policy-checks.yml': { policy: 'ubuntu-latest' },
  'desktop-icons.yml': { resources: 'ubuntu-24.04' },
};
const routedIds = (pool) => Object.entries(pool).flatMap(([file, ids]) => Object.keys(ids).map((id) => `${file}:${id}`));
function routedBy(variable) {
  const routed = [];
  for (const [file, source] of Object.entries(workflows)) {
    for (const [id, body] of Object.entries(jobs(source))) {
      if (body.includes(variable)) routed.push(`${file}:${id}`);
    }
  }
  return routed.sort();
}

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

test('only the selected Mac jobs share the reviewed Mac pool', () => {
  for (const [file, ids] of Object.entries(nativeJobs)) {
    const bodies = jobs(workflows[file]);
    for (const [id, fallback] of Object.entries(ids)) {
      const label = `${file}:${id}`;
      assertGuarded(bodies[id], reviewedMacs, fallback, label);
      assert.deepEqual(route(bodies[id], context(), { JSTI_NATIVE_RUNNER_LABELS: '["jsti-reviewed-local","macOS","X64"]' }),
        ['jsti-reviewed-local', 'macOS', 'X64'], `${label}: the pool label variable selects the runner`);
    }
  }
  assert.deepEqual(routedBy('JSTI_NATIVE_RUNNER_LABELS'), routedIds(nativeJobs).sort(),
    'adding a job to the MacBook needs its admission hook updated too');
});

test('only the selected Linux build jobs use the Omarchy pool', () => {
  for (const [file, ids] of Object.entries(linuxJobs)) {
    const bodies = jobs(workflows[file]);
    for (const [id, fallback] of Object.entries(ids)) {
      const label = `${file}:${id}`;
      assertGuarded(bodies[id], omarchy, fallback, label);
      assert.deepEqual(route(bodies[id], context(), { JSTI_LINUX_RUNNER_LABELS: '["ubuntu-24.04"]' }),
        ['ubuntu-24.04'], `${label}: the Linux label variable can return the pool to hosted`);
      assert.deepEqual(route(bodies[id], context(), { JSTI_NATIVE_RUNNER_LABELS: '["macos-15"]' }), omarchy,
        `${label}: the Mac pool variable never moves Linux jobs`);
      // Root job containers must hand the persistent work tree back to the runner user.
      assert.match(bodies[id], /- name: Record host work-tree owner\n        if: runner\.environment == 'self-hosted'\n/, label);
      assert.match(bodies[id], /- name: Restore host work-tree ownership\n        if: always\(\) && runner\.environment == 'self-hosted'\n/, label);
      assert.ok(bodies[id].indexOf('Record host work-tree owner') < bodies[id].indexOf('uses: actions/checkout'), label);
    }
  }
  assert.deepEqual(routedBy('JSTI_LINUX_RUNNER_LABELS'), routedIds(linuxJobs).sort(),
    'adding a job to Omarchy needs its admission hook updated too');
});

test('remaining Mac and light Linux jobs run on parallel hosted runners', () => {
  for (const [file, ids] of Object.entries(hostedJobs)) {
    const bodies = jobs(workflows[file]);
    for (const [id, label] of Object.entries(ids)) {
      assert.match(bodies[id], new RegExp(`^    runs-on: ${label.replaceAll('.', '\\.')}$`, 'm'), `${file}:${id}`);
    }
  }
});

test('self-hosted jobs keep a warm per-runner build directory instead of actions/cache', () => {
  for (const pool of [nativeJobs, linuxJobs]) {
    for (const [file, ids] of Object.entries(pool)) {
      const bodies = jobs(workflows[file]);
      for (const id of Object.keys(ids)) {
        const body = bodies[id];
        const label = `${file}:${id}`;
        const warm = body.indexOf('uses: ./.github/actions/warm-build-cache');
        assert.ok(warm > body.indexOf('uses: actions/checkout'), `${label}: warm cache must follow checkout`);
        const keys = [...body.matchAll(/^\s+- uses: actions\/cache@[^\n]+$/gm)];
        for (const match of body.matchAll(/- name: [^\n]+\n((?:        [^\n]*\n)*?)\s+uses: actions\/cache@/g)) {
          assert.match(match[1], /if: runner\.environment != 'self-hosted'/, `${label}: hosted-only actions/cache`);
        }
        assert.equal(keys.length, 0, `${label}: every actions/cache step is named and hosted-only`);
      }
    }
  }
  const keys = [];
  for (const source of Object.values(workflows)) {
    keys.push(...[...source.matchAll(/uses: \.\/\.github\/actions\/warm-build-cache\n\s+with:\n\s+key: (\S+)/g)].map((m) => m[1]));
  }
  assert.equal(new Set(keys).size, keys.length, 'each job needs its own warm cache key');
  const action = readFileSync(new URL('../../.github/actions/warm-build-cache/action.yml', import.meta.url), 'utf8');
  assert.match(action, /^      if: runner\.environment == 'self-hosted'$/m, 'hosted runners are untouched');
});

function warmCacheScript() {
  const action = readFileSync(new URL('../../.github/actions/warm-build-cache/action.yml', import.meta.url), 'utf8');
  const script = action.match(/      run: \|\n([\s\S]*)$/)[1];
  return script.split('\n').map((line) => line.slice(8)).join('\n');
}

function runWarmCache(work, { runner = 'omarchy-justspeaktoit', key = 'linux-desktop', paths = '.build', maxGb = '25' } = {}) {
  const workspace = join(work, 'justspeaktoit', 'justspeaktoit');
  mkdirSync(join(workspace, '.git', 'info'), { recursive: true });
  mkdirSync(join(work, '_temp'), { recursive: true });
  return spawnSync('bash', ['-c', warmCacheScript()], {
    encoding: 'utf8',
    env: {
      PATH: process.env.PATH, GITHUB_WORKSPACE: workspace, RUNNER_TEMP: join(work, '_temp'),
      JSTI_CACHE_KEY: key, JSTI_CACHE_PATHS: paths, JSTI_CACHE_MAX_GB: maxGb, JSTI_RUNNER_NAME: runner,
    },
  });
}

test('warm cache links build directories into a persistent per-runner, per-job directory', () => {
  const work = mkdtempSync(join(tmpdir(), 'jsti-warm-'));
  try {
    const workspace = join(work, 'justspeaktoit', 'justspeaktoit');
    const first = runWarmCache(work, { paths: '.build\nTooling/.build\n$RUNNER_TEMP/whisper-runtime-work\n' });
    assert.equal(first.status, 0, first.stderr);
    const cache = join(work, '.jsti-cache', 'omarchy-justspeaktoit', 'linux-desktop');
    for (const [link, name] of [[join(workspace, '.build'), '.build'], [join(workspace, 'Tooling/.build'), 'Tooling_.build'],
      [join(work, '_temp', 'whisper-runtime-work'), 'RUNNER_TEMP_whisper-runtime-work']]) {
      assert.ok(lstatSync(link).isSymbolicLink(), link);
      assert.equal(readlinkSync(link), join(cache, name));
    }
    assert.equal(readFileSync(join(workspace, '.git/info/exclude'), 'utf8'), '/.build\n/Tooling/.build\n');
    writeFileSync(join(cache, '.build', 'object.o'), 'warm');

    // checkout's clean removes only the link; the next job re-links the same state.
    rmSync(join(workspace, '.build'));
    assert.equal(runWarmCache(work, { paths: '.build' }).status, 0);
    assert.equal(readFileSync(join(workspace, '.build', 'object.o'), 'utf8'), 'warm');
    assert.equal(readFileSync(join(workspace, '.git/info/exclude'), 'utf8'), '/.build\n/Tooling/.build\n');

    // A concurrent second runner on the same machine never shares the directory.
    assert.equal(runWarmCache(work, { runner: 'omarchy-justspeaktoit-2' }).status, 0);
    assert.ok(existsSync(join(work, '.jsti-cache', 'omarchy-justspeaktoit-2', 'linux-desktop', '.build')));
    assert.ok(!existsSync(join(work, '.jsti-cache', 'omarchy-justspeaktoit-2', 'linux-desktop', '.build', 'object.o')));

    // Size guard: an oversized cache is wiped before use.
    const wiped = runWarmCache(work, { maxGb: '0' });
    assert.equal(wiped.status, 0, wiped.stderr);
    assert.match(wiped.stdout, /wiping it/);
    assert.ok(!existsSync(join(cache, '.build', 'object.o')));
    assert.ok(lstatSync(join(workspace, '.build')).isSymbolicLink());
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});

test('warm cache rejects keys and paths that could escape its directory', () => {
  const work = mkdtempSync(join(tmpdir(), 'jsti-warm-'));
  try {
    for (const options of [{ key: '../other' }, { key: '..' }, { key: '' }, { paths: '../outside' },
      { paths: '/etc' }, { paths: '$HOME/x' }, { paths: 'a/./b' }, { maxGb: 'lots' }]) {
      assert.notEqual(runWarmCache(work, options).status, 0, JSON.stringify(options));
    }
  } finally {
    rmSync(work, { recursive: true, force: true });
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
