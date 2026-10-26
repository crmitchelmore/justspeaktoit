"""Exercise the production retry loop with fake xcrun/sleep, never Apple services."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'retry-staple.sh'


class RetryStapleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='jsti-retry-staple-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.artifact = self.root / 'Alpha bundle with spaces κ.dmg'
        self.artifact.write_bytes(b'synthetic fixture, never passed to native tools')
        self.calls = self.root / 'calls'
        self.delays = self.root / 'delays'
        fake_xcrun = self.root / 'xcrun'
        fake_xcrun.write_text('''#!/usr/bin/env bash
set -euo pipefail
[[ "$1" = stapler && ( "$2" = staple || "$2" = validate ) ]]
printf '%s\\n' "$2" >> "$MOCK_CALLS"
[[ "$3" = "$MOCK_ARTIFACT" ]]
count=0
counter="$MOCK_ROOT/$2-count"
if [[ -f "$counter" ]]; then read -r count < "$counter"; fi
count=$((count + 1))
printf '%s\\n' "$count" > "$counter"
if [[ "$2" = staple ]]; then limit="$MOCK_STAPLE_FAILURES"; else limit="$MOCK_VALIDATE_FAILURES"; fi
if (( count <= limit )); then echo 'synthetic Apple transport failure' >&2; exit 68; fi
''', encoding='utf-8')
        fake_xcrun.chmod(0o700)
        fake_sleep = self.root / 'sleep'
        fake_sleep.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$1" >> "$MOCK_DELAYS"\n', encoding='utf-8')
        fake_sleep.chmod(0o700)

    def run_loop(self, staple_failures=0, validate_failures=0, overrides=None, artifact=None, missing_argument=False):
        env = dict(os.environ)
        env.pop('STAPLE_MAX_ATTEMPTS', None)
        env.pop('STAPLE_RETRY_DELAY_SECONDS', None)
        env.update(PATH=str(self.root) + os.pathsep + env['PATH'], MOCK_ROOT=str(self.root),
                   MOCK_CALLS=str(self.calls), MOCK_DELAYS=str(self.delays), MOCK_ARTIFACT=str(self.artifact),
                   MOCK_STAPLE_FAILURES=str(staple_failures), MOCK_VALIDATE_FAILURES=str(validate_failures))
        env.update(overrides or {})
        args = ['bash', str(SCRIPT)]
        if not missing_argument:
            args.append(str(artifact or self.artifact))
        result = subprocess.run(args, env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(self.artifact.read_bytes(), b'synthetic fixture, never passed to native tools')
        return result

    def trace(self):
        return self.calls.read_text(encoding='utf-8').splitlines() if self.calls.exists() else []

    def sleeps(self):
        return self.delays.read_text(encoding='utf-8').splitlines() if self.delays.exists() else []

    def test_first_attempt_requires_both_commands_and_handles_unicode_path(self):
        self.assertEqual(self.run_loop().returncode, 0)
        self.assertEqual(self.trace(), ['staple', 'validate'])
        self.assertEqual(self.sleeps(), [])

    def test_validation_transport_failure_retries_then_succeeds(self):
        self.assertEqual(self.run_loop(validate_failures=1).returncode, 0)
        self.assertEqual(self.trace(), ['staple', 'validate', 'staple', 'validate'])
        self.assertEqual(self.sleeps(), ['10'])

    def test_persistent_validation_failure_exhausts_default_budget_and_fails(self):
        result = self.run_loop(validate_failures=99)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.trace(), ['staple', 'validate'] * 6)
        self.assertEqual(self.sleeps(), ['10'] * 5)
        self.assertIn('failed after 6 attempts', result.stderr)

    def test_stapling_failure_still_retries_without_premature_validation(self):
        self.assertEqual(self.run_loop(staple_failures=2).returncode, 0)
        self.assertEqual(self.trace(), ['staple', 'staple', 'staple', 'validate'])
        self.assertEqual(self.sleeps(), ['10', '10'])

    def test_persistent_stapling_failure_never_validates_or_succeeds(self):
        self.assertNotEqual(self.run_loop(staple_failures=99).returncode, 0)
        self.assertEqual(self.trace(), ['staple'] * 6)
        self.assertEqual(self.sleeps(), ['10'] * 5)

    def test_validation_can_succeed_on_final_configured_attempt(self):
        self.assertEqual(self.run_loop(validate_failures=2, overrides={
            'STAPLE_MAX_ATTEMPTS': '3', 'STAPLE_RETRY_DELAY_SECONDS': '0'}).returncode, 0)
        self.assertEqual(self.trace(), ['staple', 'validate'] * 3)
        self.assertEqual(self.sleeps(), ['0', '0'])

    def test_missing_artifact_refuses_before_apple_commands(self):
        self.assertEqual(self.run_loop(artifact=self.root / 'absent.dmg').returncode, 2)
        self.assertEqual(self.trace(), [])
        self.assertEqual(self.sleeps(), [])

    def test_missing_argument_refuses_before_apple_commands(self):
        self.assertNotEqual(self.run_loop(missing_argument=True).returncode, 0)
        self.assertEqual(self.trace(), [])

    def test_invalid_attempt_count_refuses_before_apple_commands(self):
        for value in ['0', '-1', 'abc', '01']:
            with self.subTest(value=value):
                self.assertEqual(self.run_loop(overrides={'STAPLE_MAX_ATTEMPTS': value}).returncode, 2)
                self.assertEqual(self.trace(), [])
                self.assertEqual(self.sleeps(), [])

    def test_invalid_delay_refuses_before_apple_commands(self):
        for value in ['-1', '301', 'abc']:
            with self.subTest(value=value):
                self.assertEqual(self.run_loop(overrides={'STAPLE_RETRY_DELAY_SECONDS': value}).returncode, 2)
                self.assertEqual(self.trace(), [])
                self.assertEqual(self.sleeps(), [])


if __name__ == '__main__':
    unittest.main()
