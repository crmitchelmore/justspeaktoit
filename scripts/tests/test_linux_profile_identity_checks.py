"""Owned-fixture admission/signalling/cleanup; no X server, native app or compiler."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('profile_checks', ROOT / 'scripts/linux-profile-identity-checks.py')
CHECKS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKS)


class ProfileIdentityHarnessTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='jsti-profile-harness-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.environment = dict(os.environ, DISPLAY=':87', JSTI_PROFILE_OWNED_DISPLAY=':87',
                                JSTI_PROFILE_OWNED_DISPLAY_PID='321')

    def test_actual_proc_admission_requires_same_display_and_callers_own_xvfb(self):
        proc = self.root / 'proc'
        process = proc / '321'
        process.mkdir(parents=True)
        (process / 'stat').write_text('321 (Xvfb) S 123 0 0', encoding='utf-8')
        (process / 'cmdline').write_bytes(b'/usr/bin/Xvfb\0:87\0-screen\0')
        CHECKS.admit_display(self.environment, parent=123, proc=proc)
        for changed in [dict(self.environment, DISPLAY=':0'),
                        dict(self.environment, JSTI_PROFILE_OWNED_DISPLAY=''),
                        dict(self.environment, JSTI_PROFILE_OWNED_DISPLAY_PID='bad')]:
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                CHECKS.admit_display(changed, parent=123, proc=proc)
        with self.assertRaises(ValueError):
            CHECKS.admit_display(self.environment, parent=999, proc=proc)
        (process / 'cmdline').write_bytes(b'/usr/bin/personal-session\0:87\0')
        with self.assertRaises(ValueError):
            CHECKS.admit_display(self.environment, parent=123, proc=proc)

    def test_ambient_display_refused_before_any_child_is_created(self):
        with patch.object(CHECKS.subprocess, 'Popen') as child, self.assertRaises(ValueError):
            CHECKS.run('/not/launched', dict(self.environment, JSTI_PROFILE_OWNED_DISPLAY=''))
        child.assert_not_called()

    def install_fake_tools(self):
        # These Python fixtures exercise the real orchestration, never GTK/X11.
        tools = self.root / 'tools'
        tools.mkdir()
        registry = self.root / 'registry'
        registry.mkdir()
        programs = {
            'zenity': '''import json, os, pathlib, signal, sys
index = sys.argv[sys.argv.index('--title') + 1].rsplit(' ', 1)[1]
pathlib.Path(os.environ['FAKE_REGISTRY'], index + '.json').write_text(json.dumps({'pid': os.getpid()}))
signal.pause()
''',
            'xdotool': '''import json, os, pathlib, sys, time
registry = pathlib.Path(os.environ['FAKE_REGISTRY'])
args = sys.argv[1:]
with (registry / 'calls').open('a') as out: out.write(json.dumps(args) + '\\n')
if args[0] == 'search':
    index = args[-1][-2]
    deadline = time.monotonic() + 3
    while not (registry / (index + '.json')).exists():
        if time.monotonic() >= deadline: sys.exit(1)
        time.sleep(0.01)
    print(101 + int(index))
elif args[0] == 'getwindowpid':
    index = str(int(args[1]) - 101)
    pid = json.loads((registry / (index + '.json')).read_text())['pid']
    print(pid + (1 if os.environ.get('FAKE_WRONG_OWNER') else 0))
''',
            'checker': '''import json, os, pathlib, sys, time
assert sys.argv[1:] == ['--integration-test', 'x11-profiles']
fixture = json.loads(pathlib.Path(os.environ['JSTI_PROFILE_TEST_FIXTURE']).read_text())
registry = pathlib.Path(os.environ['FAKE_REGISTRY'])
(registry / 'checker-started').touch()
if os.environ.get('FAKE_CHECKER_FAIL'): sys.exit(9)
assert fixture['display'] == ':87' and fixture['version'] == 1
assert fixture['targets'][0]['processID'] != fixture['targets'][1]['processID']
assert os.environ['HOME'].startswith(str(pathlib.Path(fixture['signalDirectory']).parent))
signals = pathlib.Path(fixture['signalDirectory'])
(signals / 'ready').touch()
for phase in range(3):
    deadline = time.monotonic() + 3
    while not (signals / ('phase-' + str(phase))).exists():
        if time.monotonic() >= deadline: sys.exit(8)
        time.sleep(0.01)
    (signals / ('ack-' + str(phase))).touch()
(registry / 'three-phases-complete').touch()
'''}
        for name, source in programs.items():
            script = tools / name
            script.write_text('#!' + sys.executable + '\n' + source, encoding='utf-8')
            script.chmod(0o700)
        self.environment.update(PATH=str(tools) + os.pathsep + self.environment['PATH'], FAKE_REGISTRY=str(registry))
        return tools, registry

    def assert_owned_children_reaped(self, registry):
        for child in registry.glob('[01].json'):
            pid = json.loads(child.read_text(encoding='utf-8'))['pid']
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)

    def test_real_harness_three_signalled_phases_and_owned_cleanup_preserve_unrelated_child(self):
        tools, registry = self.install_fake_tools()
        unrelated = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'], start_new_session=True)
        try:
            with patch.object(CHECKS, 'admit_display'):
                CHECKS.run(tools / 'checker', self.environment)
            self.assertIsNone(unrelated.poll())
            self.assertTrue((registry / 'three-phases-complete').exists())
            calls = [json.loads(line) for line in (registry / 'calls').read_text(encoding='utf-8').splitlines()]
            self.assertEqual([call[-1] for call in calls if call[0] == 'windowactivate'], ['101', '102', '101'])
            self.assert_owned_children_reaped(registry)
        finally:
            os.killpg(unrelated.pid, signal.SIGTERM)
            unrelated.wait(timeout=3)

    def test_foreign_window_owner_refused_before_checker_and_owned_child_reaped(self):
        tools, registry = self.install_fake_tools()
        with patch.object(CHECKS, 'admit_display'), self.assertRaisesRegex(RuntimeError, 'exact child'):
            CHECKS.run(tools / 'checker', dict(self.environment, FAKE_WRONG_OWNER='1'))
        self.assertFalse((registry / 'checker-started').exists())
        self.assert_owned_children_reaped(registry)

    def test_early_checker_failure_reaps_all_owned_window_processes(self):
        tools, registry = self.install_fake_tools()
        with patch.object(CHECKS, 'admit_display'), self.assertRaisesRegex(RuntimeError, 'exited'):
            CHECKS.run(tools / 'checker', dict(self.environment, FAKE_CHECKER_FAIL='1'))
        self.assert_owned_children_reaped(registry)

    def test_missing_stage_has_a_deadline(self):
        with patch.object(CHECKS.time, 'monotonic', side_effect=[0, 21]):
            with self.assertRaises(TimeoutError):
                CHECKS.wait_file(self.root / 'absent', type('Running', (), {'poll': lambda self: None})())


if __name__ == '__main__':
    unittest.main()
