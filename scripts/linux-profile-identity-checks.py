#!/usr/bin/env python3
"""Qualify real X11 profile identities only on the caller's owned private Xvfb."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time


def admit_display(environment, parent=None, proc=Path('/proc')):
    """Refuse an ambient/personal DISPLAY before starting a fixture process."""
    display = environment.get('DISPLAY', '')
    pid = environment.get('JSTI_PROFILE_OWNED_DISPLAY_PID', '')
    if not display.startswith(':') or environment.get('JSTI_PROFILE_OWNED_DISPLAY') != display or not pid.isdecimal():
        raise ValueError('An explicitly owned private Xvfb session is required')
    process = proc / pid
    stat = (process / 'stat').read_text(encoding='utf-8').rsplit(')', 1)[1].split()
    args = (process / 'cmdline').read_bytes().split(b'\0')
    if (int(stat[1]) != (os.getppid() if parent is None else parent)
            or len(args) < 2 or Path(os.fsdecode(args[0])).name != 'Xvfb' or os.fsdecode(args[1]) != display):
        raise ValueError('The selected Xvfb must be the integration caller\'s own child for this DISPLAY')


def wait_file(path, process, seconds=20):
    deadline = time.monotonic() + seconds
    while not path.is_file():
        if process.poll() is not None:
            raise RuntimeError('The profile checker exited before its signalled stage')
        if time.monotonic() >= deadline:
            raise TimeoutError('The profile checker did not acknowledge its bounded stage')
        time.sleep(0.01)


def stop_owned(process):
    """Reap only a child this harness created, including on a failed stage."""
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=3)


def run(binary, environment=None):
    environment = dict(os.environ if environment is None else environment)
    admit_display(environment)
    zenity = shutil.which('zenity', path=environment.get('PATH'))
    xdotool = shutil.which('xdotool', path=environment.get('PATH'))
    if not zenity or not xdotool:
        raise RuntimeError('Zenity and xdotool are required; this integration check cannot skip')
    processes = []
    with tempfile.TemporaryDirectory(prefix='jsti-profile-identity-') as folder:
        root = Path(folder)
        for name in ['home', 'data', 'config', 'signals']:
            (root / name).mkdir(mode=0o700)
        environment.update(HOME=str(root / 'home'), XDG_DATA_HOME=str(root / 'data'),
                           XDG_CONFIG_HOME=str(root / 'config'))
        try:
            targets = []
            for index in range(2):
                executable = root / f'Profile-{index}'
                shutil.copy2(zenity, executable)
                title = f'JSTI owned profile {root.name} {index}'
                process = subprocess.Popen([str(executable), '--entry', '--title', title, '--text', 'Owned fixture'],
                                           env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                           start_new_session=True)
                processes.append(process)
                window = subprocess.check_output([xdotool, 'search', '--sync', '--name', '^' + title + '$'],
                                                 env=environment, timeout=15, text=True).strip().splitlines()
                if len(window) != 1 or not window[0].isdecimal():
                    raise RuntimeError('Each owned profile process must expose exactly one window')
                owner = subprocess.check_output([xdotool, 'getwindowpid', window[0]], env=environment,
                                                timeout=5, text=True).strip()
                if owner != str(process.pid):
                    raise RuntimeError('A profile window does not belong to the exact child launched by this harness')
                targets.append({'window': int(window[0]), 'processID': process.pid, 'executable': str(executable)})
            fixture = root / 'fixture.json'
            fixture.write_text(json.dumps({'version': 1, 'display': environment['DISPLAY'],
                                           'signalDirectory': str(root / 'signals'), 'targets': targets}), encoding='utf-8')
            environment['JSTI_PROFILE_TEST_FIXTURE'] = str(fixture)
            checker = subprocess.Popen([str(binary), '--integration-test', 'x11-profiles'], env=environment,
                                       stdin=subprocess.DEVNULL, start_new_session=True)
            processes.append(checker)
            wait_file(root / 'signals/ready', checker)
            for phase, index in enumerate([0, 1, 0]):
                subprocess.run([xdotool, 'windowactivate', '--sync', str(targets[index]['window'])],
                               env=environment, timeout=10, check=True)
                (root / f'signals/phase-{phase}').touch(exist_ok=False)
                wait_file(root / f'signals/ack-{phase}', checker)
            if checker.wait(timeout=10) != 0:
                raise RuntimeError('The native X11 profile checker failed')
            print('Owned X11 profile fixture: all three native stages acknowledged; child cleanup required.')
        finally:
            cleanup_errors = []
            for process in reversed(processes):
                try:
                    stop_owned(process)
                except (OSError, subprocess.TimeoutExpired) as error:
                    cleanup_errors.append(type(error).__name__)
            if cleanup_errors:
                raise RuntimeError('Owned profile child cleanup failed: ' + ', '.join(cleanup_errors))


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: linux-profile-identity-checks.py <SpeakLinux>')
    run(Path(sys.argv[1]).resolve())
