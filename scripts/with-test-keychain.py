#!/usr/bin/env python3
"""Run a command against a disposable macOS Keychain, then restore the user's configuration.

Usage:
    with-test-keychain.py command [arguments...]
    with-test-keychain.py --repair

The swap only happens in CI (``CI`` or ``GITHUB_ACTIONS`` set) or when
``JSTI_TEST_KEYCHAIN=1``. Any other explicit ``JSTI_TEST_KEYCHAIN`` value
disables it. Otherwise the command runs unchanged, so local runs never touch
the developer's Keychain.

While swapping, the user default Keychain and search list point only at the
temporary Keychain. Invariants that keep a developer machine safe:

* Overlapping runs serialise on an exclusive per-user lock held for the whole
  run, so no run can snapshot another run's temporary Keychain as "original".
* Originals are sanitised: the exact journal-owned temporary Keychain and
  missing Keychains are never restored, and ``login.keychain-db`` is kept.
* The originals are journalled before swapping; a run killed with SIGKILL is
  repaired by the next run (or ``--repair``) before anything else happens.
* SIGTERM, SIGHUP and SIGINT are forwarded to the command's own process group,
  which is waited on and SIGKILLed after a grace period before restoration.
  A recovering run stops a journalled group only when its boot and process
  identity still match; it never signals an unverified reused process-group ID.
"""
import errno
import fcntl
import json
import os
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

TEMP_PREFIX = 'jsti-ci-keychain-'
OWNERSHIP_MARKER = '.jsti-test-keychain'
JOURNAL_VERSION = 2
RUN_TOKEN_ENV = 'JSTI_TEST_KEYCHAIN_RUN_TOKEN'
HANDLED_SIGNALS = (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)
FALSE_VALUES = {'', '0', 'false', 'no', 'off'}


class Interrupted(Exception):
    pass


class RestoreFailed(Exception):
    pass


def security_binary():
    return os.environ.get('JSTI_TEST_KEYCHAIN_SECURITY', '/usr/bin/security')


def security(*args):
    timeout = float(os.environ.get('JSTI_TEST_KEYCHAIN_SECURITY_TIMEOUT_SECONDS', '30'))
    return subprocess.check_output(
        [security_binary(), *args],
        text=True,
        timeout=timeout,
    ).strip()


def state_directory():
    override = os.environ.get('JSTI_TEST_KEYCHAIN_STATE_DIR')
    if override:
        return Path(override)
    return Path.home() / 'Library' / 'Application Support' / 'com.justspeaktoit.test-keychain'


def login_keychain():
    return str(Path.home() / 'Library' / 'Keychains' / 'login.keychain-db')


def truthy(value):
    return value is not None and value.strip().lower() not in FALSE_VALUES


def swap_enabled(environ=os.environ):
    explicit = environ.get('JSTI_TEST_KEYCHAIN')
    if explicit is not None:
        return explicit.strip() == '1'
    return truthy(environ.get('CI')) or truthy(environ.get('GITHUB_ACTIONS'))


def same_path(left, right):
    return os.path.realpath(left) == os.path.realpath(right)


def is_owned(path, owned):
    return bool(path) and any(same_path(path, candidate) for candidate in owned if candidate)


def usable(path, owned=()):
    return bool(path) and not is_owned(path, owned) and os.path.exists(path)


def sanitise(default, search, owned=()):
    """Return settings without missing or exactly journal-owned Keychains."""
    login = login_keychain()
    cleaned = []
    for path in search:
        if usable(path, owned) and not any(same_path(path, kept) for kept in cleaned):
            cleaned.append(path)
    if os.path.exists(login) and not any(same_path(login, kept) for kept in cleaned):
        cleaned.insert(0, login)
    if not usable(default, owned):
        default = login if os.path.exists(login) else (cleaned[0] if cleaned else None)
    return default, cleaned


def current_configuration():
    default_output = shlex.split(security('default-keychain', '-d', 'user'))
    default = default_output[0] if default_output else None
    search = shlex.split(security('list-keychains', '-d', 'user'))
    return default, search


def apply_configuration(default, search, forbidden=()):
    """Set the user search list and default, then verify forbidden Keychains are absent."""
    errors = []
    try:
        security('list-keychains', '-d', 'user', '-s', *search)
    except (subprocess.SubprocessError, OSError) as error:
        errors.append(f'list-keychains: {error}')
    if default:
        try:
            security('default-keychain', '-d', 'user', '-s', default)
        except (subprocess.SubprocessError, OSError) as error:
            errors.append(f'default-keychain: {error}')
    try:
        actual_default, actual_search = current_configuration()
        if any(is_owned(path, forbidden) for path in actual_search):
            errors.append(f'search list still references a forbidden Keychain: {actual_search}')
        if actual_default and is_owned(actual_default, forbidden):
            errors.append(f'default Keychain is still forbidden: {actual_default}')
        if default and actual_default and not same_path(actual_default, default):
            errors.append(f'default Keychain is {actual_default}, expected {default}')
    except (subprocess.SubprocessError, OSError) as error:
        errors.append(f'verification: {error}')
    if errors:
        raise RestoreFailed('; '.join(errors))


