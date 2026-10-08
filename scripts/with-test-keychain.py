#!/usr/bin/env python3
"""Run a command against a disposable macOS Keychain, then restore the user's configuration.

Usage:
    with-test-keychain.py command [arguments...]
    with-test-keychain.py --repair

The swap only happens in CI (``CI`` or ``GITHUB_ACTIONS`` set) or when
``JSTI_TEST_KEYCHAIN=1``; ``JSTI_TEST_KEYCHAIN=0`` disables it. Otherwise the
command runs unchanged, so local runs never touch the developer's Keychain.

While swapping, the user default Keychain and search list point only at the
temporary Keychain. Invariants that keep a developer machine safe:

* Overlapping runs serialise on an exclusive per-user lock held for the whole
  run, so no run can snapshot another run's temporary Keychain as "original".
* Originals are sanitised: temporary (``jsti-ci-keychain-``) or missing
  Keychains are never restored, and ``login.keychain-db`` is always kept.
* The originals are journalled before swapping; a run killed with SIGKILL is
  repaired by the next run (or ``--repair``) before anything else happens.
* SIGTERM, SIGHUP and SIGINT are forwarded to the command's own process group,
  which is waited on (SIGKILLed after a grace period) and swept for surviving
  descendants before restoration; the temporary Keychain is deleted last. A
  recovering run also stops any process group left by a SIGKILLed wrapper.
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
HANDLED_SIGNALS = (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)
FALSE_VALUES = {'', '0', 'false', 'no', 'off'}


class Interrupted(Exception):
    pass


class RestoreFailed(Exception):
    pass


def security_binary():
    return os.environ.get('JSTI_TEST_KEYCHAIN_SECURITY', '/usr/bin/security')


def security(*args):
    return subprocess.check_output([security_binary(), *args], text=True).strip()


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
        return truthy(explicit)
    return truthy(environ.get('CI')) or truthy(environ.get('GITHUB_ACTIONS'))


def is_temporary(path):
    return TEMP_PREFIX in path


def usable(path):
    return bool(path) and not is_temporary(path) and os.path.exists(path)


def same_path(left, right):
    return os.path.realpath(left) == os.path.realpath(right)


def sanitise(default, search):
    """Return a (default, search list) pair that never references a temporary or missing Keychain."""
    login = login_keychain()
    cleaned = []
    for path in search:
        if usable(path) and not any(same_path(path, kept) for kept in cleaned):
            cleaned.append(path)
    if os.path.exists(login) and not any(same_path(login, kept) for kept in cleaned):
        cleaned.insert(0, login)
    if not usable(default):
        default = login if os.path.exists(login) else (cleaned[0] if cleaned else None)
    return default, cleaned


def current_configuration():
    default_output = shlex.split(security('default-keychain', '-d', 'user'))
    default = default_output[0] if default_output else None
    search = shlex.split(security('list-keychains', '-d', 'user'))
    return default, search


def apply_configuration(default, search):
    """Set the user search list and default, then verify no temporary Keychain remains."""
    errors = []
    try:
        security('list-keychains', '-d', 'user', '-s', *search)
    except (subprocess.CalledProcessError, OSError) as error:
        errors.append(f'list-keychains: {error}')
    if default:
        try:
            security('default-keychain', '-d', 'user', '-s', default)
        except (subprocess.CalledProcessError, OSError) as error:
            errors.append(f'default-keychain: {error}')
    try:
        actual_default, actual_search = current_configuration()
        if any(is_temporary(path) for path in actual_search):
            errors.append(f'search list still references a temporary Keychain: {actual_search}')
        if actual_default and is_temporary(actual_default):
            errors.append(f'default Keychain is still temporary: {actual_default}')
        if default and actual_default and not same_path(actual_default, default):
            errors.append(f'default Keychain is {actual_default}, expected {default}')
    except (subprocess.CalledProcessError, OSError) as error:
        errors.append(f'verification: {error}')
    if errors:
        raise RestoreFailed('; '.join(errors))


def delete_temporary_keychain(keychain):
    if not keychain or not is_temporary(keychain):
        return
    if os.path.exists(keychain):
        try:
            security('delete-keychain', keychain)
        except (subprocess.CalledProcessError, OSError) as error:
            print(f'with-test-keychain: could not delete {keychain}: {error}', file=sys.stderr)
    directory = os.path.dirname(keychain)
    if TEMP_PREFIX in os.path.basename(directory):
        shutil.rmtree(directory, ignore_errors=True)


def journal_path():
    return state_directory() / 'state.json'


def write_journal(default, search, keychain, child_group=None):
    path = journal_path()
    temporary = path.with_suffix('.json.tmp')
    state = {'default': default, 'search': search, 'keychain': keychain, 'pid': os.getpid(), 'group': child_group}
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


def recover_from_journal():
    """Restore the configuration left behind by a run that died without cleaning up."""
    path = journal_path()
    if not path.exists():
        return False
    try:
        state = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        state = {}
    print('with-test-keychain: recovering Keychain configuration from an interrupted run', file=sys.stderr)
    group = state.get('group')
    # The previous wrapper is dead (it no longer holds the lock), so any survivor of its
    # command's process group, such as an orphaned xctest, must not run on into this run.
    if isinstance(group, int) and group > 1 and group != os.getpgrp():
        terminate_group(group, signal.SIGTERM)
    default, search = sanitise(state.get('default'), state.get('search') or [])
    apply_configuration(default, search)
    delete_temporary_keychain(state.get('keychain'))
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
    # Never restore while a descendant (such as xctest) may still be using the test Keychain.
    if group_alive(child.pid):
        terminate_group(child.pid, signal.SIGTERM)
    return returncode


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
        keychain = str(Path(tempfile.mkdtemp(prefix=TEMP_PREFIX)) / 'tests.keychain-db')
        write_journal(original_default, original_search, keychain)
        try:
            password = secrets.token_urlsafe(32)
            security('create-keychain', '-p', password, keychain)
            security('set-keychain-settings', '-lut', '21600', keychain)
            security('unlock-keychain', '-p', password, keychain)
            security('list-keychains', '-d', 'user', '-s', keychain)
            security('default-keychain', '-d', 'user', '-s', keychain)
            signals.raise_on_signal = False
            # Own process group, so the whole tree can be stopped and swept before restoring.
            child = subprocess.Popen(command, start_new_session=True)
            write_journal(original_default, original_search, keychain, child_group=child.pid)
            return exit_status(supervise(child, signals))
        finally:
            signals.raise_on_signal = False
            apply_configuration(original_default, original_search)
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
