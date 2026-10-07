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
<key>CFBundleExecutable</key><string>${name}</string>
<key>CFBundleIdentifier</key><string>com.example.launch-fixture</string></dict></plist>`);
  writeFileSync(join(app, 'Contents', 'MacOS', name), `#!/usr/bin/env bash
export FIXTURE_LAUNCH_TIME="$(python3 -c 'from datetime import datetime; print(datetime.now().astimezone().isoformat())')"
${executable}
`, { mode: 0o755 });
  const home = join(directory, 'home');
  const reports = join(home, 'Library', 'Logs', 'DiagnosticReports');
  mkdirSync(reports, { recursive: true });
  const diagnostics = join(directory, 'diagnostics');
  const scratch = join(directory, 'scratch');
  mkdirSync(scratch);
  const writer = join(directory, 'make-report.py');
  if (options.captureFailure) {
    const python = spawnSync('which', ['python3'], { encoding: 'utf8' }).stdout.trim();
    writeFileSync(join(directory, 'python3'), `#!/usr/bin/env bash
if [[ "$*" == *launch_diagnostics.py* ]]; then exit 7; fi
exec "${python}" "$@"
`, { mode: 0o755 });
  }
  writeFileSync(writer, `import json,os,sys
from datetime import datetime,timedelta
from pathlib import Path
pid,path,destination=sys.argv[1:4]
launch=datetime.fromisoformat(os.environ['FIXTURE_LAUNCH_TIME'])
mode=sys.argv[4] if len(sys.argv)>4 else ""
if mode=="future": launch+=timedelta(seconds=60)
reported_path="/Users/USER/*/"+"/".join(Path(path).parts[-4:]) if mode in ("redacted","wrong-identity") else path
bundle_id="wrong.bundle" if mode=="wrong-identity" else "com.example.launch-fixture"
capture=launch+timedelta(milliseconds=1)
secret="PRIVATE_SIGNING_SENTINEL"
if destination.endswith(".crash"):
 text=f"Process: fixture [{pid}]\\nPath: {path}\\nDate/Time: {capture.strftime('%Y-%m-%d %H:%M:%S.%f %z')}\\nException Type: EXC_BAD_ACCESS\\nSecret: {secret}\\n"
else:
 text=json.dumps({"pid":int(pid),"procPath":reported_path,"procName":Path(path).name,"bundleInfo":{"CFBundleIdentifier":bundle_id},
  "procLaunch":launch.strftime('%Y-%m-%d %H:%M:%S.%f %z'),"captureTime":capture.strftime('%Y-%m-%d %H:%M:%S.%f %z'),
  "exception":{"type":"EXC_BAD_ACCESS","rawCodes":[1,0],"secret":secret},
  "usedImages":[{"name":secret,"uuid":secret},{"name":"libswiftCore.dylib","uuid":"12345678-1234-1234-1234-123456789012"}],
  "threads":[{"triggered":True,"name":secret,"frames":[{"imageIndex":1,"imageOffset":123,"symbol":secret},{"imageIndex":0,"imageOffset":456}]}],
  "environment":secret})
Path(destination).write_text(text)
`);
  const logCalls = join(directory, 'log-calls');
  writeFileSync(join(directory, 'log'), `#!/usr/bin/env bash
printf '%s\\n' "$*" > "${logCalls}"
${options.logScript ?? 'echo "candidate log entry"'}
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
      TMPDIR: scratch, REPORT_WRITER: writer,
      VERIFY_LAUNCH_TIMEOUT: options.timeout ?? '0',
      VERIFY_LAUNCH_DIAGNOSTICS_WAIT: options.wait ?? '0',
      VERIFY_LAUNCH_DIAGNOSTICS_DIR: diagnostics },
  });
  assert.doesNotThrow(() => process.kill(unrelated.pid, 0), 'must not kill an unrelated process');
  assert.equal(existsSync(lookupLog), false, 'must not discover candidate by app name');
  assert.equal(result.error, undefined, result.error?.message);
  assert.deepEqual(readdirSync(scratch), [], 'owned stream capture and FIFO must be cleaned up');
  return { ...result, diagnostics, reports, logCalls };
}

test('verifies the candidate executable at a bundle path with spaces', t => {
  const result = fixture(t, 'exec sleep 30');
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /Launch verification passed/);
});

test('fails closed when the capture worker dies rather than accepting a blocked candidate', t => {
  const result = fixture(t, 'exec sleep 30', { captureFailure: true });
  assert.equal(result.status, 1);
  assert.match(result.stdout, /Output capture failed/);
  assert.doesNotMatch(result.stdout, /Launch verification passed/);
});