def delete_temporary_keychain(keychain):
    if not keychain:
        return
    directory = Path(keychain).parent
    marker = directory / OWNERSHIP_MARKER
    try:
        owned = marker.read_text(encoding='utf-8').strip()
    except OSError:
        return
    if not owned or not same_path(keychain, owned):
        return
    if os.path.exists(keychain):
        try:
            security('delete-keychain', keychain)
        except (subprocess.SubprocessError, OSError) as error:
            print(f'with-test-keychain: could not delete {keychain}: {error}', file=sys.stderr)
            return
    shutil.rmtree(directory, ignore_errors=True)


def journal_path():
    return state_directory() / 'state.json'


def boot_identifier():
    linux_id = Path('/proc/sys/kernel/random/boot_id')
    if linux_id.exists():
        return linux_id.read_text(encoding='utf-8').strip()
    return subprocess.check_output(
        ['/usr/sbin/sysctl', '-n', 'kern.boottime'],
        text=True,
        timeout=5,
    ).strip()


def process_identity(pid):
    try:
        return subprocess.check_output(
            ['/bin/ps', '-o', 'lstart=', '-p', str(pid)],
            text=True,
            timeout=5,
        ).strip() or None
    except (subprocess.SubprocessError, OSError):
        return None


def write_journal(
    default,
    search,
    keychain,
    child_group=None,
    child_identity=None,
    child_token=None,
):
    path = journal_path()
    temporary = path.with_suffix('.json.tmp')
    state = {
        'version': JOURNAL_VERSION,
        'default': default,
        'search': search,
        'keychain': keychain,
        'pid': os.getpid(),
        'boot': boot_identifier(),
        'group': child_group,
        'child_identity': child_identity,
        'child_token': child_token,
    }
    with open(temporary, 'w', encoding='utf-8') as handle:
        json.dump(state, handle)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def clear_journal():
    try:
        journal_path().unlink()
    except FileNotFoundError:
        pass


def read_journal(path):
    try:
        state = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError) as error:
        raise RestoreFailed(
            f'cannot read recovery journal {path}; settings were left unchanged: {error}'
        ) from error
    required = {
        'version': int,
        'default': (str, type(None)),
        'search': list,
        'keychain': str,
        'boot': str,
        'group': (int, type(None)),
        'child_identity': (str, type(None)),
        'child_token': (str, type(None)),
    }
    if state.get('version') != JOURNAL_VERSION or any(
        not isinstance(state.get(key), expected) for key, expected in required.items()
    ) or not all(isinstance(item, str) for item in state['search']):
        raise RestoreFailed(
            f'recovery journal {path} is incomplete; settings were left unchanged'
        )
    return state


def verified_recovery_group(state):
    group = state['group']
    identity = state['child_identity']
    token = state['child_token']
    if (
        not isinstance(group, int)
        or group <= 1
        or group == os.getpgrp()
        or not identity
        or not token
    ):
        return None
    if state['boot'] != boot_identifier():
        return None
    if process_identity(group) != identity:
        return None
    try:
        environment = subprocess.check_output(
            ['/bin/ps', 'eww', '-p', str(group), '-o', 'command='],
            text=True,
            timeout=5,
        )
    except (subprocess.SubprocessError, OSError):
        return None
    if f'{RUN_TOKEN_ENV}={token}' not in environment.split():
        return None
    return group


def recover_from_journal():
    """Restore the configuration left behind by a run that died without cleaning up."""
    path = journal_path()
    if not path.exists():
        return False
    state = read_journal(path)
    print('with-test-keychain: recovering Keychain configuration from an interrupted run', file=sys.stderr)
    group = verified_recovery_group(state)
    if group is not None:
        terminate_group(group, signal.SIGTERM)
    default, search = sanitise(state['default'], state['search'], owned=[state['keychain']])
    apply_configuration(default, search, forbidden=[state['keychain']])
    delete_temporary_keychain(state['keychain'])
    clear_journal()
    return True


def acquire_lock():
    directory = state_directory()
    directory.mkdir(parents=True, exist_ok=True)
    handle = open(directory / 'lock', 'a+', encoding='utf-8')
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as error:
        if error.errno not in (errno.EWOULDBLOCK, errno.EAGAIN, errno.EACCES):
            raise
        print('with-test-keychain: waiting for another run to release the test Keychain', file=sys.stderr)
        fcntl.flock(handle, fcntl.LOCK_EX)
    return handle


