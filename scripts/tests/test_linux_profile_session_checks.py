import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch


SCRIPTS = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), SCRIPTS / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CHECKS = load('linux-profile-session-checks')
GUARD = load('linux-profile-session-guard')


class RecordedProfileFixtureTests(unittest.TestCase):
    def testSessionPropertiesUseOnlyActualUIDAndExplicitUnlockedActiveValues(self):
        self.assertEqual(GUARD.session_properties(os.getuid()), {
            'Active': True, 'LockedHint': False, 'User': (os.getuid(), '/org/freedesktop/login1/user/self')})
        for invalid in [True, str(os.getuid()), os.getuid() + 1]:
            with self.assertRaises(ValueError):
                GUARD.session_properties(invalid)

    def testSessionAdmissionBindsRequestedCallerPIDParentAndAllUIDs(self):
        with tempfile.TemporaryDirectory() as folder:
            proc = Path(folder)
            (proc / '123').mkdir()
            status = proc / '123/status'
            uid = os.getuid()
            status.write_text(f'PPid:\t42\nUid:\t{uid}\t{uid}\t{uid}\t{uid}\n', encoding='utf-8')
            self.assertTrue(GUARD.admit_request(123, 42, uid, 123, proc))
            self.assertFalse(GUARD.admit_request(123, 42, uid, 456, proc))
            self.assertFalse(GUARD.admit_request(123, 99, uid, 123, proc))
            status.write_text(f'PPid:\t42\nUid:\t{uid}\t{uid + 1}\t{uid}\t{uid}\n', encoding='utf-8')
            self.assertFalse(GUARD.admit_request(123, 42, uid, 123, proc))

    def testPulseAdmissionRefusesAmbientServerAndMismatchedPrivateRuntime(self):
        with tempfile.TemporaryDirectory() as folder:
            proc = Path(folder)
            (proc / '123').mkdir()
            (proc / '123/stat').write_text('123 (pipewire-pulse) S 42 0\n', encoding='utf-8')
            (proc / '123/cmdline').write_bytes(b'/usr/bin/pipewire-pulse\0')
            (proc / '123/environ').write_bytes(b'XDG_RUNTIME_DIR=/owned/runtime\0')
            env = {'JSTI_PROFILE_OWNED_PULSE_PID': '123', 'XDG_RUNTIME_DIR': '/owned/runtime'}
            CHECKS.admit_pulse(env, parent=42, proc=proc)
            for changed, parent in [(dict(env, XDG_RUNTIME_DIR='/personal'), 42), (env, 99), ({}, 42)]:
                with self.assertRaises((ValueError, OSError)):
                    CHECKS.admit_pulse(changed, parent=parent, proc=proc)

    def testPrivateBusAddressIsExactAndBounded(self):
        for value, valid in [(b'unix:path=/owned/bus,guid=abc\n', True),
                             (b'unix:path=/personal/bus,guid=abc\n', False), (b'x' * 17000 + b'\n', False)]:
            read, write = os.pipe()
            def produce():
                try:
                    with os.fdopen(write, 'wb') as writer:
                        writer.write(value)
                except BrokenPipeError:
                    pass
            producer = threading.Thread(target=produce)
            producer.start()
            try:
                with os.fdopen(read, 'rb') as output:
                    process = Mock(stdout=output, poll=Mock(return_value=None))
                    if valid:
                        self.assertEqual(CHECKS.bus_address(process, 'unix:path=/owned/bus'), value.decode().strip())
                    else:
                        with self.assertRaises(ValueError):
                            CHECKS.bus_address(process, 'unix:path=/owned/bus')
            finally:
                producer.join(timeout=1)
                self.assertFalse(producer.is_alive(), 'The owned pipe producer did not exit')

    def testAmbientDisplayFailsBeforeAnyChildOrAudioCommand(self):
        with patch.object(CHECKS.identity, 'admit_display', side_effect=ValueError('ambient display')), \
                patch.object(CHECKS.subprocess, 'Popen') as child, patch.object(CHECKS.subprocess, 'run') as command:
            with self.assertRaisesRegex(ValueError, 'ambient display'):
                CHECKS.run(Path('/never-executed'))
            child.assert_not_called()
            command.assert_not_called()

    def testSIGTERMReapsOnlyOwnedPeerProcessesDuringActualFixtureFinally(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            script = root / 'controlled.py'
            ready = root / 'ready.json'
            audio = root / 'fixture.wav'
            audio.write_bytes(b'owned synthetic fixture; never played')
            script.write_text('''import importlib.util,json,os,subprocess,sys,time
from pathlib import Path
from unittest.mock import Mock
spec=importlib.util.spec_from_file_location("checks",sys.argv[1]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
m.identity.admit_display=lambda env:None
m.admit_pulse=lambda env:None
m.shutil.which=lambda *args,**kwargs:sys.executable
m.bus_address=lambda process,address:address
real_popen=subprocess.Popen
owned=[]
def spawn(*args,**kwargs):
 p=real_popen([sys.executable,"-c","import time;time.sleep(60)",sys.argv[4]],start_new_session=True)
 owned.append(p.pid)
 return p
m.subprocess.Popen=spawn
m.subprocess.run=lambda *args,**kwargs:Mock(stdout='[{"name":"jsti_test.monitor"}]')
def held(*args,**kwargs):
 Path(sys.argv[2]).write_text(json.dumps(owned));time.sleep(60)
m.identity.wait_file=held
os.environ["JSTI_WHISPER_TEST_AUDIO"]=sys.argv[3]
os.environ["JSTI_LOCAL_MODEL_DIRECTORY"]=sys.argv[4]
m.install_signal_handlers()
m.run(Path("/never-executed"))
''', encoding='utf-8')
            process = subprocess.Popen([sys.executable, '-B', str(script), str(SCRIPTS / 'linux-profile-session-checks.py'),
                                        str(ready), str(audio), str(root)], start_new_session=True,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            children = []
            reaped = set()
            try:
                deadline = time.monotonic() + 5
                while not ready.exists():
                    if process.poll() is not None or time.monotonic() >= deadline:
                        self.fail('The controlled fixture never reached its held peer stage')
                    time.sleep(0.01)
                children = json.loads(ready.read_text(encoding='utf-8'))
                self.assertEqual(len(children), 2)
                os.kill(process.pid, signal.SIGTERM)
                stdout, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 143, stdout + stderr)
                for pid in children:
                    with self.assertRaises(ProcessLookupError):
                        os.kill(pid, 0)
                    reaped.add(pid)
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                process.communicate(timeout=5)
                for pid in children:
                    if pid in reaped:
                        continue
                    try:
                        command = subprocess.run(['ps', '-p', str(pid), '-o', 'command='], capture_output=True,
                                                 text=True, timeout=2).stdout
                        if str(root) in command and os.getpgid(pid) == pid:
                            os.killpg(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass


if __name__ == '__main__':
    unittest.main()
