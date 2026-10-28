import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { assessCIGates as assessOracle } from '../verify-ci-gates.mjs';

const workflow = readFileSync(new URL('../../.github/workflows/ci.yml', import.meta.url), 'utf8');
const tesslWorkflow = readFileSync(
  new URL('../../.github/workflows/tessl-code-review.yml', import.meta.url),
  'utf8',
);
const makefile = readFileSync(new URL('../../Makefile', import.meta.url), 'utf8');
const aggregate = workflow.slice(workflow.indexOf('\n  required-macos:'));
const jobBodies = Object.fromEntries([...workflow.matchAll(/^  ([a-z][a-z0-9-]+):\n([\s\S]*?)(?=^  [a-z][a-z0-9-]+:\n|$(?![\s\S]))/gm)]
  .map(([, id, body]) => [id, body]));
const nativeEligibleJobs = [
  'build-macos', 'release-validation', 'api-compatibility', 'lint', 'core-journey-e2e',
];
const journeyStages = readFileSync(new URL('../run-core-journey-stages.py', import.meta.url), 'utf8');

test('product checks cover stacked pull requests without broadening push or credential permissions', () => {
  for (const name of ['ci', 'windows', 'linux']) {
    const source = readFileSync(new URL(`../../.github/workflows/${name}.yml`, import.meta.url), 'utf8');
    assert.match(source, /^  push:\n    branches: \[main\]$/m, `${name}: pushes must remain main-only`);
    const pullRequest = source.match(/^  pull_request:[ \t]*\n((?: {4}[^\n]*\n|\n)*)/m);
    assert.ok(pullRequest, `${name}: ordinary pull-request checks must exist`);
    assert.doesNotMatch(pullRequest[1], /^\s+branches(?:-ignore)?:/m,
      `${name}: non-main target branches must receive product checks`);
    assert.doesNotMatch(source, /^  pull_request_target:/m, `${name}: no privileged PR event`);
    if (name !== 'ci') {
      assert.match(pullRequest[1], /^    paths:$/m, `${name}: retain product path gates`);
    }
  }
});

test('desktop native dependency changes select every native and cross-build workflow', () => {
  for (const name of ['windows', 'linux', 'windows-arm64', 'windows-cross-proof']) {
    const source = readFileSync(new URL(`../../.github/workflows/${name}.yml`, import.meta.url), 'utf8');
    for (const event of ['push', 'pull_request']) {
      const trigger = source.match(new RegExp(`^  ${event}:\\n((?: {4}[^\\n]*\\n|\\n)*)`, 'm'));
      assert.ok(trigger, `${name}: ${event} must exist`);
      for (const target of ['CLlamaCpp', 'CMigrationArchive', 'CRecordingFileSupport']) {
        assert.ok(trigger[1].includes(`      - Sources/${target}/**\n`),
          `${name}: ${event} must include native dependency ${target}`);
      }
    }
  }
});

