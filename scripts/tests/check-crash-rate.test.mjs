import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(new URL('../check-crash-rate.sh', import.meta.url));
const release = 'justspeaktoit-mac@2.30.1+202609051234';
const response = (rate, count = 100) => JSON.stringify({ groups: [{ totals: {
  'crash_free_rate(session)': rate, 'sum(session)': count,
} }] });

function check(t, { body = response(0.995), token = 'test-only', apiExit = '0', threshold = '99', releaseID = release } = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'crash-rate-test-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const log = join(directory, 'calls');
  writeFileSync(join(directory, 'curl'), `#!/usr/bin/env bash
printf '%s\\n' "$@" >> "$CALL_LOG"
printf '%s' "$MOCK_BODY"
exit "$MOCK_EXIT"
`, { mode: 0o755 });
  const result = spawnSync('bash', [script, releaseID], {
    encoding: 'utf8', env: { ...process.env, PATH: `${directory}:${process.env.PATH}`,
      SENTRY_AUTH_TOKEN: token, SENTRY_ORG: '', SENTRY_PROJECT: '',
      MOCK_BODY: body, MOCK_EXIT: apiExit, CALL_LOG: log, CRASH_FREE_THRESHOLD: threshold },
  });
  return { ...result, calls: () => readFileSync(log, 'utf8') };
}

test('accepts measured good health from the EU organization/project for exact release', t => {
  const result = check(t);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.calls(), /https:\/\/de.sentry.io\/api\/0\/organizations\/tally-lz\/sessions\//);
  assert.match(result.calls(), /project=justspeaktoit/);
  assert.ok(result.calls().includes(`--data-urlencode\nquery=release:${release}`));
  assert.match(result.calls(), /field=sum\(session\)/);
});

test('blocks a measured rate below threshold', t => {
  assert.equal(check(t, { body: response(0.98) }).status, 1);
});

for (const [name, options] of [
  ['missing credentials', { token: '' }],
  ['API outage', { apiExit: '22' }],
  ['malformed JSON', { body: '<html>bad gateway</html>' }],
  ['no groups', { body: '{"groups":[]}' }],
  ['no sessions', { body: response(1, 0) }],
  ['missing rate', { body: response(null) }],
  ['invalid rate', { body: response(2) }],
  ['boolean rate', { body: response(true) }],
  ['invalid threshold', { threshold: 'NaN' }],
  ['version without build identity', { releaseID: '2.30.1' }],
]) {
  test(`reports unknown health as failure for ${name}`, t => {
    assert.equal(check(t, options).status, 2);
  });
}
