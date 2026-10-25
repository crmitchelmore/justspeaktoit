import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

const helper = './.github/actions/setup-apple-toolchain';
const action = readFileSync(new URL(`../../${helper}/action.yml`, import.meta.url), 'utf8');
const workflow = name => readFileSync(new URL(`../../.github/workflows/${name}.yml`, import.meta.url), 'utf8');

// Extract the existing step subset without adding a package manager dependency.
// actionlint checks the consuming workflows; these tests execute the bounded contract.
function steps(source, indentation = 6) {
  return source.split(new RegExp(`(?=^ {${indentation}}- )`, 'm'))
    .filter(block => block.startsWith(`${' '.repeat(indentation)}- `))
    .map(block => {
      const lines = block.split('\n');
      const fields = [lines[0].slice(indentation + 2), ...lines.slice(1).map(line => line.slice(indentation + 2))];
      const get = key => fields.find(line => line.startsWith(`${key}: `))?.slice(key.length + 2);
      const inputs = Object.fromEntries([...block.matchAll(
        new RegExp(`^ {${indentation + 4}}(xcode-version|install-tuist): "?([^"\\n]*)"?$`, 'gm'),
      )].map(([, key, value]) => [key, value]));
      const run = get('run');
      const command = run === '|' ? fields.slice(fields.findIndex(line => line === 'run: |') + 1)
        .filter(line => line.startsWith('  ') || line === '').map(line => line.slice(2)).join('\n') : run;
      return { block, name: get('name'), uses: get('uses'), condition: get('if'), inputs, command };
    });
}

const composite = steps(action, 4);
const validation = composite.find(step => step.name === 'Validate toolchain options');

function operations(inputs = {}) {
  const values = { 'xcode-version': '', 'install-tuist': 'false', ...inputs };
  return composite.filter(step => step.uses || step.name === 'Install Tuist').filter(step => {
    const expression = step.condition.replace(/inputs\.([a-z-]+)/g, (_, key) => `inputs[${JSON.stringify(key)}]`);
    return new Function('inputs', `return (${expression});`)(values);
  }).map(step => step.uses ? `Xcode ${values['xcode-version']}` : 'Tuist');
}

function setup(step) {
  return step.uses === helper || step.uses?.startsWith('maxim-lobanov/setup-xcode@')
    || step.command?.trim() === 'brew install tuist';
}

function releaseSequence(name, hasHelper, receipt = 'missing') {
  return steps(workflow(name)).flatMap(step => {
    if (!setup(step)) return [step.name ?? step.uses];
    if (step.condition) {
      const allowed = new Function('hashFiles', 'steps', `return (${step.condition});`)(
        path => {
          assert.equal(path, '.github/actions/setup-apple-toolchain/action.yml');
          return hasHelper ? 'helper-hash' : '';
        }, { receipt: { outputs: { status: receipt } } },
      );
      if (!allowed) return [];
    }
    if (step.uses === helper) return operations(step.inputs);
    return [step.uses ? `Xcode ${step.inputs['xcode-version']}` : 'Tuist'];
  });
}

function ordered(sequence, expected) {
  const indexes = expected.map(value => sequence.indexOf(value));
  assert.ok(indexes.every(index => index >= 0), `Missing protected step: ${JSON.stringify({ sequence, expected })}`);
  assert.deepEqual(indexes, [...indexes].sort((a, b) => a - b));
}

