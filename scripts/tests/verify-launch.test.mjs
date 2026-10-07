import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, existsSync, readFileSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(new URL('../verify-launch.sh', import.meta.url));

function fixture(t, executable, options = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'launch-owner-test-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const app = join(directory, 'path with spaces', 'JustSpeakToIt.app');
  mkdirSync(join(app, 'Contents', 'MacOS'), { recursive: true });
  const name = options.name ?? 'JustSpeakToIt';
  writeFileSync(join(app, 'Contents', 'Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>${name}</string></dict></plist>`);
  writeFileSync(join(app, 'Contents', 'MacOS', name), `#!/usr/bin/env bash\n${executable}\n`, { mode: 0o755 });
  const home = join(directory, 'home');
  const reports = join(home, 'Library', 'Logs', 'DiagnosticReports');
  mkdirSync(reports, { recursive: true });
  const diagnostics = join(directory, 'diagnostics');
  const logCalls = join(directory, 'log-calls');
  writeFileSync(join(directory, 'log'), `#!/usr/bin/env bash
printf '%s\\n' "$*" > "${logCalls}"
echo "candidate log entry"
exit ${options.logExit ?? 0}
`, { mode: 0o755 });
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
    env: { ...process.env, PATH: `${directory}:${process.env.PATH}`, HOME: home,
      VERIFY_LAUNCH_TIMEOUT: options.timeout ?? '0',
      VERIFY_LAUNCH_DIAGNOSTICS_WAIT: options.wait ?? '0',
      VERIFY_LAUNCH_DIAGNOSTICS_DIR: diagnostics },
  });
  assert.doesNotThrow(() => process.kill(unrelated.pid, 0), 'must not kill an unrelated process');
  assert.equal(existsSync(lookupLog), false, 'must not discover candidate by app name');
  assert.equal(result.error, undefined, result.error?.message);
  return { ...result, diagnostics, reports, logCalls };
}

test('verifies the candidate executable at a bundle path with spaces', t => {
  const result = fixture(t, 'exec sleep 30');
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Launch verification passed/);
});

test('rejects a crashed candidate despite another matching process being alive', t => {
  const result = fixture(t, 'echo "early startup evidence"; exit 42');
  assert.equal(result.status, 1);
  assert.match(result.stdout, /Candidate process exited during launch/);
  assert.match(result.stdout, /exit status: 42/);
  assert.match(result.stdout, /early startup evidence/);
  assert.match(result.stdout, /No new crash report/);
  assert.match(readFileSync(join(result.diagnostics, 'launch.txt'), 'utf8'), /exit_status=42/);
  assert.match(readFileSync(join(result.diagnostics, 'process-output.txt'), 'utf8'), /early startup evidence/);
  const pid = result.stdout.match(/Candidate PID: (\d+)/)[1];
  assert.match(readFileSync(result.logCalls, 'utf8'), new RegExp(`processIdentifier == ${pid}`));
  assert.doesNotMatch(readFileSync(result.logCalls, 'utf8'), /process ==/);
});

test('retains only fresh crash reports belonging to the failed Alpha child', t => {
  const result = fixture(t, `
reports="$HOME/Library/Logs/DiagnosticReports"
printf '{"metadata":"header"}\\n{"pid":%s,"exception":{"type":"EXC_BAD_ACCESS"}}\\n' "$$" > "$reports/JustSpeakToItAlpha-own.ips"
printf '{"pid":999999,"exception":{"type":"unrelated"}}' > "$reports/JustSpeakToItAlpha-other.ips"
printf 'Process: JustSpeakToItAlpha [%s]\\nException Type: EXC_BAD_ACCESS\\n' "$$" > "$reports/JustSpeakToItAlpha-own.crash"
printf '{"pid":%s}' "$$" > "$reports/JustSpeakToItAlpha-old.ips"
touch -t 200001010000 "$reports/JustSpeakToItAlpha-old.ips"
exit 42
`, { name: 'JustSpeakToItAlpha' });
  assert.equal(result.status, 1);
  assert.match(result.stdout, /EXC_BAD_ACCESS/);
  const files = readdirSync(result.diagnostics);
  assert.ok(files.includes('JustSpeakToItAlpha-own.ips'));
  assert.ok(files.includes('JustSpeakToItAlpha-own.crash'));
  assert.ok(!files.includes('JustSpeakToItAlpha-other.ips'));
  assert.ok(!files.includes('JustSpeakToItAlpha-old.ips'));
  assert.doesNotMatch(result.stdout, /"type":"unrelated"/);
});