test('rejects a crashed candidate despite another matching process being alive', t => {
  const result = fixture(t, 'echo "early startup evidence"; exit 42');
  assert.equal(result.status, 1);
  assert.match(result.stdout, /Candidate process exited during launch/);
  assert.match(result.stdout, /exit status: 42/);
  assert.doesNotMatch(result.stdout, /early startup evidence/);
  assert.match(readFileSync(join(result.diagnostics, 'launch.txt'), 'utf8'), /exit_status=42/);
  assert.ok(JSON.parse(readFileSync(join(result.diagnostics, 'process-output.json'))).bytesDiscarded > 0);
  const pid = result.stdout.match(/Candidate PID: (\d+)/)[1];
  assert.match(readFileSync(result.logCalls, 'utf8'), new RegExp(`processIdentifier == ${pid}`));
  assert.doesNotMatch(readFileSync(result.logCalls, 'utf8'), /process ==/);
  assert.match(readFileSync(result.logCalls, 'utf8'), /processImagePath ==/);
  assert.match(readFileSync(result.logCalls, 'utf8'), /--start .* --end /);
  assert.doesNotMatch(readFileSync(result.logCalls, 'utf8'), /--last/);
});

test('retains only fresh crash reports belonging to the failed Alpha child', t => {
  const result = fixture(t, `
reports="$HOME/Library/Logs/DiagnosticReports"
python3 "$REPORT_WRITER" "$$" "$0" "$reports/JustSpeakToItAlpha-own.ips"
printf '{"pid":999999,"exception":{"type":"unrelated"}}' > "$reports/JustSpeakToItAlpha-other.ips"
python3 "$REPORT_WRITER" "$$" "$0" "$reports/JustSpeakToItAlpha-own.crash"
printf '{"pid":%s}' "$$" > "$reports/JustSpeakToItAlpha-old.ips"
touch -t 200001010000 "$reports/JustSpeakToItAlpha-old.ips"
exit 42
`, { name: 'JustSpeakToItAlpha' });
  assert.equal(result.status, 1);
  assert.equal(JSON.parse(readFileSync(join(result.diagnostics, 'crash-report-1.json'))).exceptionType, 'EXC_BAD_ACCESS');
  const files = readdirSync(result.diagnostics);
  assert.ok(files.includes('crash-report-1.json'));
  assert.ok(files.includes('crash-report-2.json'));
  assert.ok(!files.includes('JustSpeakToItAlpha-other.ips'));
  assert.ok(!files.includes('JustSpeakToItAlpha-old.ips'));
  assert.doesNotMatch(result.stdout, /"type":"unrelated"/);
});

test('waits a bounded interval for delayed crash-report delivery after early exit', t => {
  const result = fixture(t, `
pid=$$
path="$0"
(sleep 2.25; python3 "$REPORT_WRITER" "$pid" "$path" "$HOME/Library/Logs/DiagnosticReports/JustSpeakToIt-delayed.ips") &
exit 42
`, { wait: '1' });
  assert.equal(result.status, 1);
  assert.ok(existsSync(join(result.diagnostics, 'crash-report-1.json')));
});

test('collects the same diagnostics for death during stability monitoring', t => {
  const result = fixture(t, 'echo "monitoring evidence"; sleep 2.25; exit 43', { timeout: '3' });
  assert.equal(result.status, 1);
  assert.match(result.stdout, /Process died after/);
  assert.match(result.stdout, /exit status: 43/);
  assert.ok(JSON.parse(readFileSync(join(result.diagnostics, 'process-output.json'))).bytesDiscarded > 0);
});

test('keeps the gate failed when system-log collection fails', t => {
  const result = fixture(t, 'exit 42', { logExit: 1 });
  assert.equal(result.status, 1);
  assert.equal(JSON.parse(readFileSync(join(result.diagnostics, 'collection.json'))).systemLog.exitStatus, 1);
});

test('records signal exit status without accepting a crashed candidate', t => {
  const result = fixture(t, 'ulimit -c 0; kill -SEGV $$');
  assert.equal(result.status, 1);
  assert.match(result.stdout, /exit status: 139/);
});

test('bounds captured stdout and console excerpts', t => {
  const result = fixture(t, `python3 -c 'print("x" * 100000)'; exit 42`);
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.ok(JSON.parse(readFileSync(join(result.diagnostics, 'process-output.json'))).bytesDiscarded >= 100000);
  assert.ok(readFileSync(join(result.diagnostics, 'process-output.json')).length < 256);
  assert.ok(result.stdout.length < 20000, 'console evidence must remain bounded');
});

test('limits report count and rejects oversized, malformed and symlinked evidence', t => {
  const result = fixture(t, `
reports="$HOME/Library/Logs/DiagnosticReports"
for index in 1 2 3 4; do
  python3 "$REPORT_WRITER" "$$" "$0" "$reports/JustSpeakToIt-$index.ips"
done
python3 -c 'import os; print("{\\"pid\\":%s,\\"text\\":\\"%s\\"}" % (os.getppid(), "x" * 1048576))' > "$reports/JustSpeakToIt-big.ips"
printf 'not JSON' > "$reports/JustSpeakToIt-malformed.ips"
ln -s "$reports/JustSpeakToIt-1.ips" "$reports/JustSpeakToIt-link.ips"
exit 42
`);
  assert.equal(result.status, 1);
  const files = readdirSync(result.diagnostics).filter(name => name.startsWith('crash-report-'));
  assert.equal(files.length, 3);
  const stats = JSON.parse(readFileSync(join(result.diagnostics, 'collection.json'))).crashReports;
  assert.equal(stats.oversized, 1);
  assert.equal(stats.invalid, 1);
});

