import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { assessCIGates as assessOracle, gateJobs } from '../verify-ci-gates.mjs';

const workflow = readFileSync(new URL('../../.github/workflows/ci.yml', import.meta.url), 'utf8');
const tesslWorkflow = readFileSync(
  new URL('../../.github/workflows/tessl-code-review.yml', import.meta.url),
  'utf8',
);
const makefile = readFileSync(new URL('../../Makefile', import.meta.url), 'utf8');
const aggregate = workflow.slice(workflow.indexOf('\n  gate:'), workflow.indexOf('\n  required-macos:'));
const jobBodies = Object.fromEntries([...workflow.matchAll(/^  ([a-z][a-z0-9-]+):\n([\s\S]*?)(?=^  [a-z][a-z0-9-]+:\n|$(?![\s\S]))/gm)]
  .map(([, id, body]) => [id, body]));
const nativeEligibleJobs = [
  'build-macos', 'release-validation', 'api-compatibility', 'core-journey-e2e',
  'build-ios-keyboard',
];
// Hosted macOS concurrency is a fixed per-account cap shared by Intel and ARM,
// so Intel adds no capacity and only slows jobs: every hosted fallback is ARM.
const hostedFallback = () => 'macos-latest';
const journeyStages = readFileSync(new URL('../run-core-journey-stages.py', import.meta.url), 'utf8');