test('waits a bounded interval for delayed crash-report delivery after early exit', t => {
  const result = fixture(t, `
pid=$$
(sleep 2.25; printf '{"pid":%s,"exception":"delayed report"}' "$pid" > "$HOME/Library/Logs/DiagnosticReports/JustSpeakToIt-delayed.ips") &
exit 42
`, { wait: '1' });
  assert.equal(result.status, 1);
  assert.match(result.stdout, /delayed report/);
  assert.ok(existsSync(join(result.diagnostics, 'JustSpeakToIt-delayed.ips')));
});

test('collects the same diagnostics for death during stability monitoring', t => {
  const result = fixture(t, 'echo "monitoring evidence"; sleep 2.25; exit 43', { timeout: '3' });
  assert.equal(result.status, 1);
  assert.match(result.stdout, /Process died after/);
  assert.match(result.stdout, /exit status: 43/);
  assert.match(readFileSync(join(result.diagnostics, 'process-output.txt'), 'utf8'), /monitoring evidence/);
});

test('keeps the gate failed when system-log collection fails', t => {
  const result = fixture(t, 'exit 42', { logExit: 1 });
  assert.equal(result.status, 1);
  assert.match(result.stdout, /System log query failed with exit status 1/);
});

test('records signal exit status without accepting a crashed candidate', t => {
  const result = fixture(t, 'ulimit -c 0; kill -SEGV $$');
  assert.equal(result.status, 1);
  assert.match(result.stdout, /exit status: 139/);
});

test('bounds captured stdout and console excerpts', t => {
  const result = fixture(t, `python3 -c 'print("x" * 100000)'; exit 42`);
  assert.equal(result.status, 1);
  assert.equal(readFileSync(join(result.diagnostics, 'process-output.txt')).length, 64 * 1024);
  assert.ok(result.stdout.length < 20000, 'console evidence must remain bounded');
});

test('limits report count and rejects oversized, malformed and symlinked evidence', t => {
  const result = fixture(t, `
reports="$HOME/Library/Logs/DiagnosticReports"
for index in 1 2 3 4; do
  printf '{"pid":%s,"exception":"owned"}' "$$" > "$reports/JustSpeakToIt-$index.ips"
done
python3 -c 'import os; print("{\\"pid\\":%s,\\"text\\":\\"%s\\"}" % (os.getppid(), "x" * 1048576))' > "$reports/JustSpeakToIt-big.ips"
printf 'not JSON' > "$reports/JustSpeakToIt-malformed.ips"
ln -s "$reports/JustSpeakToIt-1.ips" "$reports/JustSpeakToIt-link.ips"
exit 42
`);
  assert.equal(result.status, 1);
  const files = readdirSync(result.diagnostics).filter(name => name.endsWith('.ips'));
  assert.equal(files.length, 3);
  assert.ok(files.every(name => /^JustSpeakToIt-[1-4]\.ips$/.test(name)));
  assert.match(result.stdout, /Skipping oversized crash report/);
  assert.match(result.stdout, /Cannot read crash report.*malformed/);
});

test('release variants persist both launch phases even when packaging fails', () => {
  const action = readFileSync(new URL('../../.github/actions/package-mac-release/action.yml', import.meta.url), 'utf8');
  assert.match(action, /VERIFY_LAUNCH_DIAGNOSTICS_DIR:.*launch-diagnostics\/.*\/pre-notarisation/);
  assert.match(action, /VERIFY_LAUNCH_DIAGNOSTICS_DIR:.*launch-diagnostics\/.*\/post-notarisation/);
  assert.equal((action.match(/\.\/scripts\/verify-launch\.sh/g) ?? []).length, 2);
  const workflow = readFileSync(new URL('../../.github/workflows/release-mac.yml', import.meta.url), 'utf8');
  assert.match(workflow, /name: Preserve launch failure diagnostics\n\s+if:.*always\(\)/);
  assert.match(workflow, /path:.*runner\.temp.*\/launch-diagnostics/);
  assert.match(workflow, /retention-days: 7/);
});
