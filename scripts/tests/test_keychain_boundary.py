"""Prevent app and fixture Security calls bypassing native CI file isolation."""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
VERIFIER = ROOT / 'scripts/verify-no-test-keychain-redirect.sh'


class KeychainBoundaryTests(unittest.TestCase):
    def test_app_and_credential_fixtures_use_canonical_security_boundary(self):
        raw = re.compile(r'\bSecItem(?:Add|CopyMatching|Update|Delete)\s*(?:\(|,|$)', re.M)
        paths = []
        for root in ['Sources/SpeakCore', 'Sources/SpeakApp', 'Sources/SpeakiOS',
                     'Tests/SpeakCoreTests', 'Tests/SpeakAppTests', 'Tests/SpeakiOSTests']:
            paths.extend((ROOT / root).rglob('*.swift'))
        offenders = [str(p.relative_to(ROOT)) for p in paths
                     if p.name != 'KeychainAccess.swift' and raw.search(p.read_text())]
        self.assertEqual(offenders, [])

    def test_native_and_hosted_gates_verify_real_process_isolation(self):
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        self.assertIn('python3 -B -m unittest scripts.tests.test_private_test_keychain -v', workflow)
        self.assertIn('python3 scripts/with-test-keychain.py bash scripts/run-core-journey-e2e.sh --phase test', workflow)

    def test_test_redirect_is_scoped_to_ci_test_commands(self):
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        for job in ('build-macos', 'core-journey-e2e'):
            body = re.split(r'\n  [a-z0-9-]+:\n', workflow.split(f'\n  {job}:\n', 1)[1], maxsplit=1)[0]
            self.assertIn('JSTI_TEST_KEYCHAIN_REDIRECT: "1"', body, job)
        release = (ROOT / '.github/workflows/release-mac.yml').read_text()
        self.assertEqual(release.count('JSTI_TEST_KEYCHAIN_REDIRECT'), 1)
        test_step = release.split('- name: Run Tests (Release Config)', 1)[1].split('\n      - name:', 1)[0]
        self.assertIn('JSTI_TEST_KEYCHAIN_REDIRECT: "1"', test_step)
        for action in ('package-mac-release', 'publish-speak-cli'):
            text = (ROOT / f'.github/actions/{action}/action.yml').read_text()
            self.assertIn('scripts/verify-no-test-keychain-redirect.sh', text, action)
            self.assertNotIn('JSTI_TEST_KEYCHAIN_REDIRECT', text, action)


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'requires the Apple Swift toolchain')
class ShippedKeychainRedirectTests(unittest.TestCase):
    """Distribution builds must not contain, or honour, the native-CI redirect."""

    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='jsti-keychain-redirect-')
        root = Path(cls.temp.name)
        cls.objects = {}
        for name, flags in (('shipped', []), ('test', ['-DJSTI_TEST_KEYCHAIN_REDIRECT'])):
            output = root / name / 'KeychainAccess.o'
            output.parent.mkdir()
            subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-name', 'SpeakCore', *flags, '-c',
                            str(ROOT / 'Sources/SpeakCore/KeychainAccess.swift'), '-o', str(output)],
                           check=True, capture_output=True, text=True, timeout=120)
            cls.objects[name] = output

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def verify(self, path):
        return subprocess.run(['bash', str(VERIFIER), str(path)], capture_output=True, text=True, timeout=60)

    def test_shipped_build_omits_redirect_environment_names(self):
        result = self.verify(self.objects['shipped'].parent)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('1 Mach-O file', result.stdout)

    def test_verifier_rejects_a_build_with_the_test_redirect(self):
        result = self.verify(self.objects['test'].parent)
        self.assertEqual(result.returncode, 1)
        for name in ('JSTI_TEST_KEYCHAIN_PATH', 'JSTI_TEST_KEYCHAIN_PASSWORD', 'RUNNER_ENVIRONMENT'):
            self.assertIn(name, result.stdout)

    def test_verifier_scans_zipped_cli_assets_and_refuses_empty_input(self):
        archive = Path(self.temp.name) / 'speak.zip'
        subprocess.run(['ditto', '-c', '-k', str(self.objects['test']), str(archive)], check=True)
        self.assertEqual(self.verify(archive).returncode, 1)
        empty = Path(self.temp.name) / 'empty'
        empty.mkdir(exist_ok=True)
        (empty / 'notes.txt').write_text('RUNNER_ENVIRONMENT')
        result = self.verify(empty)
        self.assertEqual(result.returncode, 1)
        self.assertIn('no Mach-O files', result.stderr)
