import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(new URL('../verify-launch.sh', import.meta.url));

function fixture(t, executable) {
  const directory = mkdtempSync(join(tmpdir(), 'launch-owner-test-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const app = join(directory, 'path with spaces', 'JustSpeakToIt.app');
  mkdirSync(join(app, 'Contents', 'MacOS'), { recursive: true });
  writeFileSync(join(app, 'Contents', 'Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>JustSpeakToIt</string></dict></plist>`);
  writeFileSync(join(app, 'Contents', 'MacOS', 'JustSpeakToIt'), `#!/usr/bin/env bash\n${executable}\n`, { mode: 0o755 });
  const lookupLog = join(directory, 'unscoped-lookup');
  // A same-name process exists; a return to name-based discovery would select it.
  const unrelated = spawn('sleep', ['30'], { stdio: 'ignore' });
  t.after(() => unrelated.kill());
  for (const command of ['open', 'pgrep']) {
    writeFileSync(join(directory, command), `#!/usr/bin/env bash
touch "${lookupLog}"
echo "${unrelated.pid}"
`, { mode: 0o755 });
  }
  const result = spawnSync('bash', [script, app], {
    encoding: 'utf8', timeout: 15000,
    env: { ...process.env, PATH: `${directory}:${process.env.PATH}`, VERIFY_LAUNCH_TIMEOUT: '0' },
  });
  assert.doesNotThrow(() => process.kill(unrelated.pid, 0), 'must not kill an unrelated process');
  assert.equal(existsSync(lookupLog), false, 'must not discover candidate by app name');
  return result;
}

test('verifies the candidate executable at a bundle path with spaces', t => {
  const result = fixture(t, 'exec sleep 30');
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Launch verification passed/);
});

test('rejects a crashed candidate despite another matching process being alive', t => {
  const result = fixture(t, 'exit 42');
  assert.equal(result.status, 1);
  assert.match(result.stdout, /Candidate process exited during launch/);
});
