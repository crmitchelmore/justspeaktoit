import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { assessCIGates as assessOracle } from '../verify-ci-gates.mjs';

const workflow = readFileSync(new URL('../../.github/workflows/ci.yml', import.meta.url), 'utf8');
const makefile = readFileSync(new URL('../../Makefile', import.meta.url), 'utf8');
const aggregate = workflow.slice(workflow.indexOf('\n  required-macos:'));
const jobBodies = Object.fromEntries([...workflow.matchAll(/^  ([a-z][a-z0-9-]+):\n([\s\S]*?)(?=^  [a-z][a-z0-9-]+:\n|$(?![\s\S]))/gm)]
  .map(([, id, body]) => [id, body]));
const appleJobs = [
  'build-macos', 'release-validation', 'api-compatibility', 'lint',
  'build-ios', 'build-ios-keyboard', 'core-journey-e2e', 'core-journey-fixture-ui',
];

function route(id, github, vars = {}) {
  const expression = jobBodies[id].match(/runs-on: \$\{\{ (.+) \}\}/)?.[1];
  assert.ok(expression, `${id}: must retain guarded routing`);
  return new Function('github', 'vars', 'fromJSON', `return (${expression});`)(github, vars, JSON.parse);
}

function routingContext(event = 'pull_request', repository = 'crmitchelmore/justspeaktoit', number = 1200) {
  return {
    event_name: event, ref: 'refs/heads/main', sha: 'merge-sha', repository: 'crmitchelmore/justspeaktoit',
    event: { number, pull_request: { head: { sha: 'head-sha', repo: { full_name: repository } } } },
  };
}

test('all compatible Apple CI lanes default to standard same-OS hosted Intel', () => {
  for (const id of appleJobs) {
    for (const event of ['pull_request', 'push']) {
      assert.deepEqual(route(id, routingContext(event)), ['macos-26-intel'], id);
    }
  }
  assert.doesNotMatch(workflow, /macos-latest|macos-26-(?:large|xlarge)/);
});

test('native pool still requires the exact reviewed source and trusted event', () => {
  for (const id of ['build-macos', 'api-compatibility']) {
    assert.deepEqual(route(id, routingContext(), { JSTI_NATIVE_APPROVED_SHA: 'head-sha' }),
      ['jsti-macos-build', 'macOS']);
    assert.deepEqual(route(id, routingContext(), { JSTI_NATIVE_APPROVED_SHA: 'merge-sha' }),
      ['macos-26-intel'], 'PR approval must match the source head, not merge SHA');
    assert.deepEqual(route(id, routingContext('pull_request', 'fork/repo'), { JSTI_NATIVE_APPROVED_SHA: 'head-sha' }),
      ['macos-26-intel'], 'forks cannot enter the native pool');
    assert.deepEqual(route(id, routingContext('push'), { JSTI_NATIVE_APPROVED_SHA: 'merge-sha' }),
      ['jsti-macos-build', 'macOS']);
    assert.deepEqual(route(id, { ...routingContext('push'), ref: 'refs/heads/feature' },
      { JSTI_NATIVE_APPROVED_SHA: 'merge-sha' }), ['macos-26-intel']);
    assert.deepEqual(route(id, routingContext('workflow_dispatch'), { JSTI_NATIVE_APPROVED_SHA: 'merge-sha' }),
      ['macos-26-intel']);
  }
});

test('standalone iOS SwiftPM compilation stays hosted with no new native admission', () => {
  const body = jobBodies['build-ios-swiftpm'];
  assert.match(body, /^\s+runs-on: macos-26-intel$/m);
  assert.match(body, /^\s+timeout-minutes: 30$/m);
  assert.match(body, /run: swift build --disable-dependency-cache --target SpeakiOSLib/);
  assert.doesNotMatch(body, /if:|jsti-macos-build|bravo-mini-local/);
});

test('historical owner-approved native route retains its source and event guards', () => {
  for (const id of appleJobs.filter(id => !['build-macos', 'api-compatibility'].includes(id))) {
    assert.deepEqual(route(id, routingContext('pull_request', 'crmitchelmore/justspeaktoit', 1038)),
      ['bravo-mini-local', 'macOS', 'ARM64']);
    assert.deepEqual(route(id, routingContext('pull_request', 'fork/repo', 1038)), ['macos-26-intel']);
    assert.deepEqual(route(id, routingContext('push', 'crmitchelmore/justspeaktoit', 1038)), ['macos-26-intel']);
  }
});

