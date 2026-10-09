import importlib.util
import json
import os
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'with-test-keychain.py'
spec = importlib.util.spec_from_file_location('with_test_keychain', SCRIPT)
keychain_script = importlib.util.module_from_spec(spec)
spec.loader.exec_module(keychain_script)

# A stand-in for /usr/bin/security backed by a JSON file, so no test touches a real Keychain.
FAKE_SECURITY = textwrap.dedent('''\
    import fcntl, json, os, sys
    state_path = os.environ['FAKE_SECURITY_STATE']
    with open(state_path + '.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with open(state_path) as handle:
            state = json.load(handle)
        args = sys.argv[1:]
        state['calls'].append(args)
        command, rest = args[0], args[1:]
        if rest[:2] == ['-d', 'user']:
            rest = rest[2:]
        def live():
            return [path for path in state['created'] if os.path.exists(path)]
        if command == 'default-keychain':
            if rest[:1] == ['-s']:
                state['default'] = rest[1]
            else:
                print('    "%s"' % state['default'])
        elif command == 'list-keychains':
            if rest[:1] == ['-s']:
                state['search'] = rest[1:]
            else:
                for path in state['search']:
                    print('    "%s"' % path)
        elif command == 'create-keychain':
            path = rest[-1]
            if os.path.exists(path):
                sys.exit(48)
            open(path, 'w').close()
            state['created'].append(path)
            state['max_live'] = max(state['max_live'], len(live()))
        elif command in ('set-keychain-settings', 'unlock-keychain'):
            if not os.path.exists(rest[-1]):
                sys.exit(50)
        elif command == 'delete-keychain':
            os.remove(rest[-1])
            state['search'] = [path for path in state['search'] if path != rest[-1]]
        else:
            sys.exit(2)
        with open(state_path + '.tmp', 'w') as handle:
            json.dump(state, handle)
        os.replace(state_path + '.tmp', state_path)
''')

CHILD_EXPECTS_ISOLATION = textwrap.dedent('''\
    import json, os, signal, sys, time
    with open(os.environ['CHILD_PID_FILE'], 'a') as pids:
        pids.write('%d\\n' % os.getpid())
    if len(sys.argv) > 3 and sys.argv[3] == 'ignore-term':
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    if len(sys.argv) > 3 and sys.argv[3] == 'orphan':
        import subprocess
        orphan = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
        with open(os.environ['CHILD_PID_FILE'], 'a') as pids:
            pids.write('%d\\n' % orphan.pid)
    state = json.load(open(os.environ['FAKE_SECURITY_STATE']))
    default = state['default']
    ok = 'jsti-ci-keychain-' in default and os.path.exists(default) and state['search'] == [default]
    time.sleep(float(sys.argv[1]))
    sys.exit(int(sys.argv[2]) if ok else 99)
''')


