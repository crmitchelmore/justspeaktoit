import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, matchesGlob } from 'node:path';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import { lanes, acceptsDesktopGate } from '../verify-desktop-ci-gates.mjs';

const read = path => readFileSync(new URL(`../../${path}`, import.meta.url), 'utf8');
const filters = {};
let current;
for (const line of read('.github/desktop-platform-paths.yml').split('\n')) {
  if (/^[a-z][a-z0-9-]+:$/.test(line)) filters[current = line.slice(0, -1)] = [];
  else if (line.startsWith('  - ')) filters[current].push(JSON.parse(line.slice(4)));
}
const workflows = Object.fromEntries(Object.entries(lanes).map(([id, spec]) => [id, read(`.github/workflows/${spec.file}`)]));
const jobs = text => Object.fromEntries([...text.slice(text.indexOf('\njobs:\n')).matchAll(
  /^  ([a-z][a-z0-9-]+):\n([\s\S]*?)(?=^  [a-z][a-z0-9-]+:\n|$(?![\s\S]))/gm,
)].map(([, id, body]) => [id, body]));
const selectedBy = (lane, paths) => paths.some(path => filters[lane].some(glob => matchesGlob(path, glob)));

for (const [lane, spec] of Object.entries(lanes)) {
  const source = workflows[lane];
  const bodies = jobs(source);
  const gate = bodies['required-desktop'];
  const predicate = gate.match(/if: >-\n([\s\S]*?)\n        env:/)?.[1];
  assert.ok(predicate, `${lane}: test the shipped inline predicate`);
  const rejects = new Function('needs', 'github', 'always', `return (${predicate.replace(
    /\bneeds((?:\.[a-zA-Z0-9_-]+)+)/g,
    (_, path) => 'needs' + path.split('.').slice(1).map(key => `?.[${JSON.stringify(key)}]`).join(''),
  )});`);
  const fixture = (selected = 'true', mode = 'build') => ({
    'desktop-paths': { result: 'success', outputs: { selected, mode } },
    ...Object.fromEntries(spec.required.map(id => [id, {
      result: selected === 'false' || (lane === 'linux-flatpak' && id !== (mode === 'retest' ? 'retest' : 'flatpak'))
        ? 'skipped' : 'success',
    }])),
  });
  function assess(needs, event = 'pull_request') {
    const expected = acceptsDesktopGate(lane, needs, event);
    assert.equal(!rejects(needs, { event_name: event }, () => true), expected, `${lane}: inline/oracle parity`);
    return expected;
  }

  test(`${lane}: stable terminal covers every mandatory job without repository code`, () => {
    assert.match(gate, new RegExp(`^    name: ${spec.name}$`, 'm'));
    assert.match(gate, /^    if: always\(\)$/m);
    assert.match(gate, /^    permissions: \{\}$/m);
    assert.doesNotMatch(gate, /uses:|scripts\/|continue-on-error:/);
    assert.match(gate, /exit 1/);
    assert.deepEqual(gate.match(/^    needs: \[(.+)\]$/m)[1].split(', '), ['desktop-paths', ...spec.required]);
    assert.deepEqual(Object.keys(bodies).filter(id => !['desktop-paths', 'required-desktop', 'sign'].includes(id)), spec.required);
    for (const id of spec.entry) {
      assert.match(bodies[id], /^    needs: desktop-paths$/m);
      assert.match(bodies[id], /needs.desktop-paths.outputs.selected == 'true'/);
    }
  });

  test(`${lane}: PR checks always emit; main push paths match canonical filters`, () => {
    const pr = source.match(/^  pull_request:\n((?: {4}[^\n]*\n|\n)*)/m);
    assert.ok(pr);
    assert.doesNotMatch(pr[1], /paths(?:-ignore)?:/);
    assert.doesNotMatch(source, /pull_request_target:/);
    const push = source.match(/^  push:\n((?: {4}[^\n]*\n|\n)*)/m)[1];
    assert.match(push, /^    branches: \[main\]$/m);
    assert.deepEqual([...push.matchAll(/^      - (.+)$/gm)].map(match => match[1]), filters[lane]);
    assert.ok(filters[lane].includes('Package.resolved'));
    assert.ok(filters[lane].includes('.github/desktop-platform-paths.yml'));
    assert.match(bodies['desktop-paths'], /dorny\/paths-filter@ceb8a2b8f2d89434be7ff52d3de7ec3738c5cc9d/);
    assert.match(bodies['desktop-paths'], /persist-credentials: false/);
  });

  test(`${lane}: relevant, docs, Apple-only and no-change classification`, () => {
    for (const paths of [[], ['README.md'], ['Docs/unrelated.md'], ['Sources/SpeakiOS/Views/Example.swift']]) {
      assert.equal(selectedBy(lane, paths), false, paths.join(','));
      assert.equal(assess(fixture('false')), true);
    }
    for (const path of ['Package.swift', 'Package.resolved', 'Sources/SpeakCore/Example.swift',
      'Sources/CLlamaCpp/Example.c', 'Sources/CMigrationArchive/Example.c', 'Sources/CRecordingFileSupport/Example.c',
      `.github/workflows/${spec.file}`, '.github/desktop-platform-paths.yml']) {
      assert.equal(selectedBy(lane, [path]), true, path);
    }
    assert.equal(assess(fixture()), true);
  });

  test(`${lane}: selected failure, cancellation, missing and unexpected skips fail closed`, () => {
    for (const job of spec.required) {
      for (const state of ['failure', 'cancelled', 'skipped', 'pending', undefined]) {
        // Flatpak's deliberately inactive branch must be skipped, never succeed/fail/cancel.
        if (lane === 'linux-flatpak' && job === 'retest' && state === 'skipped') continue;
        const needs = fixture();
        if (state === undefined) delete needs[job]; else needs[job].result = state;
        assert.equal(assess(needs), false, `${job}:${state}`);
      }
    }
    for (const job of spec.required) {
      for (const state of ['failure', 'cancelled', 'pending', undefined]) {
        const needs = fixture('false');
        if (state === undefined) delete needs[job]; else needs[job].result = state;
        assert.equal(assess(needs), false, `irrelevant ${job}:${state}`);
      }
    }
    for (const state of ['failure', 'cancelled', 'skipped', undefined]) {
      const needs = fixture('false');
      if (state === undefined) delete needs['desktop-paths']; else needs['desktop-paths'].result = state;
      assert.equal(assess(needs), false);
    }
    for (const value of ['', 'invalid', undefined]) {
      const needs = fixture(); needs['desktop-paths'].outputs.selected = value;
      assert.equal(assess(needs), false);
    }
    assert.equal(assess(fixture('false'), 'push'), false);
    assert.equal(assess(fixture('false'), 'workflow_dispatch'), false);
  });

  test(`${lane}: actual selector shell validates outputs and manual input boundaries`, () => {
    const script = bodies['desktop-paths'].match(/        run: \|\n([\s\S]*)/)[1].replace(/^          /gm, '');
    function select(event, selected, run = '', sha = '') {
      const dir = mkdtempSync(join(tmpdir(), 'platform-selector-'));
      const output = join(dir, 'outputs');
      try {
        const result = spawnSync('/bin/bash', ['-c', script], { encoding: 'utf8', env: {
          ...process.env, EVENT_NAME: event, SELECTED: selected, SOURCE_RUN: run, SOURCE_SHA: sha, GITHUB_OUTPUT: output,
        } });
        return { status: result.status, outputs: result.status === 0 ? readFileSync(output, 'utf8') : '' };
      } finally { rmSync(dir, { recursive: true, force: true }); }
    }
    for (const selected of ['true', 'false']) {
      const result = select('pull_request', selected);
      assert.equal(result.status, 0);
      assert.match(result.outputs, new RegExp(`selected=${selected}\\n`));
    }
    for (const selected of ['', 'invalid']) assert.notEqual(select('pull_request', selected).status, 0);
    for (const event of ['', 'merge_group', 'invalid']) assert.notEqual(select(event, 'false').status, 0);
    for (const event of ['push', 'workflow_dispatch']) assert.match(select(event, '').outputs, /selected=true\n/);
    if (lane === 'linux-flatpak') {
      assert.match(select('workflow_dispatch', '', '123', 'a'.repeat(40)).outputs, /mode=retest\n/);
      for (const [run, sha] of [['123', ''], ['', 'a'.repeat(40)], ['invalid', 'a'.repeat(40)], ['123', 'invalid']]) {
        assert.notEqual(select('workflow_dispatch', '', run, sha).status, 0);
      }
      assert.notEqual(select('pull_request', 'true', '123', 'a'.repeat(40)).status, 0);
      assert.equal(assess(fixture('true', 'retest'), 'workflow_dispatch'), true);
      assert.equal(assess(fixture('true', 'retest')), false);
      for (const selected of ['true', 'false']) {
        for (const mode of ['invalid', undefined]) {
          const needs = fixture(selected); needs['desktop-paths'].outputs.mode = mode;
          assert.equal(assess(needs), false, `${selected}:${mode}`);
        }
      }
      for (const mode of ['build', 'retest']) {
        const inactive = mode === 'retest' ? 'flatpak' : 'retest';
        for (const state of ['success', 'failure', 'cancelled', 'pending', undefined]) {
          const needs = fixture('true', mode);
          if (state === undefined) delete needs[inactive]; else needs[inactive].result = state;
          assert.equal(assess(needs, 'workflow_dispatch'), false, `${mode}:inactive ${state}`);
        }
      }
      const fork = fixture(); fork.flatpak.result = 'skipped';
      assert.equal(assess(fork), false, 'selected fork cannot silently skip privileged qualification');
      assert.match(bodies.flatpak, /github.event.pull_request.head.repo.full_name == github.repository/);
      assert.match(bodies.flatpak, /options: --privileged/);
      assert.doesNotMatch(bodies['desktop-paths'] + gate, /options: --privileged/);
    }
  });
}