test('every Apple build cache isolates architecture, host and workspace, including restore prefixes', () => {
  const cacheLines = workflow.match(/^\s+(?:key:|restore-keys:).*(?:\n\s+\$\{\{[^\n]+)?/gm);
  assert.equal(cacheLines.length, 7, 'three Swift keys and restore prefixes plus the lint tooling key');
  for (const line of cacheLines) {
    assert.ok(line.includes('${{ runner.arch }}'), line);
    assert.ok(line.includes("${{ runner.environment == 'self-hosted' && runner.name || 'hosted' }}"), line);
    assert.ok(line.includes('${{ github.workspace }}'), line);
  }
});

const simulatorPreparation = jobBodies['build-ios'].match(
  /- name: Select iOS Simulator\n        run: \|\n([\s\S]*?)(?=\n      - name:)/,
)?.[1].replace(/^          /gm, '');
assert.ok(simulatorPreparation, 'simulator selection must reject unavailable devices');
const iosPreparation = readFileSync(new URL('../prepare-ios-ci.py', import.meta.url), 'utf8');

function prepareSimulator(devices) {
  const directory = mkdtempSync(join(tmpdir(), 'ios-ci-readiness-'));
  const environmentFile = join(directory, 'environment');
  try {
    const result = spawnSync('/bin/bash', ['-c', `
      xcrun() {
        if [[ "$*" == "simctl list devices available -j" ]]; then
          printf '%s\\n' "$SIM_DEVICES_JSON"
        else
          echo "Unexpected simulator command" >&2
          return 64
        fi
      }
      ${simulatorPreparation}
    `], {
      encoding: 'utf8',
      env: {
        ...process.env,
        GITHUB_ENV: environmentFile,
        SIM_DEVICES_JSON: JSON.stringify({ devices }),
      },
    });
    assert.ifError(result.error);
    return { ...result, environment: existsSync(environmentFile) ? readFileSync(environmentFile, 'utf8') : null };
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

test('iOS workloads are partitioned without extending budgets or dropping tests', () => {
  const body = jobBodies['build-ios'];
  assert.match(body, /^\s+timeout-minutes: 30$/m);
  assert.ok(body.indexOf('Select iOS Simulator') < body.indexOf('- name: Prepare iOS Simulator and Project'));
  assert.match(body, /python3 scripts\/prepare-ios-ci\.py "\$SIMULATOR_ID"/);
  assert.doesNotMatch(iosPreparation, /"swift"/);
  assert.match(iosPreparation, /\["tuist", "generate", "--no-open"\]/);
  assert.match(iosPreparation, /environment\["TUIST_IOS_KEYBOARD"\] = "1"/);
  assert.match(body, /xcodebuild test/);
  assert.match(body, /-only-testing:SpeakiOSTests/);
  assert.match(body, /-only-testing:SpeakiOSUITests/);
  assert.match(body, /verify-ios-test-evidence\.py/);
  const devices = jobBodies['build-ios-keyboard'];
  assert.match(devices, /^\s+timeout-minutes: 30$/m);
  assert.match(devices, /Build Keyboard Extension, hand-off shape/);
  assert.match(devices, /Build Keyboard Extension, direct-capture shape/);
  assert.match(devices, /Build watchOS App \(feature-flagged\)/);
  assert.match(devices, /TUIST_WATCH_APP=1 TUIST_IOS_KEYBOARD=1 TUIST_IOS_KEYBOARD_DIRECT_CAPTURE=0 tuist generate/);
  assert.match(devices, /-scheme JustSpeakWatchApp/);
  assert.match(devices, /-destination generic\/platform=watchOS/);
  assert.match(devices, /-scheme SpeakiOS/);
  assert.match(devices, /-destination generic\/platform=iOS/);
  assert.match(aggregate, /^\s+- build-ios-swiftpm$/m);
  assert.match(aggregate, /needs\.build-ios-swiftpm\.result != 'success'/);
});

test('iOS selection prefers an available Pro before starting preparation', () => {
  const result = prepareSimulator({ runtime: [
    { name: 'iPhone 17 Pro', udid: 'unavailable', isAvailable: false },
    { name: 'iPhone 16', udid: 'fallback', isAvailable: true },
    { name: 'iPhone 17 Pro', udid: 'preferred', isAvailable: true },
  ] });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.environment, 'SIMULATOR_ID=preferred\n');
});

test('iOS preparation falls back to an available iPhone, not a watch', () => {
  const result = prepareSimulator({ runtime: [
    { name: 'Apple Watch', udid: 'watch', isAvailable: true },
    { name: 'iPhone 16', udid: 'fallback', isAvailable: true },
  ] });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.environment, 'SIMULATOR_ID=fallback\n');
});

test('missing simulator explicitly fails instead of publishing a usable destination', () => {
  const missing = prepareSimulator({ runtime: [] });
  assert.equal(missing.status, 1);
  assert.match(missing.stdout, /::error::No available iPhone simulator/);
  assert.doesNotMatch(missing.stdout, /READINESS/);
  assert.equal(missing.environment, null);
});

const predicate = aggregate.match(/name: Reject unsuccessful CI gates\n        if: >-\n([\s\S]*?)\n        env:/)?.[1];
assert.ok(predicate, 'must test the actual workflow rejection predicate');
// GitHub property names permit hyphens; adapt those paths for local evaluation.
// The predicate uses only boolean/string comparisons, with no Actions-specific
// coercions. This tests the shipped predicate against the diagnostic oracle.
const evaluatePredicate = new Function('needs', 'github', 'always', `return (${
  predicate.replace(/\bneeds((?:\.[a-zA-Z0-9_-]+)+)/g, (_, path) =>
    'needs' + path.split('.').slice(1).map(key => `?.[${JSON.stringify(key)}]`).join(''))
});`);

function assessCIGates(needs, event) {
  const errors = assessOracle(needs, event);
  assert.equal(evaluatePredicate(needs, { event_name: event }, () => true), errors.length > 0,
    'workflow predicate must agree with fixture expectations');
  return errors;
}

test('aggregate never checks out or executes repository helper code', () => {
  assert.doesNotMatch(aggregate, /uses:|run:.*scripts\//);
  assert.match(aggregate, /permissions: \{\}/);
  assert.match(aggregate, /exit 1/);
});

test('tooling gate delegates to the complete local discovery target', () => {
  assert.match(workflow, /- name: SwiftLint\n\s+run: make lint/);
  assert.match(workflow, /- name: Check tooling Package\.resolved drift\n\s+run: git diff --exit-code/);
  assert.match(workflow, /- name: Test CI and release gates\n\s+run: make test-tooling/);
  assert.match(makefile, /node --test scripts\/tests\/\*\.test\.mjs/);
  assert.match(makefile, /^\tnode --test \.github\/scripts\/dependabot-merge\.test\.mjs$/m);
  assert.match(makefile, /ruby scripts\/tests\/release_apple_test\.rb/);
  assert.match(makefile, /ruby scripts\/tests\/create_ios_app_store_profile_test\.rb/);
  assert.match(makefile, /python3 -m unittest discover -s scripts\/tests -p 'test_\*\.py' -v/);
  assert.match(makefile, /python3 scripts\/generate-release-train-config\.py --check/);
  assert.doesNotMatch(workflow, /Tests\/ReleaseNotesTests|scripts\/release-train\.test\.mjs/);
});

const platformPythonTestRoots = [
  'scripts/linux-local-runtime', 'scripts/windows-local-runtime', 'scripts/windows-bundle',
  'scripts/windows-cross', 'scripts/windows-cloudkit', 'scripts/windows-package',
];
const platformPythonCommand = root => `\tpython3 -B -m unittest discover -s ${root} -p 'test_*.py' -v\n`;

function toolingTestIsDiscovered(path, trackedFiles, makefileText) {
  const toolingRecipe = makefileText.match(/^test-tooling:[^\n]*\n((?:\t[^\n]*\n)*)/m)?.[1] ?? '';
  // `unittest discover -s <root>` loads identifier-named test_*.py modules and
  // recurses only into regular packages (directories with __init__.py) below the start.
  const discoveredByUnittest = (path, root) => {
    if (!path.startsWith(`${root}/`)) return false;
    const match = path.slice(root.length + 1).match(/^((?:[^/]+\/)*)test_\w*\.py$/);
    if (!match) return false;
    let directory = root;
    for (const part of match[1].split('/').filter(Boolean)) {
      directory += `/${part}`;
      if (!trackedFiles.has(`${directory}/__init__.py`)) return false;
    }
    return true;
  };
  return /^scripts\/tests\/[^/]+\.test\.mjs$/.test(path)
    || discoveredByUnittest(path, 'scripts/tests')
    || platformPythonTestRoots.some(root => toolingRecipe.includes(platformPythonCommand(root))
      && discoveredByUnittest(path, root))
    || (path === '.github/scripts/dependabot-merge.test.mjs'
      && makefileText.includes(`\tnode --test ${path}\n`))
    || (/^scripts\/tests\/[^/]+_test\.rb$/.test(path) && makefileText.includes(`\truby ${path}\n`));
}

test('dependency policy discovery requires its exact execution command', () => {
  const path = '.github/scripts/dependabot-merge.test.mjs';
  const tracked = new Set([path]);
  assert.equal(toolingTestIsDiscovered(path, tracked, makefile), true);
  const withoutExecution = makefile.replace(`\tnode --test ${path}\n`, '');
  assert.equal(toolingTestIsDiscovered(path, tracked, withoutExecution), false,
    'listing or tracking the dependency test alone must not count as execution');
  assert.equal(toolingTestIsDiscovered('.github/scripts/unwired.test.mjs', tracked, makefile), false,
    'other tests beside the dependency policy still need explicit execution');
});

test('platform Python discovery requires each actual execution command', () => {
  for (const root of platformPythonTestRoots) {
    const path = `${root}/test_fixture.py`;
    const tracked = new Set([path]);
    const command = platformPythonCommand(root);
    assert.equal(toolingTestIsDiscovered(path, tracked, makefile), true, root);
    assert.equal(toolingTestIsDiscovered(path, tracked, makefile.replace(command, '')), false,
      `${root}: removing the command must remove coverage`);
    assert.equal(toolingTestIsDiscovered(path, tracked, makefile.replace(command, `\t# ${command.trim()}\n`)), false,
      `${root}: a commented command must not count as execution`);
    assert.equal(toolingTestIsDiscovered(path, tracked, `${makefile.replace(command, '')}\nunwired-target:\n${command}`), false,
      `${root}: a command in an uncalled target must not count as execution`);
    assert.equal(toolingTestIsDiscovered(`${root}/nested/test_fixture.py`, tracked, makefile), false,
      `${root}: unittest does not recurse into a directory without __init__.py`);
    tracked.add(`${root}/nested/__init__.py`);
    assert.equal(toolingTestIsDiscovered(`${root}/nested/test_fixture.py`, tracked, makefile), true);
  }
  assert.equal(toolingTestIsDiscovered('scripts/unwired/test_fixture.py', new Set(), makefile), false,
    'another tooling directory needs its own execution command');
});

test('every tracked tooling test is discovered by make test-tooling', () => {
  const root = fileURLToPath(new URL('../../', import.meta.url));
  const tracked = execFileSync('git', ['ls-files', '-z'], { cwd: root, encoding: 'utf8' }).split('\0');
  const toolingTests = tracked.filter(path => /\.test\.[cm]?js$|_test\.rb$|(^|\/)test_[^/]*\.py$/.test(path)
    // The website package runs its own suite via `npm test` in deploy-landing-page.yml.
    && !path.startsWith('landing-page/'));
  assert.ok(toolingTests.length > 0, 'must find the tracked tooling tests');
  const trackedFiles = new Set(tracked);
  for (const path of toolingTests) {
    assert.ok(toolingTestIsDiscovered(path, trackedFiles, makefile), `${path} is not run by make test-tooling`);
  }
});

function passing() {
  return Object.fromEntries([
    'build-macos', 'build-ios', 'build-ios-swiftpm', 'build-ios-keyboard', 'lint',
    'release-paths', 'release-validation', 'core-journey-e2e',
    'core-journey-fixture-ui', 'api-compatibility',
  ].map(id => [id, { result: 'success', outputs: { package: 'true', 'core-journey': 'true' } }]));
}

test('accepts all successful pull-request gates', () => {
  assert.deepEqual(assessCIGates(passing(), 'pull_request'), []);
});

for (const id of Object.keys(passing())) {
  for (const status of ['failure', 'cancelled', 'skipped', undefined]) {
    test(`blocks ${id} when ${status ?? 'missing'}`, () => {
      const needs = passing();
      needs[id].result = status;
      assert.ok(assessCIGates(needs, 'pull_request').length > 0);
    });
  }
}

test('permits only path-excluded PR gates to skip', () => {
  const needs = passing();
  needs['release-paths'].outputs = { package: 'false', 'core-journey': 'false' };
  for (const id of ['release-validation', 'core-journey-e2e', 'core-journey-fixture-ui']) {
    needs[id].result = 'skipped';
  }
  assert.deepEqual(assessCIGates(needs, 'pull_request'), []);
  assert.ok(assessCIGates(needs, 'push').length > 0, 'main cannot skip gates');
  needs['core-journey-e2e'].result = 'failure';
  assert.ok(assessCIGates(needs, 'pull_request').length > 0);
});

test('blocks missing path detection outputs', () => {
  const needs = passing();
  needs['release-paths'].outputs = {};
  assert.ok(assessCIGates(needs, 'pull_request').length > 0);
});

test('permits API compatibility skip only on main push', () => {
  const needs = passing();
  needs['api-compatibility'].result = 'skipped';
  assert.deepEqual(assessCIGates(needs, 'push'), []);
  assert.ok(assessCIGates(needs, 'pull_request').length > 0);
});