class SwapPolicyTests(unittest.TestCase):
    def test_local_runs_do_not_swap_by_default(self):
        self.assertFalse(keychain_script.swap_enabled({}))
        self.assertFalse(keychain_script.swap_enabled({'CI': ''}))

    def test_ci_swaps_unless_disabled(self):
        self.assertTrue(keychain_script.swap_enabled({'CI': 'true'}))
        self.assertTrue(keychain_script.swap_enabled({'GITHUB_ACTIONS': 'true'}))
        self.assertFalse(keychain_script.swap_enabled({'CI': 'true', 'JSTI_TEST_KEYCHAIN': '0'}))

    def test_local_opt_in(self):
        self.assertTrue(keychain_script.swap_enabled({'JSTI_TEST_KEYCHAIN': '1'}))
        self.assertFalse(keychain_script.swap_enabled({'JSTI_TEST_KEYCHAIN': 'enabled'}))
        self.assertFalse(keychain_script.swap_enabled({'CI': 'true', 'JSTI_TEST_KEYCHAIN': 'typo'}))

    def test_security_calls_have_a_bounded_timeout(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(
            keychain_script.subprocess, 'check_output', return_value=''
        ) as command:
            keychain_script.security('list-keychains')
        self.assertEqual(command.call_args.kwargs['timeout'], 30)


class WithTestKeychainTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.home = self.root / 'home'
        keychains = self.home / 'Library' / 'Keychains'
        keychains.mkdir(parents=True)
        self.login = str(keychains / 'login.keychain-db')
        self.extra = str(keychains / 'extra.keychain-db')
        Path(self.login).touch()
        Path(self.extra).touch()
        (self.root / 'tmp').mkdir()
        self.state_dir = self.root / 'state'
        self.fake_state = self.root / 'security.json'
        fake = self.root / 'security'
        fake.write_text(f'#!{sys.executable}\n' + FAKE_SECURITY)
        fake.chmod(0o755)
        self.child = self.root / 'child.py'
        self.child.write_text(CHILD_EXPECTS_ISOLATION)
        self.write_state(self.login, [self.login, self.extra])
        self.env = {
            key: value for key, value in os.environ.items()
            if key not in ('CI', 'GITHUB_ACTIONS', 'JSTI_TEST_KEYCHAIN')
        }
        self.env.update({
            'HOME': str(self.home),
            'TMPDIR': str(self.root / 'tmp'),
            'JSTI_TEST_KEYCHAIN_SECURITY': str(fake),
            'JSTI_TEST_KEYCHAIN_STATE_DIR': str(self.state_dir),
            'FAKE_SECURITY_STATE': str(self.fake_state),
            'CI': 'true',
            'CHILD_PID_FILE': str(self.root / 'child-pids'),
            'JSTI_TEST_KEYCHAIN_GRACE_SECONDS': '1',
        })

    def write_state(self, default, search):
        self.fake_state.write_text(json.dumps(
            {'default': default, 'search': search, 'created': [], 'calls': [], 'max_live': 0}
        ))

    def state(self):
        return json.loads(self.fake_state.read_text())

    def command(self, *args):
        return [sys.executable, str(SCRIPT), *args]

    def child_command(self, sleep=0.0, exit_code=0, mode=''):
        return [sys.executable, str(self.child), str(sleep), str(exit_code), mode]

    def assert_children_gone(self):
        pids = [int(line) for line in (self.root / 'child-pids').read_text().split()]
        self.assertTrue(pids)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and any(self.alive(pid) for pid in pids):
            time.sleep(0.05)
        self.assertFalse([pid for pid in pids if self.alive(pid)])

    @staticmethod
    def alive(pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        # Reparented zombies still answer kill(0); treat them as gone.
        status = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)], capture_output=True, text=True).stdout
        return bool(status.strip()) and not status.strip().startswith('Z')

    def run_script(self, *args, env=None):
        return subprocess.run(self.command(*args), env=env or self.env, timeout=60).returncode

    def start_script(self, *args):
        return subprocess.Popen(self.command(*args), env=self.env, start_new_session=True)

    def wait_for_swap(self):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if keychain_script.TEMP_PREFIX in self.state()['default'] and (self.state_dir / 'state.json').exists():
                time.sleep(0.2)
                return
            time.sleep(0.05)
        self.fail('test Keychain was never activated')

    def assert_restored(self, search=None):
        state = self.state()
        self.assertEqual(state['default'], self.login)
        self.assertEqual(state['search'], search or [self.login, self.extra])
        self.assertTrue(state['created'])
        self.assertFalse([path for path in state['created'] if os.path.exists(path)])
        self.assertFalse(list((self.root / 'tmp').glob(keychain_script.TEMP_PREFIX + '*')))
        self.assertFalse((self.state_dir / 'state.json').exists())

    def test_local_run_passes_through_without_touching_keychain(self):
        env = dict(self.env)
        del env['CI']
        self.assertEqual(self.run_script(sys.executable, '-c', 'raise SystemExit(3)', env=env), 3)
        self.assertEqual(self.state()['calls'], [])

    def test_ci_run_isolates_and_restores(self):
        self.assertEqual(self.run_script(*self.child_command()), 0)
        self.assert_restored()

    def test_command_exit_status_is_propagated(self):
        self.assertEqual(self.run_script(*self.child_command(exit_code=7)), 7)
        self.assert_restored()

    def test_poisoned_originals_restore_login_keychain(self):
        dead = str(self.root / 'tmp' / 'jsti-ci-keychain-dead' / 'tests.keychain-db')
        self.write_state(dead, [dead])
        self.assertEqual(self.run_script(*self.child_command()), 0)
        self.assert_restored(search=[self.login])

    def test_missing_login_keychain_is_added_back(self):
        self.write_state(self.extra, [self.extra])
        self.assertEqual(self.run_script(*self.child_command()), 0)
        state = self.state()
        self.assertEqual(state['default'], self.extra)
        self.assertEqual(state['search'], [self.login, self.extra])

    def test_legitimate_keychain_with_wrapper_prefix_is_preserved(self):
        legitimate = str(Path(self.login).parent / 'jsti-ci-keychain-backup.keychain-db')
        Path(legitimate).touch()
        self.write_state(legitimate, [legitimate, self.login])
        self.assertEqual(self.run_script(*self.child_command()), 0)
        state = self.state()
        self.assertEqual(state['default'], legitimate)
        self.assertEqual(state['search'], [legitimate, self.login])

    def test_sigterm_forwards_to_command_and_restores(self):
        process = self.start_script(*self.child_command(sleep=30))
        self.wait_for_swap()
        process.send_signal(signal.SIGTERM)
        self.assertEqual(process.wait(timeout=30), 128 + signal.SIGTERM)
        self.assert_restored()
        self.assert_children_gone()

    def test_sigterm_escalates_to_sigkill_for_stubborn_commands(self):
        process = self.start_script(*self.child_command(sleep=30, mode='ignore-term'))
        self.wait_for_swap()
        process.send_signal(signal.SIGTERM)
        self.assertEqual(process.wait(timeout=30), 128 + signal.SIGKILL)
        self.assert_restored()
        self.assert_children_gone()

    def test_descendants_that_outlive_the_command_are_stopped_before_restore(self):
        self.assertEqual(self.run_script(*self.child_command(mode='orphan')), 0)
        self.assert_restored()
        self.assert_children_gone()

    def test_sighup_restores(self):
        process = self.start_script(*self.child_command(sleep=30))
        self.wait_for_swap()
        process.send_signal(signal.SIGHUP)
        self.assertEqual(process.wait(timeout=30), 128 + signal.SIGHUP)
        self.assert_restored()

    def test_sigint_restores(self):
        process = self.start_script(*self.child_command(sleep=30))
        self.wait_for_swap()
        process.send_signal(signal.SIGINT)
        self.assertEqual(process.wait(timeout=30), 128 + signal.SIGINT)
        self.assert_restored()

    def test_sigkill_is_recovered_by_the_next_run(self):
        process = self.start_script(*self.child_command(sleep=30))
        self.wait_for_swap()
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=30)
        self.assertIn(keychain_script.TEMP_PREFIX, self.state()['default'])
        orphaned = [int(line) for line in (self.root / 'child-pids').read_text().split()]
        self.assertTrue(all(self.alive(pid) for pid in orphaned))
        self.assertEqual(self.run_script(*self.child_command()), 0)
        self.assert_restored()
        self.assert_children_gone()

    def test_repair_recovers_after_sigkill(self):
        process = self.start_script(*self.child_command(sleep=30))
        self.wait_for_swap()
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=30)
        self.assertEqual(self.run_script('--repair'), 0)
        self.assert_restored()

    def test_unreadable_journal_does_not_change_settings_or_delete_state(self):
        self.state_dir.mkdir()
        journal = self.state_dir / 'state.json'
        journal.write_text('{not json')
        before = self.state()
        self.assertEqual(self.run_script('--repair'), 70)
        self.assertEqual(self.state(), before)
        self.assertTrue(journal.exists())

    def test_recovery_does_not_signal_a_group_with_mismatched_identity(self):
        unrelated = subprocess.Popen(
            [sys.executable, '-c', 'import time; time.sleep(60)'],
            start_new_session=True,
        )
        def stop_unrelated():
            if unrelated.poll() is None:
                unrelated.kill()
            unrelated.wait()
        self.addCleanup(stop_unrelated)
        directory = Path(tempfile.mkdtemp(prefix=keychain_script.TEMP_PREFIX, dir=self.root / 'tmp'))
        keychain = directory / 'tests.keychain-db'
        keychain.touch()
        (directory / keychain_script.OWNERSHIP_MARKER).write_text(str(keychain))
        self.state_dir.mkdir()
        (self.state_dir / 'state.json').write_text(json.dumps({
            'version': keychain_script.JOURNAL_VERSION,
            'default': self.login,
            'search': [self.login, str(keychain)],
            'keychain': str(keychain),
            'pid': 123,
            'boot': keychain_script.boot_identifier(),
            'group': unrelated.pid,
            'child_identity': 'definitely-not-the-live-process',
            'child_token': 'not-the-live-process-token',
        }))
        self.write_state(str(keychain), [str(keychain)])
        self.assertEqual(self.run_script('--repair'), 0)
        self.assertIsNone(unrelated.poll())
        state = self.state()
        self.assertEqual(state['default'], self.login)
        self.assertEqual(state['search'], [self.login])
        self.assertFalse(keychain.exists())
        self.assertFalse((self.state_dir / 'state.json').exists())

    def test_launch_gate_cannot_exec_before_the_journal_release(self):
        marker = self.root / 'launched'
        child, gate_fd = keychain_script.launch_gated(
            [sys.executable, '-c', f'from pathlib import Path; Path({str(marker)!r}).touch()'],
            'gate-test-token',
        )
        try:
            time.sleep(0.1)
            self.assertFalse(marker.exists())
            os.write(gate_fd, b'1')
            os.close(gate_fd)
            gate_fd = None
            self.assertEqual(child.wait(timeout=10), 0)
            self.assertTrue(marker.exists())
        finally:
            if gate_fd is not None:
                os.close(gate_fd)
            if child.poll() is None:
                child.kill()
                child.wait()

    def test_concurrent_runs_serialise_and_restore_originals(self):
        processes = [self.start_script(*self.child_command(sleep=0.3)) for _ in range(6)]
        self.assertEqual([process.wait(timeout=120) for process in processes], [0] * 6)
        state = self.state()
        self.assertEqual(len(state['created']), 6)
        self.assertEqual(state['max_live'], 1)
        self.assert_restored()


if __name__ == '__main__':
    unittest.main()