test('discards sustained producer output without growing temporary files', t => {
  const producer = `python3 - <<'PY'
import os,time
from pathlib import Path
end=time.monotonic()+0.75
while time.monotonic()<end:
 os.write(1,b"x"*32768)
 if any(p.is_file() and p.stat().st_size>1024 for p in Path(os.environ["TMPDIR"]).iterdir()):
  raise SystemExit(99)
 time.sleep(0.003)
PY
status=$?
[ "$status" = 0 ] || exit "$status"
exit 42`;
  const result = fixture(t, producer, { logScript: producer.replace('exit 42', 'exit 0') });
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stdout, /exit status: 42/);
  const output = JSON.parse(readFileSync(join(result.diagnostics, 'process-output.json')));
  const log = JSON.parse(readFileSync(join(result.diagnostics, 'collection.json'))).systemLog;
  assert.ok(output.bytesDiscarded > 1024 * 1024);
  assert.ok(log.bytesDiscarded > 1024 * 1024);
  assert.equal(log.exitStatus, 0);
});

test('bounds slow and continuously producing system-log sources', t => {
  for (const logScript of [
    `exec python3 -c 'import time; time.sleep(30)'`,
    `exec python3 -c 'import os,time; end=time.monotonic()+30
while time.monotonic()<end: os.write(1,b"x"*32768); time.sleep(0.01)'`,
  ]) {
    const started = Date.now();
    const result = fixture(t, 'exit 42', { logScript });
    assert.equal(result.status, 1);
    assert.ok(Date.now() - started < 12000);
    assert.equal(JSON.parse(readFileSync(join(result.diagnostics, 'collection.json'))).systemLog.timedOut, true);
  }
});

test('projects crash evidence without persisting arbitrary output or private text', t => {
  const result = fixture(t, `
echo "PRIVATE_SIGNING_SENTINEL"
echo "-----BEGIN PRIVATE KEY-----"
echo "secret-key-body"
echo "-----END PRIVATE KEY-----"
python3 "$REPORT_WRITER" "$$" "$0" "$HOME/Library/Logs/DiagnosticReports/JustSpeakToIt-own.ips"
exit 42
`, { logScript: 'echo "PRIVATE_SIGNING_SENTINEL"' });
  const evidence = readdirSync(result.diagnostics).map(name =>
    readFileSync(join(result.diagnostics, name), 'utf8')).join('\\n');
  assert.doesNotMatch(result.stdout + result.stderr + evidence, /PRIVATE_SIGNING_SENTINEL|PRIVATE KEY|secret-key-body/);
  const report = JSON.parse(readFileSync(join(result.diagnostics, 'crash-report-1.json')));
  assert.equal(report.frames[0].image, 'libswiftCore.dylib');
  assert.equal(report.frames[0].imageOffset, 123);
  assert.equal(report.frames[0].symbol, undefined);
  assert.equal(report.frames[1].image, 'other');
});

test('rejects a reused PID or mismatched executable despite matching report names', t => {
  const result = fixture(t, `
reports="$HOME/Library/Logs/DiagnosticReports"
python3 "$REPORT_WRITER" "$$" "$0" "$reports/JustSpeakToIt-reused.ips" future
python3 "$REPORT_WRITER" "$$" "/wrong/executable" "$reports/JustSpeakToIt-wrong.ips"
exit 42
`);
  const stats = JSON.parse(readFileSync(join(result.diagnostics, 'collection.json'))).crashReports;
  assert.equal(stats.identityRejected, 2);
  assert.equal(stats.reportsRetained, 0);
});

test('accepts native Apple path redaction only with matching bundle and process identity', t => {
  const result = fixture(t, `
reports="$HOME/Library/Logs/DiagnosticReports"
python3 "$REPORT_WRITER" "$$" "$0" "$reports/JustSpeakToIt-redacted.ips" redacted
python3 "$REPORT_WRITER" "$$" "$0" "$reports/JustSpeakToIt-wrong-identity.ips" wrong-identity
exit 42
`);
  const stats = JSON.parse(readFileSync(join(result.diagnostics, 'collection.json'))).crashReports;
  assert.equal(stats.reportsRetained, 1);
  assert.equal(stats.identityRejected, 1);
});

test('bounds report discovery and total reads before parsing a directory flood', t => {
  const result = fixture(t, `
reports="$HOME/Library/Logs/DiagnosticReports"
for index in {1..400}; do printf '{"pid":999999}' > "$reports/JustSpeakToIt-$index.ips"; done
exit 42
`, { wait: '1' });
  const stats = JSON.parse(readFileSync(join(result.diagnostics, 'collection.json'))).crashReports;
  assert.ok(stats.entriesScanned <= 256);
  assert.ok(stats.reportsRead <= 8);
  assert.equal(stats.discoveryTruncated, true);
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
