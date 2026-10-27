#!/usr/bin/env python3
"""Recorded full-host profile qualification inside caller-owned Xvfb/PipeWire."""
import importlib.util
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time

spec = importlib.util.spec_from_file_location('profile_identity', Path(__file__).with_name('linux-profile-identity-checks.py'))
identity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(identity)


def install_signal_handlers():
    def interrupted(number, _frame):
        raise SystemExit(128 + number)
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)


def admit_pulse(environment, parent=None, proc=Path('/proc')):
    pid = environment.get('JSTI_PROFILE_OWNED_PULSE_PID', '')
    if not pid.isdecimal() or not environment.get('XDG_RUNTIME_DIR'):
        raise ValueError('The caller must identify its owned private pipewire-pulse process')
    process = proc / pid
    stat = (process / 'stat').read_text(encoding='utf-8').rsplit(')', 1)[1].split()
    args = (process / 'cmdline').read_bytes().split(b'\0')
    values = dict(value.split(b'=', 1) for value in (process / 'environ').read_bytes().split(b'\0') if b'=' in value)
    if (int(stat[1]) != (os.getppid() if parent is None else parent)
            or Path(os.fsdecode(args[0])).name != 'pipewire-pulse'
            or os.fsdecode(values.get(b'XDG_RUNTIME_DIR', b'')) != environment['XDG_RUNTIME_DIR']):
        raise ValueError('The selected audio server must be the caller\'s own private-runtime child')


def bus_address(process, requested, seconds=5):
    """Read the owned no-fork daemon's address with a byte/time bound."""
    deadline = time.monotonic() + seconds
    data = b''
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        while b'\n' not in data:
            if process.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError('The owned private bus did not become ready')
            if selector.select(timeout=min(0.1, max(0, deadline - time.monotonic()))):
                chunk = os.read(process.stdout.fileno(), 4096)
                if not chunk:
                    raise RuntimeError('The owned private bus closed its address pipe')
                data += chunk
                if len(data) > 16384:
                    raise ValueError('Unexpected oversized private bus address')
    address = data.split(b'\n', 1)[0].decode('utf-8')
    if address.split(',', 1)[0] != requested:
        raise ValueError('The daemon did not bind the exact owned socket')
    return address