test('composite has only opt-in tool selection with the existing pinned Xcode action', () => {
  assert.match(action, /using: composite/);
  const inputNames = [...action.slice(action.indexOf('inputs:'), action.indexOf('runs:'))
    .matchAll(/^  ([a-z-]+):$/gm)].map(([, name]) => name);
  assert.deepEqual(inputNames, ['xcode-version', 'install-tuist']);
  assert.match(action, /xcode-version:[\s\S]*?default: ""/);
  assert.match(action, /install-tuist:[\s\S]*?default: "false"/);
  assert.match(action, /maxim-lobanov\/setup-xcode@ed7a3b1fda3918c0306d1b724322adc0b8cc0a90 # v1\.7\.0/);
  assert.doesNotMatch(action, /secrets\.|APP_STORE_CONNECT|security |keychain|tuist generate|post:/);
  assert.deepEqual(operations(), []);
  assert.deepEqual(operations({ 'install-tuist': 'false' }), []);
  assert.deepEqual(operations({ 'install-tuist': 'true' }), ['Tuist']);
  assert.deepEqual(operations({ 'xcode-version': '26.2' }), ['Xcode 26.2']);
  assert.deepEqual(operations({ 'xcode-version': '26.2', 'install-tuist': 'true' }), ['Xcode 26.2', 'Tuist']);
});

test('actual validation rejects ambiguous or executable input before tool changes', t => {
  assert.equal(composite[0], validation);
  assert.match(validation.block, /INSTALL_TUIST: \$\{\{ inputs\.install-tuist \}\}/);
  assert.doesNotMatch(validation.command, /\$\{\{/);
  for (const value of ['true', 'false', '', 'False', 'yes', 'false; exit 0', '$(exit 0)']) {
    const result = spawnSync('bash', ['-e', '-o', 'pipefail', '-c', validation.command], {
      env: { ...process.env, INSTALL_TUIST: value }, encoding: 'utf8',
    });
    assert.equal(result.status, ['true', 'false'].includes(value) ? 0 : 1, value);
  }
  const directory = mkdtempSync(join(tmpdir(), 'apple-toolchain-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const log = join(directory, 'brew-call');
  writeFileSync(join(directory, 'brew'), '#!/bin/sh\nprintf "%s\\n" "$*" > "$BREW_CALL"\n', { mode: 0o755 });
  const install = composite.find(step => step.name === 'Install Tuist');
  const result = spawnSync('bash', ['-e', '-o', 'pipefail', '-c', install.command], {
    env: { ...process.env, PATH: `${directory}:${process.env.PATH}`, BREW_CALL: log }, encoding: 'utf8',
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(readFileSync(log, 'utf8'), 'install tuist\n');
});

test('CI preserves the selected Xcode and validates helper changes through both release path gates', () => {
  const source = workflow('ci');
  const calls = steps(source).filter(step => step.uses === helper);
  assert.equal(calls.length, 2);
  for (const call of calls) assert.deepEqual(call.inputs, { 'install-tuist': 'true' });
  const filters = source.slice(source.indexOf('          filters: |'), source.indexOf('      - name: Select gate outputs'));
  for (const section of filters.split(/^            (?:package|core-journey):$/m).slice(1)) {
    assert.ok(section.includes("- '.github/actions/setup-apple-toolchain/**'"));
  }
  assert.doesNotMatch(source, /github\.event\.number == 1038|JSTI_MAC_RUNNER/);
  const device = workflow('ios-device-matrix');
  assert.doesNotMatch(device, /uses: \.\/\.github\/actions\/setup-apple-toolchain/);
  assert.match(device, /TUIST_PINNED_VERSION: "4\.207\.0"/);
  for (const name of ['alpha-release', 'prepare-stable']) assert.doesNotMatch(workflow(name), /uses: \.\/\.github\/actions\/setup-apple-toolchain/);
});

test('release workers retain equivalent setup and protected order for old and new frozen sources', () => {
  for (const name of ['release-mac', 'release-ios', 'release-appstore']) {
    assert.ok(steps(workflow(name)).some(step => step.uses === helper), `${name}: shared setup must be exercised`);
    assert.deepEqual(releaseSequence(name, true), releaseSequence(name, false), name);
    const sequence = releaseSequence(name, true);
    assert.equal(sequence.filter(step => step === 'Xcode 26.2').length, 1, name);
    assert.equal(sequence.filter(step => step === 'Tuist').length, 1, name);
    assert.match(workflow(name), /ref: \$\{\{ inputs\.manifest \}\}/);
    const generation = steps(workflow(name)).find(step => step.name === 'Generate Xcode Project');
    assert.match(generation.command, /tuist generate --no-open/);
    assert.match(generation.command, /cp Package\.resolved/);
    if (name === 'release-mac') {
      ordered(sequence, ['Check candidate delivery receipt', 'Xcode 26.2', 'Run Tests (Release Config)',
        'Load frozen release manifest', 'Stamp immutable app metadata', 'Tuist', 'Generate Xcode Project',
        'Import Code Signing Certificate', 'Cleanup Keychain']);
      for (const hasHelper of [true, false]) {
        const delivered = releaseSequence(name, hasHelper, 'verified');
        assert.ok(!delivered.includes('Xcode 26.2') && !delivered.includes('Tuist'));
      }
    } else {
      ordered(sequence, ['Load frozen release manifest', 'Stamp immutable app metadata', 'Xcode 26.2', 'Tuist',
        'Install App Store Connect API Key', 'Reuse an already uploaded manifest build', 'Generate Xcode Project']);
      assert.equal(generation.condition, "steps.preflight.outputs.skip_upload != 'true'");
      if (name === 'release-appstore') assert.match(workflow(name), /if: always\(\)/);
    }
  }
});
