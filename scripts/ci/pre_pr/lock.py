"""The machine-wide lock that serialises the heavy part of pre-pr runs for one user."""
from __future__ import annotations

import contextlib
import os
import time
from pathlib import Path

# One heavy phase at a time per user on this machine, across every worktree: several
# agents running the macOS build, Lint tooling tests and Swift tests at once
# drove load past 300 and turned timing-sensitive tests into false failures.
# Only checks marked exclusive (runner.Check) take it; autofix, cheap checks and
# remote GitHub runs never wait for it.
# JSTI_PRE_PR_LOCK=off disables it; any other value is the lock file path.
LOCK_PATH = Path.home() / '.cache' / 'jsti-pre-pr.lock'


@contextlib.contextmanager
def machine_lock(setting: str | None = None):
    setting = os.environ.get('JSTI_PRE_PR_LOCK', '') if setting is None else setting
    try:
        import fcntl
    except ImportError:  # Windows: no flock; run unlocked.
        fcntl = None
    if setting == 'off' or fcntl is None:
        yield
        return
    path = Path(setting) if setting else LOCK_PATH
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, 'a+', encoding='utf-8') as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            handle.seek(0)
            holder = handle.read().strip() or 'another worktree'
            print(f'pre-pr: waiting for the machine-wide lock held by {holder} '
                  f'(set JSTI_PRE_PR_LOCK=off to skip)', flush=True)
            waited = time.monotonic()
            fcntl.flock(handle, fcntl.LOCK_EX)
            print(f'pre-pr: lock acquired after {time.monotonic() - waited:.0f}s', flush=True)
        handle.seek(0)
        handle.truncate()
        handle.write(f'pid {os.getpid()} in {Path.cwd()}\n')
        handle.flush()
        try:
            yield
        finally:
            handle.seek(0)
            handle.truncate()
            fcntl.flock(handle, fcntl.LOCK_UN)