def run(binary):
    original = dict(os.environ)
    identity.admit_display(original)
    admit_pulse(original)
    tools = {name: shutil.which(name, path=original.get('PATH'))
             for name in ['zenity', 'xdotool', 'dbus-daemon', 'pactl', 'paplay', 'gdbus']}
    if not all(tools.values()):
        raise RuntimeError('Recorded profile qualification requires every native fixture tool')
    audio = Path(original['JSTI_WHISPER_TEST_AUDIO']).resolve(strict=True)
    model_root = Path(original['JSTI_LOCAL_MODEL_DIRECTORY']).resolve(strict=True)
    deadline = time.monotonic() + 180
    processes = []

    def command(arguments, environment=original, check=True):
        return subprocess.run(arguments, env=environment, stdin=subprocess.DEVNULL, capture_output=True,
                              text=True, check=check, timeout=min(15, max(0.1, deadline - time.monotonic())))

    with tempfile.TemporaryDirectory(prefix='jsti-profile-session-', dir='/tmp') as folder:
        root = Path(folder)
        for name in ['home', 'data', 'config', 'signals']:
            (root / name).mkdir(mode=0o700)
        environment = dict(original, HOME=str(root / 'home'), XDG_DATA_HOME=str(root / 'data'),
                           XDG_CONFIG_HOME=str(root / 'config'))
        # Borrow only the original integration caller's explicitly named test
        # monitor. Do not create/delete devices or change any default audio route.
        sink = 'jsti_test'
        try:
            sources = json.loads(command([tools['pactl'], '--format=json', 'list', 'sources']).stdout)
            if sum(item['name'] == sink + '.monitor' for item in sources) != 1:
                raise ValueError('The caller-owned recorded audio monitor is unavailable')
            address = f'unix:path={root / "bus"}'
            bus = subprocess.Popen([tools['dbus-daemon'], '--session', '--nofork', '--print-address=1',
                                    f'--address={address}'], env=environment, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, start_new_session=True)
            processes.append(bus)
            private = bus_address(bus, address)
            environment.update(DBUS_SESSION_BUS_ADDRESS=private, DBUS_SYSTEM_BUS_ADDRESS=private)
            guard = subprocess.Popen([
                sys.executable, '-B', str(Path(__file__).with_name('linux-profile-session-guard.py')),
                '--address', private, '--bus-path', str(root / 'bus'), '--parent', str(os.getpid()),
                '--uid', str(os.getuid()), '--ready', str(root / 'guard-ready')],
                env=environment, stdin=subprocess.DEVNULL, start_new_session=True)
            processes.append(guard)
            identity.wait_file(root / 'guard-ready', guard, seconds=5)
            ready = json.loads((root / 'guard-ready').read_text(encoding='utf-8'))
            if ready != {'uid': os.getuid(), 'pid': guard.pid, 'parent': os.getpid(), 'address': private}:
                raise ValueError('Private guard readiness identity is not the exact owned child')
            # Exercise a real service refusal; no fabricated successful session
            # can be obtained for a different requested process.
            refused = command([tools['gdbus'], 'call', '--address', private, '--dest', 'org.freedesktop.login1',
                               '--object-path', '/org/freedesktop/login1', '--method',
                               'org.freedesktop.login1.Manager.GetSessionByPID', '1'], environment, check=False)
            if refused.returncode == 0 or 'NoSessionForPID' not in refused.stderr:
                raise RuntimeError('The private guard did not explicitly refuse an unrelated process')
            targets = []
            for index in range(3):
                executable = root / f'Profile-{index}'
                shutil.copy2(tools['zenity'], executable)
                title = f'JSTI recorded profile {root.name} {index}'
                process = subprocess.Popen([str(executable), '--entry', '--title', title, '--text', 'Owned fixture'],
                                           env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                           start_new_session=True)
                processes.append(process)
                windows = command([tools['xdotool'], 'search', '--sync', '--name', '^' + title + '$'],
                                  environment).stdout.strip().splitlines()
                if len(windows) != 1 or not windows[0].isdecimal():
                    raise RuntimeError('Each owned executable must expose exactly one window')
                pid = command([tools['xdotool'], 'getwindowpid', windows[0]], environment).stdout.strip()
                if pid != str(process.pid):
                    raise RuntimeError('A GApplication alias cannot substitute another process')
                targets.append({'window': int(windows[0]), 'processID': process.pid, 'executable': str(executable)})
            fixture = root / 'fixture.json'
            fixture.write_text(json.dumps({
                'version': 1, 'ownerPID': os.getpid(), 'display': environment['DISPLAY'],
                'dataDirectory': str(root / 'data'), 'signalDirectory': str(root / 'signals'),
                'deviceID': sink + '.monitor', 'modelRoot': str(model_root), 'targets': targets}) + '\n',
                encoding='utf-8')
            environment['JSTI_PROFILE_SESSION_FIXTURE'] = str(fixture)
            app = subprocess.Popen([str(binary), '--integration-test', 'x11-profile-session'], env=environment,
                                   stdin=subprocess.DEVNULL, start_new_session=True)
            processes.append(app)

            def wait(name):
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError('The recorded host fixture exceeded its owned 180-second deadline')
                identity.wait_file(root / 'signals' / name, app, seconds=min(45, remaining))

            def phase(name, index):
                command([tools['xdotool'], 'windowactivate', '--sync', str(targets[index]['window'])], environment)
                (root / 'signals' / name).touch(exist_ok=False)

            def play():
                process = subprocess.Popen([tools['paplay'], '--device', sink, str(audio)], env=original,
                                           stdin=subprocess.DEVNULL, start_new_session=True)
                processes.append(process)
                return process

            wait('ready')
            phase('manual', 0)
            wait('manual-capture-ready')
            player = play()
            if player.wait(timeout=min(20, max(0.1, deadline - time.monotonic()))) != 0:
                raise RuntimeError('Recorded manual audio producer failed')
            (root / 'signals/manual-audio-done').touch(exist_ok=False)
            wait('manual-complete')
            phase('automatic', 0)
            wait('automatic-capture-ready')
            player = play()
            if player.wait(timeout=min(20, max(0.1, deadline - time.monotonic()))) != 0:
                raise RuntimeError('Recorded automatic audio producer failed')
            wait('automatic-complete')
            phase('rate', 1)
            wait('rate-capture-ready')
            player = play()
            wait('rate-complete')
            identity.stop_owned(player)
            phase('unavailable-manual', 2)
            wait('unavailable-manual-complete')
            phase('unavailable-arm', 0)
            wait('unavailable-armed')
            phase('unavailable-automatic', 2)
            wait('unavailable-capture-ready')
            player = play()
            wait('unavailable-automatic-complete')
            identity.stop_owned(player)
            phase('owner-loss', 0)
            wait('owner-loss-ready')
            identity.stop_owned(guard)
            wait('complete')
            if app.wait(timeout=min(15, max(0.1, deadline - time.monotonic()))) != 0:
                raise RuntimeError('The actual recorded Linux host pipeline failed')
            print('Owned recorded profile host: manual, automatic, rate refusal, unavailable-model refusals '
                  'and guard-owner-loss stages passed.')
        finally:
            failures = []
            for process in reversed(processes):
                try:
                    identity.stop_owned(process)
                except (OSError, subprocess.TimeoutExpired) as error:
                    failures.append(type(error).__name__)
            if failures:
                raise RuntimeError('Owned recorded fixture cleanup failed: ' + ', '.join(failures))


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: linux-profile-session-checks.py <SpeakLinux>')
    install_signal_handlers()
    run(Path(sys.argv[1]).resolve(strict=True))
