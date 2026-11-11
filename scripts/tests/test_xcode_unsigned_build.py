"""Tests for scripts/ci/xcode-unsigned-build.sh, ci.yml's unsigned keyboard and watch builds."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'ci' / 'xcode-unsigned-build.sh'
STUB = '#!/usr/bin/env bash\nprintf "%s %s\\n" "$(basename "$0")" "$*" >> "$CALLS"\n' \
       '[[ "$*" == *"-scheme ${FAIL_SCHEME:-none} -destination"* ]] && { echo "build failed"; exit 65; }\nexit 0\n'


class XcodeUnsignedBuildTests(unittest.TestCase):
    def run_script(self, *args, fail_scheme=None):
        with tempfile.TemporaryDirectory() as directory:
            bin_dir = Path(directory)
            for tool in ('tuist', 'xcodebuild'):
                (bin_dir / tool).write_text(STUB, encoding='utf-8')
                (bin_dir / tool).chmod(0o755)
            calls = bin_dir / 'calls'
            env = {**os.environ, 'PATH': f'{bin_dir}:{os.environ["PATH"]}', 'CALLS': str(calls),
                   'RETRY_NETWORK_DELAYS': '', **({'FAIL_SCHEME': fail_scheme} if fail_scheme else {})}
            result = subprocess.run(['bash', str(SCRIPT), *args], env=env, capture_output=True, text=True)
            lines = calls.read_text(encoding='utf-8').splitlines() if calls.exists() else []
            return result, lines

    def test_generates_resolves_then_builds_unsigned(self):
        result, calls = self.run_script('JustSpeakKeyboard', 'generic/platform=iOS')
        self.assertEqual(result.returncode, 0, result.stderr)
        workspace = '-workspace Just Speak to It.xcworkspace'
        self.assertEqual(calls, [
            'tuist generate --no-open',
            f'xcodebuild -resolvePackageDependencies -skipPackagePluginValidation {workspace} -scheme JustSpeakKeyboard',
            f'xcodebuild build {workspace} -scheme JustSpeakKeyboard -destination generic/platform=iOS '
            'CODE_SIGNING_ALLOWED=NO -skipPackagePluginValidation -quiet',
        ])

    def test_no_generate_only_builds(self):
        result, calls = self.run_script('--no-generate', 'SpeakiOS', 'generic/platform=iOS')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertTrue(calls[0].startswith('xcodebuild build '))

    def test_a_failed_build_fails_despite_the_output_tail(self):
        result, _ = self.run_script('JustSpeakWatchApp', 'generic/platform=watchOS', fail_scheme='JustSpeakWatchApp')
        self.assertEqual(result.returncode, 65)
        self.assertIn('build failed', result.stdout)

    def test_usage(self):
        self.assertEqual(self.run_script('OnlyScheme')[0].returncode, 64)


if __name__ == '__main__':
    unittest.main()