def group_alive(group):
    try:
        os.killpg(group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def signal_group(group, signum):
    try:
        os.killpg(group, signum)
    except (ProcessLookupError, PermissionError):
        pass


def terminate_group(group, signum, leader=None):
    """Signal a process group, wait for it to exit and SIGKILL whatever outlives the grace period."""
    signal_group(group, signum)
    deadline = time.monotonic() + grace_seconds()
    while time.monotonic() < deadline:
        if leader is not None:
            leader.poll()
        if not group_alive(group):
            return
        time.sleep(0.05)
    signal_group(group, signal.SIGKILL)
    if leader is not None:
        leader.wait()
    deadline = time.monotonic() + grace_seconds()
    while group_alive(group) and time.monotonic() < deadline:
        time.sleep(0.05)


def grace_seconds():
    return float(os.environ.get('JSTI_TEST_KEYCHAIN_GRACE_SECONDS', '5'))


def supervise(child, signals):
    """Wait for the command; on a signal, stop its whole process group before returning."""
    while True:
        try:
            returncode = child.wait(timeout=0.1)
            break
        except subprocess.TimeoutExpired:
            if signals.received is not None:
                terminate_group(child.pid, signals.received, leader=child)
    # Never restore while a process in the command's group may still use the test Keychain.
    if group_alive(child.pid):
        terminate_group(child.pid, signal.SIGTERM)
    return returncode


def launch_gated(command, token):
    """Launch a new process group that cannot exec the command before journalling."""
    read_fd, write_fd = os.pipe()
    gate = (
        'import os,sys; '
        'fd=int(sys.argv[1]); token=os.read(fd,1); os.close(fd); '
        'token == b"1" or sys.exit(75); '
        'os.execvp(sys.argv[2], sys.argv[2:])'
    )
    try:
        environment = dict(os.environ)
        environment[RUN_TOKEN_ENV] = token
        child = subprocess.Popen(
            [sys.executable, '-c', gate, str(read_fd), *command],
            start_new_session=True,
            pass_fds=(read_fd,),
            env=environment,
        )
    finally:
        os.close(read_fd)
    return child, write_fd


def exit_status(returncode):
    return 128 - returncode if returncode < 0 else returncode


class SignalState:
    def __init__(self):
        self.received = None
        self.raise_on_signal = True

    def handle(self, signum, frame):
        self.received = signum
        if self.raise_on_signal:
            raise Interrupted(signum)


def repair():
    lock = acquire_lock()
    try:
        recover_from_journal()
        before = current_configuration()
        default, search = sanitise(*before)
        apply_configuration(default, search)
        print(f'with-test-keychain: default Keychain {default}; search list {search}')
        return 0
    finally:
        lock.close()


def run_isolated(command):
    signals = SignalState()
    for signum in HANDLED_SIGNALS:
        signal.signal(signum, signals.handle)
    lock = None
    try:
        lock = acquire_lock()
        recover_from_journal()
        # Snapshot only while holding the lock, so another run's Keychain is never mistaken for ours.
        original_default, original_search = sanitise(*current_configuration())
        directory = Path(tempfile.mkdtemp(prefix=TEMP_PREFIX))
        keychain = str(directory / 'tests.keychain-db')
        (directory / OWNERSHIP_MARKER).write_text(keychain, encoding='utf-8')
        write_journal(original_default, original_search, keychain)
        child = None
        gate_fd = None
        try:
            password = secrets.token_urlsafe(32)
            security('create-keychain', '-p', password, keychain)
            security('set-keychain-settings', '-lut', '21600', keychain)
            security('unlock-keychain', '-p', password, keychain)
            security('list-keychains', '-d', 'user', '-s', keychain)
            security('default-keychain', '-d', 'user', '-s', keychain)
            signals.raise_on_signal = False
            child_token = secrets.token_hex(32)
            child, gate_fd = launch_gated(command, child_token)
            identity = process_identity(child.pid)
            if not identity:
                raise RestoreFailed(f'could not identify launched command process {child.pid}')
            write_journal(
                original_default,
                original_search,
                keychain,
                child_group=child.pid,
                child_identity=identity,
                child_token=child_token,
            )
            os.write(gate_fd, b'1')
            os.close(gate_fd)
            gate_fd = None
            return exit_status(supervise(child, signals))
        finally:
            signals.raise_on_signal = False
            if gate_fd is not None:
                os.close(gate_fd)
            if child is not None and child.poll() is None:
                terminate_group(child.pid, signal.SIGTERM, leader=child)
            apply_configuration(original_default, original_search, forbidden=[keychain])
            delete_temporary_keychain(keychain)
            clear_journal()
    except Interrupted as interruption:
        return 128 + interruption.args[0]
    finally:
        if lock is not None:
            lock.close()


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if not argv:
        raise SystemExit('Usage: with-test-keychain.py command [arguments...] | --repair')
    try:
        if argv == ['--repair']:
            return repair()
        if not swap_enabled():
            os.execvp(argv[0], argv)
        return run_isolated(argv)
    except RestoreFailed as error:
        print(f'with-test-keychain: failed to restore Keychain configuration: {error}', file=sys.stderr)
        print('with-test-keychain: run `python3 scripts/with-test-keychain.py --repair`', file=sys.stderr)
        return 70


if __name__ == '__main__':
    sys.exit(main())