test('journey cold preparation and actual runtime have separate finite budgets and always-uploaded evidence', () => {
  const swift = jobBodies['core-journey-e2e'];
  const ui = jobBodies['core-journey-fixture-ui'];
  assert.match(swift, /^\s+timeout-minutes: 40$/m);
  assert.match(ui, /^\s+timeout-minutes: 42$/m);
  assert.match(swift, /timeout-minutes: 17\n\s+run: scripts\/run-core-journey-e2e.sh --phase build/);
  assert.match(swift, /timeout-minutes: 10\n\s+run: scripts\/run-core-journey-e2e.sh --phase test/);
  assert.ok(swift.indexOf('--phase build') < swift.indexOf('--phase test'));
  for (const phase of ['setup', 'build', 'test']) {
    assert.match(ui, new RegExp(`run: python3 scripts/run-core-journey-stages.py ui --phase ${phase}`));
  }
  assert.ok(ui.indexOf('--phase setup') < ui.indexOf('--phase build'));
  assert.ok(ui.indexOf('--phase build') < ui.indexOf('--phase test'));
  for (const body of [swift, ui]) {
    assert.doesNotMatch(body, /continue-on-error:|if:.*(?:failure|cancelled)/);
    assert.match(body, /if: always\(\)\n\s+timeout-minutes: 3\n\s+uses: actions\/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7\.0\.2/);
    assert.match(body, /if-no-files-found: error/);
    assert.match(body, /uses: actions\/checkout@v7.0.1/);
    assert.doesNotMatch(body, /ref:.*head|workflow_dispatch|retry|--skip.*test/);
  }
  assert.match(ui, /include-hidden-files: true/);
  assert.match(ui, /path: \|\n\s+\.artifacts\/core-journey-fixture-ui\n\s+!\.artifacts\/core-journey-fixture-ui\/DerivedData/);
  assert.match(journeyStages, /BUILD_BUDGET = 900/);
  assert.match(journeyStages, /SETUP_BUDGET = 300/);
  assert.match(journeyStages, /RUNTIME_BUDGET = \{"swift": 480, "ui": 600\}/);
  assert.match(journeyStages, /RECEIPT_BUDGET = 60/);
  assert.match(journeyStages, /"swift", "build", "--build-tests", "--enable-code-coverage"/);
  assert.match(journeyStages, /"swift", "test", "--skip-build", "--disable-automatic-resolution",\s+"--enable-code-coverage"/);
  assert.match(journeyStages, /"xcodebuild", "build-for-testing"/);
  assert.match(journeyStages, /"xcodebuild", "test-without-building", "-xctestrun"/);
  assert.match(journeyStages, /"GITHUB_SHA"/);
  assert.match(journeyStages, /"Apple Swift"/);
  assert.doesNotMatch(journeyStages, /CORE_JOURNEY_BUDGET_SECONDS|--skip-test|--skip-testing/);
  for (const path of ['scripts/run-core-journey-stages.py', 'scripts/tests/test_core_journey_stages.py',
    'scripts/tests/verify-ci-gates.test.mjs']) {
    assert.ok(jobBodies['release-paths'].includes(`- '${path}'`), `path filter must include ${path}`);
  }
});

