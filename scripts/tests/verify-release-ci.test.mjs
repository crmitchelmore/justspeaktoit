import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(new URL('../verify-release-ci.sh', import.meta.url));
const sha = 'a'.repeat(40);

function verify(t, { main = sha, conclusion = 'success', apiExit = '0', commit = sha } = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'release-ci-test-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const log = join(directory, 'calls');
  writeFileSync(join(directory, 'gh'), `#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$CALL_LOG"
if [[ "$*" == *git/ref/heads/main* ]]; then
  printf '%s\\n' "$MOCK_MAIN"
else
  printf '%s\\n' "$MOCK_CONCLUSION"
fi
exit "$MOCK_EXIT"
`, { mode: 0o755 });
  const result = spawnSync('bash', [script, commit], {
    encoding: 'utf8',
    env: { ...process.env, PATH: `${directory}:${process.env.PATH}`,
      GITHUB_REPOSITORY: 'owner/repo', MOCK_MAIN: main,
      MOCK_CONCLUSION: conclusion, MOCK_EXIT: apiExit, CALL_LOG: log },
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