test('product checks cover stacked pull requests without broadening push or credential permissions', () => {
  for (const name of ['ci', 'linux']) {
    const source = readFileSync(new URL(`../../.github/workflows/${name}.yml`, import.meta.url), 'utf8');
    // A batch runs ci.yml once, through its pull request, not again on push.
    const pushes = name === 'ci' ? /^  push:\n    branches: \[main\]$/m : /^  push:\n    branches: \[main, 'merge-batch\/\*\*'\]$/m;
    assert.match(source, pushes, `${name}: pushes must stay limited to main (and merge batches outside ci.yml)`);
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
  for (const name of ['linux', 'windows-arm64', 'windows-cross-proof']) {
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
  assert.match(ui, /^\s+timeout-minutes: 47$/m);
  assert.match(ui, /timeout-minutes: 11\n\s+run: python3 scripts\/run-core-journey-stages.py ui --phase setup/);
  assert.match(swift, /timeout-minutes: 17\n\s+run: scripts\/run-core-journey-e2e.sh --phase build/);
  assert.match(swift, /timeout-minutes: 10\n\s+run: python3 scripts\/with-test-keychain.py bash scripts\/run-core-journey-e2e.sh --phase test/);
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
    assert.match(body, /uses: actions\/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7\.0\.1/);
    assert.doesNotMatch(body, /ref:.*head|workflow_dispatch|retry|--skip.*test/);
  }
  assert.match(ui, /include-hidden-files: true/);
  assert.match(ui, /path: \|\n\s+\.artifacts\/core-journey-fixture-ui\n\s+!\.artifacts\/core-journey-fixture-ui\/DerivedData/);
  assert.match(journeyStages, /BUILD_BUDGET = 900/);
  assert.match(journeyStages, /SETUP_BUDGET = 600/);
  assert.match(journeyStages, /RUNTIME_BUDGET = \{"swift": 480, "ui": 600\}/);
  assert.match(journeyStages, /RECEIPT_BUDGET = 60/);
  assert.match(journeyStages, /"swift", "build", "--build-tests", "--enable-code-coverage"/);
  assert.match(journeyStages, /"swift", "test", "--skip-build", "--disable-automatic-resolution",\s+"--enable-code-coverage"/);
  assert.match(journeyStages, /"xcodebuild", "build-for-testing"/);
  assert.match(journeyStages, /"xcodebuild", "test-without-building", "-xctestrun"/);
  assert.match(journeyStages, /"GITHUB_SHA"/);
  assert.match(journeyStages, /"Apple Swift"/);
  assert.doesNotMatch(journeyStages, /CORE_JOURNEY_BUDGET_SECONDS|--skip-test|--skip-testing/);
  for (const body of [swift, ui]) assert.match(body, /if: needs\.release-paths\.outputs\.full == 'true'/);
});

test('Debug dependency resolution bypasses shared repositories in commands and recorded diagnostics', () => {
  const body = jobBodies['build-macos'];
  const commandLines = body.split('\n').filter((line) => !line.trimStart().startsWith('#'));
  const commands = commandLines.flatMap((line) => line.match(/\bswift (?:build|test) [^\n]+/g) ?? []);
  // make build receives the same option through SWIFT_FLAGS; the four direct
  // invocations include tests, isolated diagnostics and coverage path queries.
  assert.equal(commands.length, 4);
  for (const command of commands) {
    assert.ok(command.includes('--disable-dependency-cache'), command);
  }
  assert.equal((body.match(/"--disable-dependency-cache"/g) ?? []).length, 2,
    'both recorded History argv values must describe the actual diagnostic');
  assert.match(body, /^    timeout-minutes: 45$/m);
  assert.doesNotMatch(body, /swift package (?:reset|clean)|rm -rf.*\.build/);
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
  assert.match(body, /^\s+timeout-minutes: 45$/m);
  assert.match(body, /name: Build\n\s+id: build\n(?:\s+#[^\n]*\n)*\s+run: SWIFT_FLAGS="--enable-code-coverage --disable-dependency-cache" make build/);
  assert.match(body, /name: Test \(Debug\)\n(?:\s+id: [\w-]+\n)?[\s\S]*?python3 scripts\/with-test-keychain.py python3 scripts\/retry-xctest-crash.py swift test --enable-code-coverage --disable-dependency-cache "\$\{args\[@\]\}"/);
  assert.ok(body.indexOf('name: Build') < body.indexOf('name: Test (Debug)'),
    'Build must run before Test (Debug) so the coverage-enabled cache is already warm');
  assert.doesNotMatch(body, /-DAPP_STORE/,
    'the App Store flavour compile invalidates the Debug cache, so it runs in release-validation');
  assert.match(jobBodies['release-validation'],
    /name: Build SpeakCore \(App Store flavour\)\n(?:\s+#[^\n]*\n)*\s+run: >-\n\s+swift build --scratch-path "\$RUNNER_TEMP\/app-store-flavour"\n\s+-Xswiftc -DAPP_STORE --target SpeakCore/);
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

test('Apple CI routing keeps every hosted macOS job on ARM', () => {
  for (const id of ['build-ios', 'core-journey-fixture-ui']) {
    assert.match(jobBodies[id], /^\s+runs-on: macos-latest$/m, id);
  }
  for (const id of ['build-ios-test-products']) {
    assert.match(jobBodies[id], /^\s+runs-on: macos-latest$/m, id);
  }
  assert.doesNotMatch(workflow, /macos-26-(?:large|xlarge)/);
  assert.doesNotMatch(workflow, /-intel/);
  for (const id of nativeEligibleJobs) {
    const hosted = hostedFallback(id);
    assert.ok(jobBodies[id].includes(`|| '["${hosted}"]') }}`), id);
  }
});

test('native pool still requires the exact reviewed source and trusted event', () => {
  for (const id of nativeEligibleJobs) {
    // Restore-only gates must share build-macos's hosted architecture to hit its cache.
    const fallback = [hostedFallback(id)];
    assert.deepEqual(route(id, routingContext(), { JSTI_NATIVE_APPROVED_SHA: 'head-sha' }),
      ['jsti-reviewed-local', 'macOS']);
    assert.deepEqual(route(id, routingContext(), {
      JSTI_NATIVE_APPROVED_SHA: 'head-sha',
      JSTI_NATIVE_RUNNER_LABELS: '["jsti-reviewed-local","macOS","X64"]',
    }), ['jsti-reviewed-local', 'macOS', 'X64']);
    assert.deepEqual(route(id, routingContext(), { JSTI_NATIVE_APPROVED_SHA: 'merge-sha' }),
      fallback, 'PR approval must match the source head, not merge SHA');
    assert.deepEqual(route(id, routingContext()), fallback, 'unset approval must stay hosted');
    assert.deepEqual(route(id, routingContext(), { JSTI_NATIVE_APPROVED_SHA: 'stale-sha' }), fallback);
    assert.deepEqual(route(id, routingContext('pull_request', 'fork/repo'), { JSTI_NATIVE_APPROVED_SHA: 'head-sha' }),
      fallback, 'forks cannot enter the native pool');
    assert.deepEqual(route(id, routingContext('push'), { JSTI_NATIVE_APPROVED_SHA: 'merge-sha' }),
      ['jsti-reviewed-local', 'macOS']);
    assert.deepEqual(route(id, routingContext('push')), fallback);
    assert.deepEqual(route(id, routingContext('push'), { JSTI_NATIVE_APPROVED_SHA: 'stale-sha' }), fallback);
    assert.deepEqual(route(id, { ...routingContext('push'), ref: 'refs/heads/feature' },
      { JSTI_NATIVE_APPROVED_SHA: 'merge-sha' }), fallback);
    assert.deepEqual(route(id, routingContext('workflow_dispatch'), { JSTI_NATIVE_APPROVED_SHA: 'merge-sha' }),
      fallback);
  }
});

test('full runs compile Release without repeating the Debug test suite', () => {
  const body = jobBodies['release-validation'];
  assert.match(body, /^    name: Build \(Release\)$/m);
  assert.match(body, /run: swift build -c release\n/);
  assert.doesNotMatch(body, /swift test|JSTI_TEST_KEYCHAIN_REDIRECT/,
    'Release tests repeat Debug; release-mac.yml still runs them for published builds');
  assert.doesNotMatch(workflow, /build-ios-swiftpm|--target SpeakiOSLib/,
    'a host-only SpeakiOSLib build compiles almost no iOS code; real iOS compiles cover it');
});

test('UI jobs cannot be admitted to a native runner by repository variables', () => {
  for (const id of ['build-ios', 'core-journey-fixture-ui', 'build-ios-test-products']) {
    assert.doesNotMatch(jobBodies[id], /JSTI_NATIVE|jsti-macos-build|jsti-reviewed-local|bravo-mini-local/, id);
  }
});

test('Lint and the portable Swift graph run on hosted Ubuntu, never a macOS slot', () => {
  for (const id of ['lint', 'portable-linux']) {
    assert.match(jobBodies[id], /^    runs-on: ubuntu-24\.04$/m, id);
  }
  assert.match(jobBodies['portable-linux'], /image: swift:6\.2\.3-jammy@sha256:/);
  // The same entry points scripts/pre-pr runs, so a local pass means CI passes.
  assert.match(jobBodies['portable-linux'], /run: scripts\/ci-portable-linux\.sh\n/);
  assert.match(jobBodies.lint, /run: make ci-lint\n/);
  const ciLint = makefile.match(/^ci-lint:[^\n]*\n((?:\t[^\n]*\n)*)/m)?.[1] ?? '';
  for (const command of ['$(MAKE) lint', 'git diff --exit-code Tooling/Package.resolved', '$(MAKE) test-tooling']) {
    assert.ok(ciLint.includes(`\t${command}\n`), `make ci-lint must run ${command}`);
  }
  assert.match(jobBodies['build-macos'], /name: Test macOS-only tooling\n\s+if: needs\.release-paths\.outputs\.full == 'true'\n\s+run: make test-tooling/);
});

test('the macOS pull-request job tests only affected targets, minus those Linux proves', () => {
  const body = jobBodies['build-macos'];
  assert.match(body, /name: Compile iOS library for the simulator\n\s+if: needs\.release-paths\.outputs\.full != 'true' && needs\.release-paths\.outputs\.ios == 'true'/);
  assert.match(body, /xcodebuild build -scheme SpeakiOSLib -destination 'generic\/platform=iOS Simulator'/);
  assert.doesNotMatch(body.split('Compile iOS library for the simulator')[1].split('- name:')[0], /\btest\b/);
  assert.match(body, /name: Select affected unit tests\n\s+id: affected\n\s+if: needs\.release-paths\.outputs\.full != 'true'/);
  assert.match(body, /affected-swift-tests\.py "\$BASE"[\s\\]+--skip-target SpeakDesktopTests --skip-target SpeakAutomationKitTests/);
  assert.match(body, /if: steps\.affected\.outputs\.mode != 'none'/);
  assert.match(body, /BASE: \$\{\{ github\.event\.pull_request\.base\.sha \}\}/);
  assert.match(body, /git fetch --no-tags --depth=1 origin "\$BASE" \|\| true/);
});

test('Tessl is on demand and preserves trusted-author secret restrictions', () => {
  assert.doesNotMatch(tesslWorkflow, /^  pull_request:/m);
  assert.match(tesslWorkflow, /github\.event_name == 'issue_comment'/);
  assert.match(tesslWorkflow, /github\.event_name == 'workflow_dispatch'/);
  assert.match(tesslWorkflow, /allowed-associations: OWNER,MEMBER,COLLABORATOR/);
  assert.doesNotMatch(tesslWorkflow, /pull_request_target/);
});

test('every remote action in ci.yml is pinned to a full commit SHA with a version comment', () => {
  const uses = [...workflow.matchAll(/^\s+(?:- )?uses: ([^\s]+)(.*)$/gm)].filter(([, ref]) => !ref.startsWith('./'));
  assert.ok(uses.length > 0);
  for (const [line, ref, rest] of uses) {
    assert.match(ref, /^[\w.-]+\/[\w./-]+@[0-9a-f]{40}$/, line.trim());
    assert.match(rest, /^ # v\d+(?:\.\d+)*$/, `${line.trim()}: needs a version comment`);
  }
});

test('every Apple build cache isolates architecture, host and workspace, including restore prefixes', () => {
  const cacheLines = workflow.match(/^\s+(?:key:|restore-keys:).*(?:\n\s+\$\{\{[^\n]+)?/gm);
  const lintKey = cacheLines.find(line => line.includes('-tooling-'));
  assert.ok(lintKey);
  assert.equal(cacheLines.length, 8,
    'Debug restore/save, journey restore and release Swift keys with restore prefixes, plus the lint tooling key');
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
  // 30 minutes for the gated run plus the bounded 5-minute quarantine step.
  assert.match(body, /^\s+timeout-minutes: 35$/m);
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
  assert.match(body, /needs: \[release-paths, build-ios-test-products\]/);
  assert.match(body, /artifact-ids: \$\{\{ needs.build-ios-test-products.outputs.artifact-id \}\}/);
  assert.match(body, /scripts\/ios-test-products.py unpack/);
  assert.match(body, /-testProductsPath "\$RUNNER_TEMP\/ios-test-products\/SpeakiOS.xctestproducts"/);
  assert.match(body, /name: Upload complete iOS XCTest log separately\n\s+if: always\(\)/);
  const products = jobBodies['build-ios-test-products'];
  assert.match(products, /^\s+runs-on: macos-latest$/m);
  assert.match(products, /^\s+timeout-minutes: 30$/m);
  assert.match(products, /TUIST_IOS_KEYBOARD=1 scripts\/retry-network.sh tuist generate/);
  assert.match(products, /scripts\/retry-network.sh xcodebuild -resolvePackageDependencies/);
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
  assert.match(devices, /TUIST_WATCH_APP=1 TUIST_IOS_KEYBOARD=1 TUIST_IOS_KEYBOARD_DIRECT_CAPTURE=0 scripts\/retry-network.sh tuist generate/);
  assert.match(devices, /-scheme JustSpeakWatchApp/);
  assert.match(devices, /-destination generic\/platform=watchOS/);
  assert.match(devices, /-scheme SpeakiOS/);
  assert.match(devices, /-destination generic\/platform=iOS/);
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
const evaluatePredicate = new Function('needs', 'github', 'always', 'startsWith', `return (${
  predicate.replace(/\bneeds((?:\.[a-zA-Z0-9_-]+)+)/g, (_, path) =>
    'needs' + path.split('.').slice(1).map(key => `?.[${JSON.stringify(key)}]`).join(''))
});`);

function assessCIGates(needs, event) {
  const errors = assessOracle(needs, event);
  assert.equal(evaluatePredicate(needs, { event_name: event, head_ref: '' }, () => true,
    (value, prefix) => String(value ?? '').startsWith(prefix)), errors.length > 0,
    'workflow predicate must agree with fixture expectations');
  return errors;
}

test('a merge-batch pull request must run every gate', () => {
  const needs = Object.fromEntries(['release-paths', 'paid-access-worker', 'pre-pr-evidence', 'lint',
    'portable-linux', 'build-macos'].map(id => [id, { result: 'success' }]));
  needs['release-paths'].outputs = { apple: 'true', swift: 'true', ios: 'true', full: 'false' };
  const startsWith = (value, prefix) => String(value ?? '').startsWith(prefix);
  const run = head_ref => evaluatePredicate(needs, { event_name: 'pull_request', head_ref }, () => true, startsWith);
  assert.equal(run('merge-batch/7'), true, 'a batch reporting full=false is rejected');
  assert.match(jobBodies['release-paths'], /startsWith\(github\.head_ref, 'merge-batch\/'\)/, 'batches select full');
});

test('aggregate never checks out or executes repository helper code', () => {
  assert.doesNotMatch(aggregate, /uses:|run:.*scripts\/|checkout/);
  // The gate may only cancel its own run; the legacy mirror needs nothing.
  assert.match(aggregate, /    permissions:\n      actions: write\n    steps:/);
  assert.match(aggregate, /\/actions\/runs\/\$\{\{ github\.run_id \}\}\/force-cancel/);
  assert.match(aggregate, /Could not cancel this run; failing closed\.'\n\s+exit 1/);
  assert.match(aggregate, /exit 1/);
});

test('only pull requests cancel an in-progress CI run', () => {
  assert.match(workflow, /^concurrency:\n  group: \$\{\{ github\.workflow \}\}-\$\{\{ github\.ref \}\}\n  cancel-in-progress: \$\{\{ github\.event_name == 'pull_request' \}\}$/m,
    'main and merge-batch runs must finish so main is ever verified');
});

test('tooling gate delegates to the complete local discovery target', () => {
  assert.match(workflow, /- name: Lint and tooling tests \(make ci-lint\)\n\s+run: make ci-lint\n/);
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

const flags = ['apple', 'swift', 'api', 'full', 'workers'];
const allOutputs = value => Object.fromEntries(flags.map(flag => [flag, value]));
const gateFlags = Object.fromEntries(Object.entries(gateJobs).flatMap(([flag, ids]) => ids.map(id => [id, flag])));

function passing() {
  return Object.fromEntries(['release-paths', 'pre-pr-evidence', ...Object.keys(gateFlags)]
    .map(id => [id, { result: 'success', outputs: allOutputs('true') }]));
}

function pullRequest({ apple = 'true', swift = 'true', workers = 'true' } = {}) {
  const needs = passing();
  needs['release-paths'].outputs = { apple, swift, api: swift, full: 'false', workers };
  for (const [id, flag] of Object.entries(gateFlags)) {
    if (needs['release-paths'].outputs[flag] === 'false') needs[id].result = 'skipped';
  }
  return needs;
}

test('aggregate needs exactly the gate jobs and path detection', () => {
  const listed = [...aggregate.split('    permissions:')[0].matchAll(/^      - ([a-z0-9-]+)$/gm)].map(([, id]) => id).sort();
  assert.deepEqual(listed, ['release-paths', 'pre-pr-evidence', ...Object.keys(gateFlags)].sort());
});

test('accepts all successful gates on pushes and ci:full pull requests', () => {
  assert.deepEqual(assessCIGates(passing(), 'pull_request'), []);
  assert.deepEqual(assessCIGates(passing(), 'push'), []);
});

for (const id of Object.keys(passing())) {
  for (const status of ['failure', 'cancelled', 'skipped', undefined]) {
    test(`blocks ${id} when ${status ?? 'missing'}`, () => {
      const needs = passing();
      needs[id].result = status;
      assert.ok(assessCIGates(needs, 'pull_request').length > 0);
      assert.ok(assessCIGates(needs, 'push').length > 0);
    });
  }
}

test('an untrusted Swift pull request needs Lint, the Linux graph and one macOS job only', () => {
  const needs = pullRequest();
  assert.deepEqual(assessCIGates(needs, 'pull_request'), []);
  const macos = Object.entries(gateFlags).filter(([id, flag]) => !['full', 'workers'].includes(flag) && !['lint', 'portable-linux'].includes(id));
  assert.deepEqual(macos.map(([id]) => id), ['build-macos']);
  for (const id of ['lint', 'build-macos', 'portable-linux']) {
    const failed = pullRequest();
    failed[id].result = 'skipped';
    assert.ok(assessCIGates(failed, 'pull_request').length > 0, `${id} cannot skip on a Swift PR`);
  }
});

test('docs, website, Android and Workers-only pull requests skip every gate but Workers', () => {
  assert.deepEqual(assessCIGates(pullRequest({ apple: 'false', swift: 'false' }), 'pull_request'), []);
});

test('a trusted pull request merges on its pre-pr record alone', () => {
  const needs = pullRequest({ apple: 'false', swift: 'false', workers: 'false' });
  assert.deepEqual(assessCIGates(needs, 'pull_request'), []);
  needs['pre-pr-evidence'].result = 'failure';
  assert.ok(assessCIGates(needs, 'pull_request').length > 0, 'the record stays required');
  const main = pullRequest({ apple: 'false', swift: 'false', workers: 'false' });
  main['release-paths'].outputs.full = 'true';
  assert.ok(assessCIGates(main, 'push').length > 0, 'main can never skip');
});

test('non-Swift tooling pull requests run Lint only', () => {
  const needs = pullRequest({ swift: 'false' });
  assert.deepEqual(assessCIGates(needs, 'pull_request'), []);
  needs.lint.result = 'skipped';
  assert.ok(assessCIGates(needs, 'pull_request').length > 0);
});

test('merge batches and main may never skip a gate or report full=false', () => {
  assert.ok(assessCIGates(pullRequest(), 'push').length > 0, 'batch skips are rejected');
  const needs = passing();
  needs['release-paths'].outputs.full = 'false';
  assert.ok(assessCIGates(needs, 'push').length > 0);
});

// Full runs chain macOS jobs into lanes; a chained job still runs after its
// predecessor fails, so it is gated on !cancelled() plus its own output.
const macLanes = {
  'core-journey-e2e': 'build-macos', 'api-compatibility': 'release-validation',
  'build-ios': 'build-ios-test-products',
  'build-ios-keyboard': 'build-ios',
};

test('every gate job honours exactly its path-detection output', () => {
  for (const [id, flag] of Object.entries(gateFlags)) {
    const chained = id in macLanes && !['build-ios', 'core-journey-e2e'].includes(id);
    const pattern = chained
      ? `^    if: \\$\\{\\{ !cancelled\\(\\) && needs\\.${macLanes[id]}\\.result != 'skipped' && needs\\.release-paths\\.outputs\\.${flag} == 'true' \\}\\}$`
      : `^    if: needs\\.release-paths\\.outputs\\.${flag} == 'true'$`;
    assert.match(jobBodies[id], new RegExp(pattern, 'm'), id);
  }
  assert.match(jobBodies['paid-access-worker'], /^    needs: release-paths$/m);
});

test('full runs ask for at most four hosted macOS slots at once', () => {
  for (const [id, after] of Object.entries(macLanes)) {
    assert.match(jobBodies[id], new RegExp(`^    needs: \\[release-paths, ${after}\\]$`, 'm'), id);
  }
  const macJobs = Object.entries(jobBodies)
    .filter(([, body]) => /^    runs-on: (?:macos-latest|\$\{\{ fromJSON\(.*'\["macos-latest"\]'\) \}\})$/m.test(body))
    .map(([id]) => id);
  const laneHeads = macJobs.filter(id => !(id in macLanes));
  assert.deepEqual(laneHeads.sort(),
    ['build-ios-test-products', 'build-macos', 'core-journey-fixture-ui', 'release-validation']);
  assert.match(jobBodies['core-journey-fixture-ui'], /^      max-parallel: 1$/m, 'UI shards share one slot');
});

test('macOS lanes start only after the cheap Ubuntu gates pass', () => {
  for (const id of ['build-macos', 'core-journey-fixture-ui', 'release-validation', 'build-ios-test-products']) {
    assert.match(jobBodies[id], /^    needs: \[release-paths, lint, portable-linux, pre-pr-evidence\]$/m, id);
    assert.doesNotMatch(jobBodies[id], /^    if: .*(?:always|cancelled)\(\)/m, `${id}: a failed cheap gate must skip it`);
  }
  for (const id of ['lint', 'portable-linux', 'pre-pr-evidence']) {
    assert.match(jobBodies[id], /^    runs-on: ubuntu-[\w.]+$/m, id);
  }
});

test('pre-PR evidence is strict, exact-head and blocks the gate on pull requests', () => {
  const body = jobBodies['pre-pr-evidence'];
  assert.doesNotMatch(body, /^    if:/m, 'it always reports, passing straight through on pushes');
  assert.match(body, /JSTI_PRE_PR_STRICT: "true"/);
  assert.match(body, /ref: \$\{\{ github\.event\.pull_request\.head\.sha \}\}/);
  assert.match(body, /git rev-parse 'HEAD\^\{tree\}'/);
  assert.match(body, /^        if: github\.event_name == 'pull_request'$/m, 'merge-batch PRs need their combined record too');
  assert.match(body, /gh api "\$PR_URL" --jq '\.body \/\/ ""'/, 'reads the current body, not the event snapshot');
  assert.doesNotMatch(body, /continue-on-error/);
  assert.match(aggregate, /needs\.pre-pr-evidence\.result != 'success'/);
});

test('flaky iOS UI tests are quarantined to a bounded, non-gating step', () => {
  const body = jobBodies['build-ios'];
  const quarantine = body.match(/^      IOS_UI_QUARANTINE: (.+)$/m)?.[1];
  assert.ok(quarantine, 'the quarantine list is declared once on the job');
  for (const id of quarantine.split(' ')) {
    assert.match(id, /^SpeakiOSUITests\/[A-Za-z]+UITests\/test\w+$/, 'only individual UI tests are quarantined');
    assert.doesNotMatch(id, /SettingsCredentialUITests/, 'required evidence suites cannot be quarantined');
  }
  const gated = body.split('- name: Test iOS App and Action Button Settings')[1].split('\n      - name:')[0];
  assert.match(gated, /-skip-testing:\$test_id/);
  assert.doesNotMatch(gated, /continue-on-error/);
  const step = body.split('- name: Run quarantined iOS UI tests (non-gating)')[1].split('\n      - name:')[0];
  assert.match(step, /continue-on-error: true/);
  assert.match(step, /timeout-minutes: 5/);
  assert.match(step, /-only-testing:\$test_id/);
  assert.doesNotMatch(step, /ios-tests\.log|SpeakiOS\.xcresult"/, 'quarantine output never feeds gated evidence');
});

test('Apple path detection excludes only docs, the website, the Android app and Workers', () => {
  const body = jobBodies['release-paths'];
  const filter = body.match(
    /id: apple\n\s+with:\n\s+predicate-quantifier: every\n\s+filters: \|\n\s+apple:\n((?:\s+- '[^']+'\n)+)/);
  assert.ok(filter, 'apple filter must use the every-pattern quantifier');
  assert.deepEqual(filter[1].trim().split('\n').map(line => line.trim()), [
    "- '**'", "- '!android/**'", "- '!.github/workflows/android.yml'", "- '!Docs/**'", "- '!**/*.md'",
    "- '!landing-page/**'", "- '!.github/workflows/deploy-landing-page.yml'", "- '!workers/**'",
  ]);
  assert.match(body, /\{ echo "apple=true"; echo "swift=true"; echo "ios=true"; echo "api=true"; echo "full=true"; echo "workers=true"; \}/,
    'pushes force every gate');
  const swiftFilter = body.match(/\n            swift:\n((?:              - '[^']+'\n)+)/)?.[1] ?? '';
  assert.ok(swiftFilter.includes("- 'Sources/**'"));
  assert.doesNotMatch(swiftFilter, /\.github\//, 'CI-only edits must not take a macOS slot; use ci:full');
  assert.match(body, /echo "full=false"/);
  assert.match(body, /contains\(github\.event\.pull_request\.labels\.\*\.name, 'ci:full'\)/,
    'a ci:full label runs every gate before merge');
});

test('blocks missing path detection outputs', () => {
  const needs = passing();
  needs['release-paths'].outputs = {};
  assert.ok(assessCIGates(needs, 'pull_request').length > 0);
});

test('API compatibility diffs batches against main and main against its previous commit', () => {
  const body = jobBodies['api-compatibility'];
  assert.match(body, /\(github\.event\.before \|\| 'HEAD~1'\) \|\| 'origin\/main'/);
  assert.match(body, /git log --format=%s "\$BASELINE\.\.HEAD"/);
});

test('pull requests rely on pre-pr for the API check; full runs keep the API job', () => {
  assert.doesNotMatch(jobBodies['build-macos'], /check-api-compatibility|Public API compatibility/);
  assert.match(jobBodies['api-compatibility'], /bash scripts\/check-api-compatibility\.sh "\$BASELINE"/);
});

test('batch and main failures open a tracking issue from a main-only, checkout-free job', () => {
  const body = jobBodies['report-ci-failure'];
  assert.match(body, /if: failure\(\) && !cancelled\(\) && \(github\.event_name != 'pull_request' \|\| startsWith\(github\.head_ref, 'merge-batch\/'\)\)/);
  assert.match(body, /needs: gate/);
  assert.match(body, /issues: write/);
  assert.match(body, /ci-batch-failure/);
  assert.doesNotMatch(body, /checkout|scripts\//);
});

test('the legacy required name mirrors CI Gate without executing anything', () => {
  const legacy = jobBodies['required-macos'];
  assert.match(legacy, /name: Build & Test \(macOS\)/);
  assert.match(legacy, /needs: gate/);
  assert.match(legacy, /needs\.gate\.result != 'success'/);
  assert.doesNotMatch(legacy, /uses:|scripts\//);
  assert.match(aggregate, /name: CI Gate/);
});

test('pull requests restore the Swift cache without saving; main saves one entry per commit', () => {
  const body = jobBodies['build-macos'];
  assert.match(body, /uses: actions\/cache\/restore@[0-9a-f]{40} # v6\./);
  assert.match(body, /name: Save Swift packages \(main only\)\n\s+if: github\.event_name != 'pull_request' && github\.ref == 'refs\/heads\/main'/);
  assert.doesNotMatch(body, /uses: actions\/cache@/);
  assert.match(body, /-swift-\$\{\{ hashFiles\('Package\.resolved'\) \}\}-\$\{\{ github\.sha \}\}/);
});

test('launched-app UI shards in CI match every shard the verifier requires', () => {
  const ui = jobBodies['core-journey-fixture-ui'];
  const matrix = ui.match(/^\s+shard: \[([^\]]+)\]$/m);
  assert.ok(matrix, 'the UI gate must declare its shard matrix');
  const ciShards = matrix[1].split(',').map(value => value.trim()).sort();
  const verifier = readFileSync(new URL('../verify-core-journey-ui.py', import.meta.url), 'utf8');
  const block = verifier.match(/^SHARDS = \{\n([\s\S]*?)^\}/m);
  assert.ok(block, 'the verifier must declare SHARDS');
  const verifierShards = [...block[1].matchAll(/^    "([a-z0-9-]+)": \(/gm)].map(([, name]) => name).sort();
  assert.deepEqual(ciShards, verifierShards);
  assert.match(ui, /fail-fast: false/);
  assert.match(ui, /CORE_JOURNEY_UI_SHARD: \$\{\{ matrix\.shard \}\}/);
  assert.match(ui, /name: core-journey-fixture-ui-\$\{\{ matrix\.shard \}\}-\$\{\{ github\.run_attempt \}\}/);
});

test('network-bound package resolution and Tuist generation retry before Apple builds', () => {
  const retry = 'scripts/retry-network.sh';
  for (const id of ['build-macos', 'release-validation']) {
    const body = jobBodies[id];
    const resolve = body.indexOf(`run: ${retry} swift package resolve`);
    assert.ok(resolve > 0, `${id}: resolve with retries`);
    assert.ok(resolve < body.search(/run: (?:SWIFT_FLAGS=.*make build|swift build -c release)/),
      `${id}: resolution must precede the build`);
  }
  for (const id of ['build-ios-test-products', 'build-ios-keyboard']) {
    const body = jobBodies[id];
    assert.doesNotMatch(body.replaceAll(`${retry} tuist generate`, ''), /tuist generate/, `${id}: every generate retries`);
    assert.equal((body.match(/xcodebuild -resolvePackageDependencies/g) || []).length,
      (body.match(/tuist generate/g) || []).length, `${id}: resolve after each generate`);
  }
});

function selectGateOutputs(env) {
  const script = jobBodies['release-paths'].split('- name: Select gate outputs')[1].split('        run: |\n')[1]
    .split('\n').map(line => line.replace(/^ {10}/, '')).join('\n');
  const dir = mkdtempSync(join(tmpdir(), 'gate-select-'));
  const output = join(dir, 'out');
  writeFileSync(output, '');
  execFileSync('bash', ['-c', script], { env: { PATH: process.env.PATH, GITHUB_OUTPUT: output, ...env } });
  return Object.fromEntries(readFileSync(output, 'utf8').trim().split('\n').map(line => line.split('=')));
}

test('a trusted pre-pr record replaces every build and test on pull requests only', () => {
  const swiftPR = { EVENT_NAME: 'pull_request', FULL: 'false', APPLE: 'true', SWIFT: 'true', IOS: 'true', API: 'true' };
  assert.deepEqual(selectGateOutputs({ ...swiftPR, PRE_PR_TRUSTED: 'true' }),
    { apple: 'false', swift: 'false', ios: 'false', api: 'false', full: 'false', workers: 'false' });
  assert.deepEqual(selectGateOutputs({ ...swiftPR, PRE_PR_TRUSTED: 'false' }),
    { apple: 'true', swift: 'true', ios: 'true', api: 'true', full: 'false', workers: 'true' }, 'forks and Dependabot keep the CI jobs');
  assert.deepEqual(selectGateOutputs({ ...swiftPR, FULL: 'true', PRE_PR_TRUSTED: 'true' }),
    { apple: 'true', swift: 'true', ios: 'true', api: 'true', full: 'true', workers: 'true' }, 'ci:full and merge batches run everything');
  for (const event of ['push', 'workflow_dispatch']) {
    assert.equal(selectGateOutputs({ EVENT_NAME: event, PRE_PR_TRUSTED: 'false' }).full, 'true', event);
  }
  const trust = jobBodies['release-paths'].match(/PRE_PR_TRUSTED: (.*)/)[1];
  assert.match(trust, /github\.event\.pull_request\.head\.repo\.full_name == github\.repository/);
  assert.match(trust, /!startsWith\(github\.event\.pull_request\.user\.login, 'dependabot'\)/);
  assert.match(aggregate, /needs\.pre-pr-evidence\.result != 'success'/, 'the record itself stays required');
});

test('main can be re-verified by dispatch, as the auto-revert bot does', () => {
  assert.match(workflow, /^on:\n  push:\n    branches: \[main\]\n  pull_request:\n(?:  #.*\n)*  workflow_dispatch:\n/m);
});