test('macOS Debug and Core Journey share coverage instrumentation and cache keys', () => {
  const body = jobBodies['build-macos'];
  const journey = jobBodies['core-journey-e2e'];
  for (const pattern of [/^\s+key:\s*(.+)$/m, /restore-keys:\s*\|\s*\n\s+([^\n]+)/]) {
    const producer = body.match(pattern);
    const consumer = journey.match(pattern);
    assert.ok(producer && consumer, 'Debug and Core Journey must declare matching cache keys');
    assert.equal(consumer[1].trim(), producer[1].trim());
  }
  assert.match(body, /^\s+timeout-minutes: 30$/m);
  assert.match(body, /name: Build\n(?:\s+#[^\n]*\n)*\s+run: SWIFT_FLAGS=--enable-code-coverage make build/);
  assert.match(body, /name: Test \(Debug\)\n(?:\s+id: [\w-]+\n)?\s+run: python3 scripts\/with-test-keychain.py swift test --enable-code-coverage/);
  assert.ok(body.indexOf('name: Build') < body.indexOf('name: Test (Debug)'),
    'Build must run before Test (Debug) so the coverage-enabled cache is already warm');
  assert.ok(body.indexOf('name: Test (Debug)') < body.indexOf('name: Build SpeakCore (App Store flavour)'),
    'App Store flavour rebuild must stay after tests, not before');
  assert.doesNotMatch(body, /\n\s+run: make build\n/, 'Build step must not regress to an uninstrumented build');
  // Non-test steps unaffected: still a real build, no dropped checks.
  assert.match(body, /name: Verify brand asset sizes and appearance variants/);
  assert.match(body, /name: Check Package.resolved drift/);
  assert.match(body, /name: Report Coverage/);
});

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

test('Apple CI routing keeps UI execution on hosted ARM and compilation on Intel', () => {
  for (const id of ['build-ios', 'core-journey-fixture-ui']) {
    assert.match(jobBodies[id], /^\s+runs-on: macos-latest$/m, id);
  }
  for (const id of ['build-ios-swiftpm', 'build-ios-test-products', 'build-ios-keyboard']) {
    assert.match(jobBodies[id], /^\s+runs-on: macos-26-intel$/m, id);
  }
  assert.doesNotMatch(workflow, /macos-26-(?:large|xlarge)/);
});

test('native pool still requires the exact reviewed source and trusted event', () => {
  for (const id of nativeEligibleJobs) {
    // Restore-only gates must share build-macos's hosted architecture to hit its cache.
    const fallback = ['macos-26-intel'];
    assert.deepEqual(route(id, routingContext(), { JSTI_NATIVE_APPROVED_SHA: 'head-sha' }),
      ['jsti-macos-build', 'macOS']);
    assert.deepEqual(route(id, routingContext(), {
      JSTI_NATIVE_APPROVED_SHA: 'head-sha',
      JSTI_NATIVE_RUNNER_LABELS: '["mac-mini-3-local","macOS"]',
    }), ['mac-mini-3-local', 'macOS']);
    assert.deepEqual(route(id, routingContext(), { JSTI_NATIVE_APPROVED_SHA: 'merge-sha' }),
      fallback, 'PR approval must match the source head, not merge SHA');
    assert.deepEqual(route(id, routingContext()), fallback, 'unset approval must stay hosted');
    assert.deepEqual(route(id, routingContext(), { JSTI_NATIVE_APPROVED_SHA: 'stale-sha' }), fallback);
    assert.deepEqual(route(id, routingContext('pull_request', 'fork/repo'), { JSTI_NATIVE_APPROVED_SHA: 'head-sha' }),
      fallback, 'forks cannot enter the native pool');
    assert.deepEqual(route(id, routingContext('push'), { JSTI_NATIVE_APPROVED_SHA: 'merge-sha' }),
      ['jsti-macos-build', 'macOS']);
    assert.deepEqual(route(id, routingContext('push')), fallback);
    assert.deepEqual(route(id, routingContext('push'), { JSTI_NATIVE_APPROVED_SHA: 'stale-sha' }), fallback);
    assert.deepEqual(route(id, { ...routingContext('push'), ref: 'refs/heads/feature' },
      { JSTI_NATIVE_APPROVED_SHA: 'merge-sha' }), fallback);
    assert.deepEqual(route(id, routingContext('workflow_dispatch'), { JSTI_NATIVE_APPROVED_SHA: 'merge-sha' }),
      fallback);
  }
});

test('standalone iOS SwiftPM compilation stays hosted with no new native admission', () => {
  const body = jobBodies['build-ios-swiftpm'];
  assert.match(body, /^\s+runs-on: macos-26-intel$/m);
  assert.match(body, /^\s+timeout-minutes: 30$/m);
  assert.match(body, /run: swift build --disable-dependency-cache --target SpeakiOSLib/);
  assert.doesNotMatch(body, /if:|jsti-macos-build|bravo-mini-local/);
});

test('UI jobs cannot be admitted to a native runner by repository variables', () => {
  for (const id of ['build-ios', 'core-journey-fixture-ui']) {
    assert.doesNotMatch(jobBodies[id], /JSTI_NATIVE|jsti-macos-build|bravo-mini-local/, id);
  }
});

test('Tessl is on demand and preserves trusted-author secret restrictions', () => {
  assert.doesNotMatch(tesslWorkflow, /^  pull_request:/m);
  assert.match(tesslWorkflow, /github\.event_name == 'issue_comment'/);
  assert.match(tesslWorkflow, /github\.event_name == 'workflow_dispatch'/);
  assert.match(tesslWorkflow, /allowed-associations: OWNER,MEMBER,COLLABORATOR/);
  assert.doesNotMatch(tesslWorkflow, /pull_request_target/);
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
  /- name: Create owned iOS Simulator matching the selected configuration\n        run: \|\n([\s\S]*?)(?=\n      - name:)/,
)?.[1];
assert.ok(simulatorPreparation, 'owned simulator creation must precede preparation');
const iosPreparation = readFileSync(new URL('../prepare-ios-ci.py', import.meta.url), 'utf8');
const ownedSimulator = fileURLToPath(new URL('../owned-ios-ci-simulator.py', import.meta.url));

function prepareSimulator(devices) {
  // Execute the canonical selector without invoking simctl or creating devices.
  const result = spawnSync('python3', ['-B', '-c', `
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("owned_simulator", sys.argv[1])
owned = importlib.util.module_from_spec(spec)
spec.loader.exec_module(owned)
print(json.dumps(owned.selected_configuration(json.loads(sys.argv[2]))))
`, ownedSimulator, JSON.stringify(devices)], { encoding: 'utf8' });
  assert.ifError(result.error);
  return result;
}

test('iOS workloads are partitioned without extending budgets or dropping tests', () => {
  const body = jobBodies['build-ios'];
  assert.match(body, /^\s+timeout-minutes: 30$/m);
  assert.ok(body.indexOf('Create owned iOS Simulator') < body.indexOf('- name: Prepare iOS Simulator'));
  assert.match(body, /python3 scripts\/prepare-ios-ci\.py "\$SIMULATOR_ID"/);
  assert.match(simulatorPreparation, /python3 scripts\/owned-ios-ci-simulator\.py create/);
  assert.match(simulatorPreparation, /--receipt "\$RUNNER_TEMP\/owned-ios-simulator\.json" --github-env "\$GITHUB_ENV"/);
  assert.match(simulatorPreparation, /--owner "\$GITHUB_RUN_ID:\$GITHUB_RUN_ATTEMPT:\$GITHUB_JOB"/);
  assert.match(body, /name: Remove only the simulator created by this job\n\s+if: always\(\)/);
  assert.match(body, /owned-ios-ci-simulator\.py cleanup/);
  assert.match(body, /\$\{\{ runner.temp \}\}\/owned-ios-simulator\.json/);
  assert.doesNotMatch(iosPreparation, /"swift"/);
  assert.doesNotMatch(iosPreparation, /"tuist"/);
  assert.match(iosPreparation, /boot.wait\(timeout=600\)/);
  assert.match(body, /xcodebuild test-without-building/);
  assert.match(body, /needs: build-ios-test-products/);
  assert.match(body, /artifact-ids: \$\{\{ needs.build-ios-test-products.outputs.artifact-id \}\}/);
  assert.match(body, /scripts\/ios-test-products.py unpack/);
  assert.match(body, /-testProductsPath "\$RUNNER_TEMP\/ios-test-products\/SpeakiOS.xctestproducts"/);
  assert.match(body, /name: Upload complete iOS XCTest log separately\n\s+if: always\(\)/);
  const products = jobBodies['build-ios-test-products'];
  assert.match(products, /^\s+runs-on: macos-26-intel$/m);
  assert.match(products, /^\s+timeout-minutes: 30$/m);
  assert.match(products, /TUIST_IOS_KEYBOARD=1 tuist generate/);
  assert.match(products, /xcodebuild build-for-testing/);
  assert.match(products, /-only-testing:SpeakiOSTests/);
  assert.match(products, /-only-testing:SpeakiOSUITests/);
  assert.match(products, /ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO/);
  assert.match(products, /scripts\/ios-test-products.py pack/);
  assert.doesNotMatch(products, /simctl|bravo-mini-local|jsti-macos-build/);
  assert.match(aggregate, /^\s+- build-ios-test-products$/m);
  assert.match(aggregate, /needs\.build-ios-test-products\.result != 'success'/);
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
    { name: 'iPhone 17 Pro', udid: 'unavailable', deviceTypeIdentifier: 'unavailable-type', isAvailable: false },
    { name: 'iPhone 16', udid: 'fallback', deviceTypeIdentifier: 'fallback-type', isAvailable: true },
    { name: 'iPhone 17 Pro', udid: 'preferred', deviceTypeIdentifier: 'preferred-type', isAvailable: true },
  ] });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), ['runtime', 'preferred-type']);
});

test('iOS preparation falls back to an available iPhone, not a watch', () => {
  const result = prepareSimulator({ runtime: [
    { name: 'Apple Watch', udid: 'watch', isAvailable: true },
    { name: 'iPhone 16', udid: 'fallback', deviceTypeIdentifier: 'fallback-type', isAvailable: true },
  ] });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), ['runtime', 'fallback-type']);
});

test('missing simulator explicitly fails instead of publishing a usable destination', () => {
  const missing = prepareSimulator({ runtime: [] });
  assert.equal(missing.status, 1);
  assert.match(missing.stderr, /No available iPhone simulator configuration/);
  assert.doesNotMatch(missing.stdout, /READINESS/);
  assert.equal(missing.stdout, '');
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
  'scripts/windows-cross', 'scripts/windows-cloudkit', 'scripts/windows-package', 'scripts/migration',
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
    'build-macos', 'build-ios', 'build-ios-swiftpm', 'build-ios-test-products', 'build-ios-keyboard', 'lint',
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
