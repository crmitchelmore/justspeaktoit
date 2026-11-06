"""Real macOS Security integration; creates only private synthetic test items."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
WRAPPER = ROOT / 'scripts/with-test-keychain.py'
spec = importlib.util.spec_from_file_location('private_test_keychain', ROOT / 'scripts/private-test-keychain.py')
private = importlib.util.module_from_spec(spec)
spec.loader.exec_module(private)


@unittest.skipUnless(sys.platform == 'darwin', 'requires macOS Security framework')
class PrivateKeychainIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='jsti-scope-integration-')
        cls.root = Path(cls.temp.name).resolve()
        cls.probe = cls.root / 'scope-probe'
        subprocess.run(['xcrun', 'swiftc', '-DJSTI_TEST_KEYCHAIN_REDIRECT',
                        str(ROOT / 'Sources/SpeakCore/KeychainAccess.swift'),
                        str(ROOT / 'scripts/tests/keychain-scope-probe.swift'), '-o', str(cls.probe)],
                       check=True, capture_output=True, text=True, timeout=120)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.before = self.settings()
        self.directory = tempfile.TemporaryDirectory(prefix='jsti-ci-keychain-', dir=self.root)
        self.addCleanup(self.directory.cleanup)
        self.keychain = Path(self.directory.name) / 'tests.keychain-db'
        (self.keychain.parent / '.jsti-test-keychain').write_text(str(self.keychain))
        password = private.create(self.keychain)
        self.env = dict(os.environ, RUNNER_ENVIRONMENT='self-hosted', CI='true',
                        JSTI_TEST_KEYCHAIN='1', JSTI_TEST_KEYCHAIN_REDIRECT='1',
                        JSTI_TEST_KEYCHAIN_PATH=str(self.keychain),
                        JSTI_TEST_KEYCHAIN_PASSWORD=password)
        self.run_probe('seed')
        self.assertEqual(self.settings(), self.before)

    def tearDown(self):
        self.assertEqual(self.settings(), self.before)

    @staticmethod
    def settings():
        return [subprocess.check_output(['/usr/bin/security', query, '-d', 'user'], text=True)
                for query in ('default-keychain', 'list-keychains')]

    def run_probe(self, *args, env=None):
        subprocess.run([str(self.probe), *args], env=env or self.env, check=True,
                       capture_output=True, text=True, timeout=10)

    def wrapper_env(self):
        env = dict(self.env)
        env.pop('JSTI_TEST_KEYCHAIN_PATH')
        env['TMPDIR'] = str(self.root)
        return env

    def test_private_create_and_scoped_crud_cannot_read_or_delete_other_keychain(self):
        subprocess.run([sys.executable, str(WRAPPER), str(self.probe), 'exercise', str(self.keychain)],
                       env=self.wrapper_env(), check=True, capture_output=True, text=True, timeout=30)
        self.run_probe('check')
        env = dict(self.env, RUNNER_ENVIRONMENT='github-hosted')
        env.pop('JSTI_TEST_KEYCHAIN_PATH')
        self.run_probe('unscoped-check', str(self.keychain), env=env)

    def test_symlink_scope_is_rejected_even_with_a_matching_marker(self):
        alias = self.root / 'jsti-ci-keychain-alias'
        alias.symlink_to(self.keychain.parent, target_is_directory=True)
        marker = self.keychain.parent / '.jsti-test-keychain'
        aliased_path = str(alias / self.keychain.name)
        try:
            marker.write_text(aliased_path)
            self.run_probe('invalid', env=dict(self.env, JSTI_TEST_KEYCHAIN_PATH=aliased_path))
        finally:
            marker.write_text(str(self.keychain))
            alias.unlink()
        self.run_probe('check')

    def test_invalid_scope_and_unwrapped_native_ci_fail_closed(self):
        self.run_probe('invalid', env=dict(self.env, JSTI_TEST_KEYCHAIN_PATH='/missing/tests.keychain-db'))
        env = dict(self.env)
        env.pop('JSTI_TEST_KEYCHAIN_PATH')
        self.run_probe('unwrapped-native', env=env)
        self.run_probe('check')

    def test_locked_scope_unlocks_noninteractively_and_wrong_password_fails_closed(self):
        self.run_probe('lock-check')
        self.run_probe('bad-password', env=dict(self.env, JSTI_TEST_KEYCHAIN_PASSWORD='synthetic-wrong-password'))
        self.run_probe('check')

    def test_concurrent_native_commands_use_distinct_private_keychains(self):
        children = []
        states = []
        try:
            for index in range(2):
                ready = self.root / f'concurrent-{index}.json'
                child = subprocess.Popen([sys.executable, str(WRAPPER), str(self.probe), 'hold', str(ready)],
                                         env=self.wrapper_env(), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                children.append(child)
                deadline = time.monotonic() + 20
                while not ready.exists() and time.monotonic() < deadline:
                    if child.poll() is not None:
                        self.fail(child.stderr.read().decode())
                    time.sleep(0.05)
                self.assertTrue(ready.exists())
                states.append(json.loads(ready.read_text()))
            self.assertNotEqual(states[0]['path'], states[1]['path'])
            self.assertEqual(self.settings(), self.before)
            self.run_probe('check')
        finally:
            for child in children:
                if child.poll() is None:
                    child.terminate()
                child.wait(timeout=10)
                child.stderr.close()

    def test_sigterm_and_sigkill_leave_desktop_configuration_and_other_items_unchanged(self):
        for sig in (signal.SIGTERM, signal.SIGKILL):
            with self.subTest(signal=sig):
                ready = self.root / f'ready-{sig}.json'
                child = subprocess.Popen([sys.executable, str(WRAPPER), str(self.probe), 'hold', str(ready)],
                                         env=self.wrapper_env(), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                state = None
                try:
                    deadline = time.monotonic() + 20
                    while not ready.exists() and time.monotonic() < deadline:
                        if child.poll() is not None:
                            self.fail(child.stderr.read().decode())
                        time.sleep(0.05)
                    self.assertTrue(ready.exists())
                    state = json.loads(ready.read_text())
                    self.assertEqual(self.settings(), self.before)
                    child.send_signal(sig)
                    child.wait(timeout=10)
                    self.assertEqual(self.settings(), self.before)
                    self.run_probe('check')
                finally:
                    if child.poll() is None:
                        child.kill()
                        child.wait()
                    if state:
                        try:
                            os.killpg(state['pid'], signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        path = Path(state['path'])
                        if path.parent.parent == self.root:
                            shutil.rmtree(path.parent, ignore_errors=True)
                    child.stderr.close()
