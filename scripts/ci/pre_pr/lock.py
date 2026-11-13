"""The machine-wide lock that serialises the heavy part of pre-pr runs for one user."""
from __future__ import annotations

import contextlib
import os
import time
from pathlib import Path

# A few heavy phases at a time per user on this machine, across every worktree:
# several agents running the macOS build, Lint tooling tests and Swift tests at
# once drove load past 300 and turned timing-sensitive tests into false failures,
# while one at a time left agents queueing for an hour. JSTI_PRE_PR_SLOTS runs
# (default 2) hold it at once; each slot has its own build mirror and container
# volume, so the runs share no build state.
# Only checks marked exclusive (runner.Check) take it; autofix, cheap checks and
# remote GitHub runs never wait for it.
# JSTI_PRE_PR_LOCK=off disables it; any other value is the lock file path.
LOCK_PATH = Path.home() / '.cache' / 'jsti-pre-pr.lock'


def slot_count() -> int:
    try:
        return max(1, int(os.environ.get('JSTI_PRE_PR_SLOTS', '2')))
    except ValueError:
        return 1


def slot_path(path: Path, slot: int) -> Path:
    """Slot 0 is the original lock file, so older pre-pr versions still exclude slot 0's mirror."""
    return path if slot == 0 else path.with_name(f'{path.name}.{slot}')


@contextlib.contextmanager
def machine_lock(setting: str | None = None, slots: int | None = None, poll: float = 1.0):
    """Hold one of the slots; yields its number (0 when the lock is off)."""
    setting = os.environ.get('JSTI_PRE_PR_LOCK', '') if setting is None else setting
    try:
        import fcntl
    except ImportError:  # Windows: no flock; run unlocked.
        fcntl = None
    if setting == 'off' or fcntl is None:
        yield 0
        return
    path = Path(setting) if setting else LOCK_PATH
    path.parent.mkdir(parents=True, exist_ok=True)
    count = slot_count() if slots is None else slots
    handles = [open(slot_path(path, slot), 'a+', encoding='utf-8') for slot in range(count)]
    try:
        slot, waited = None, None
        while slot is None:
            for index, handle in enumerate(handles):
                try:
                    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    slot = index
                    break
                except BlockingIOError:
                    continue
            if slot is None:
                if waited is None:
                    waited = time.monotonic()
                    holders = []
                    for handle in handles:
                        handle.seek(0)
                        holders.append(handle.read().strip() or 'another worktree')
                    print(f'pre-pr: waiting for the machine-wide lock ({count} slot(s)) held by '
                          f'{"; ".join(holders)} (set JSTI_PRE_PR_LOCK=off to skip)', flush=True)
                time.sleep(poll)
        if waited is not None:
            print(f'pre-pr: lock acquired after {time.monotonic() - waited:.0f}s', flush=True)
        handle = handles[slot]
        handle.seek(0)
        handle.truncate()
        handle.write(f'pid {os.getpid()} in {Path.cwd()}\n')
        handle.flush()
        try:
            yield slot
        finally:
            handle.seek(0)
            handle.truncate()
            fcntl.flock(handle, fcntl.LOCK_UN)
    finally:
        for handle in handles:
            handle.close()
