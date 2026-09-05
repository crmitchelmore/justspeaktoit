import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(new URL('../verify-release-ci.sh', import.meta.url));
const sha = 'a'.repeat(40);

function verify(t, { main = sha, conclusion = 'success', apiExit = '0', commit = sha,
  status = 'completed', attempt = 1, runs, current = {}, detailExit = '0' } = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'release-ci-test-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const log = join(directory, 'calls');
  const listedRuns = runs ?? [{ id: 101, run_number: 42, run_attempt: 1, conclusion: 'success' }];
  const detail = { id: 101, head_sha: sha, event: 'push', head_branch: 'main',
    status, conclusion, run_attempt: attempt, ...current };
  writeFileSync(join(directory, 'gh'), `#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$CALL_LOG"
if [[ "$MOCK_EXIT" != 0 ]]; then exit "$MOCK_EXIT"; fi
if [[ "$*" == *git/ref/heads/main* ]]; then
  BODY="$MOCK_MAIN"
elif [[ "$*" == *actions/workflows/ci.yml/runs* ]]; then
  BODY="$MOCK_RUNS"
else
  if [[ "$MOCK_DETAIL_EXIT" != 0 ]]; then exit "$MOCK_DETAIL_EXIT"; fi
  BODY="$MOCK_CURRENT"
fi
# Execute the production jq expression against fixture JSON, rather than
# returning a preselected conclusion and bypassing the selection logic.
while [[ "$#" -gt 0 && "$1" != --jq ]]; do shift; done
[[ "$#" -ge 2 ]] || exit 1
printf '%s' "$BODY" | jq -r "$2"
`, { mode: 0o755 });
  const result = spawnSync('bash', [script, commit], {
    encoding: 'utf8',
    env: { ...process.env, PATH: `${directory}:${process.env.PATH}`,
      GITHUB_REPOSITORY: 'owner/repo', MOCK_MAIN: JSON.stringify({ object: { sha: main } }),
      MOCK_RUNS: JSON.stringify({ workflow_runs: listedRuns }), MOCK_CURRENT: JSON.stringify(detail),
      MOCK_EXIT: apiExit, MOCK_DETAIL_EXIT: detailExit, CALL_LOG: log },
  });
  return { ...result, calls: () => readFileSync(log, 'utf8') };
}

test('allows the current main SHA after successful push CI', t => {
  const result = verify(t);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.calls(), new RegExp(`head_sha=${sha}`));
  assert.match(result.calls(), /branch=main/);
  assert.match(result.calls(), /event=push/);
  assert.doesNotMatch(result.calls(), /status=success/);
});

for (const conclusion of ['failure', 'cancelled', 'missing', 'null', 'timed_out', '']) {
  test(`blocks CI conclusion ${JSON.stringify(conclusion)}`, t => {
    const result = verify(t, { conclusion });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /has not succeeded/);
  });
}

test('blocks superseded main without accepting its old successful CI', t => {
  const result = verify(t, { main: 'b'.repeat(40) });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /no longer current main/);
  assert.doesNotMatch(result.calls(), /ci.yml/);
});

test('fails closed when GitHub API cannot be read', t => {
  assert.notEqual(verify(t, { apiExit: '1' }).status, 0);
});

test('rejects a symbolic ref instead of a pinned SHA', t => {
  const result = verify(t, { commit: 'main' });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /full Git SHA/);
});


test('reads the authoritative current attempt rather than a stale successful list snapshot', t => {
  const result = verify(t, { attempt: 2, conclusion: 'failure' });
  assert.equal(result.status, 1);
  assert.match(result.calls(), /actions\/runs\/101/);
  assert.match(result.stderr, /attempt: 2/);
});

test('accepts a completed successful rerun after the listed attempt failed', t => {
  const result = verify(t, { attempt: 2,
    runs: [{ id: 101, run_number: 42, run_attempt: 1, conclusion: 'failure' }] });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /attempt 2/);
});

for (const status of ['queued', 'in_progress', 'waiting']) {
  test(`blocks a ${status} attempt even if its conclusion still says success`, t => {
    assert.equal(verify(t, { attempt: 2, status }).status, 1);
  });
}

test('selects the newest run independently of API ordering and earlier rerun counts', t => {
  const result = verify(t, { runs: [
    { id: 102, run_number: 43, run_attempt: 1 },
    { id: 101, run_number: 42, run_attempt: 7 },
  ], current: { id: 102 }, conclusion: 'failure' });
  assert.equal(result.status, 1);
  assert.match(result.calls(), /actions\/runs\/102/);
});

test('fails closed when no matching run exists', t => {
  const result = verify(t, { runs: [] });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /No CI run found/);
  assert.doesNotMatch(result.calls(), /actions\/runs\//);
});

test('fails closed when authoritative run detail cannot be read', t => {
  assert.notEqual(verify(t, { detailExit: '1' }).status, 0);
});

for (const current of [{ head_sha: 'b'.repeat(40) }, { event: 'pull_request' }, { head_branch: 'feature' }]) {
  test(`rejects mismatched authoritative run ${JSON.stringify(current)}`, t => {
    const result = verify(t, { current });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /does not match/);
  });
}
