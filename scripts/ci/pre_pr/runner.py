"""One check's lifecycle: launch it with its output in its log (or settle it at
once), wait for it, classify the result through scripts/ci/pre_pr_outcome.py
and undo any tracked-file side effects it left behind."""
from __future__ import annotations

import contextlib
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

from pre_pr import environment
from pre_pr.environment import ROOT, display, git, outcomes


@dataclass
class Check:
    id: str
    area: str
    title: str
    command: list[str]
    cwd: Path = ROOT
    env: dict[str, str] = field(default_factory=dict)
    advisory: bool = False
    requires: str | None = None
    skip_reason: str = ''
    failure: str = ''          # a planning failure: the check fails without running
    counts_tests: bool = False  # fail when the run executes zero tests
    background: bool = False    # started first and awaited last (the remote/container Linux run)
    exclusive: bool = True      # loads this machine (builds, tests), so it runs under the machine-wide lock
    forbid_drift: tuple[str, ...] = ()  # tracked files the check must not modify (CI's drift checks)
    incomplete: bool = False    # a required check deliberately not run: the result is 'incomplete'
    status: str = 'pending'
    duration: float = 0.0
    note: str = ''
    started: float = 0.0
    dirty_before: set = field(default_factory=set)

    @property
    def log(self) -> Path:
        return environment.OUT / 'logs' / f'{self.id}.log'


def settle(check: Check, outcome) -> None:
    check.status, check.note = outcome.status, outcome.note


def dirty_tracked() -> set[str]:
    return set(filter(None, git('diff', '--name-only', 'HEAD').splitlines()))


def restore_side_effects(check: Check, dirty_before: set[str]) -> None:
    """Undo tracked-file changes a check made (the portable graph deletes Package.resolved)."""
    touched = sorted(dirty_tracked() - dirty_before)
    if touched:
        git('checkout', 'HEAD', '--', *touched)
        restored = f'restored {", ".join(touched[:3])}{"…" if len(touched) > 3 else ""}'
        check.note = f'{check.note}; {restored}' if check.note else restored


def tests_executed(log: str) -> int:
    """Tests run according to XCTest ("Executed N tests") and Swift Testing ("Test run with N tests")."""
    xctest = [int(n) for n in re.findall(r'Executed (\d+) tests?', log)]
    testing = [int(n) for n in re.findall(r'Test run with (\d+) tests?', log)]
    return max(xctest, default=0) + max(testing, default=0)


def launch(check: Check) -> subprocess.Popen | None:
    """Start a check with its output going to its log, or settle it at once (skip, planning failure, no tool)."""
    missing = check.requires if check.requires and not shutil.which(check.requires) else None
    settled = outcomes().before_launch(skip_reason=check.skip_reason, failure=check.failure,
                                       missing_tool=missing, advisory=check.advisory)
    if settled is not None:
        settle(check, settled)
        return None
    check.log.parent.mkdir(parents=True, exist_ok=True)
    env = {**os.environ, 'PYTHONDONTWRITEBYTECODE': '1', **check.env}
    check.dirty_before = dirty_tracked() if not check.background else set()
    check.started = time.monotonic()
    log = check.log.open('w', encoding='utf-8')
    log.write(f'$ {" ".join(check.command)}\n')
    log.flush()
    try:
        return subprocess.Popen(check.command, cwd=check.cwd, env=env, stdout=log, stderr=subprocess.STDOUT,
                                text=True, stdin=subprocess.DEVNULL)
    except OSError as error:
        log.write(f'{error}\n')
        settle(check, outcomes().cannot_start(advisory=check.advisory, reason=error.strerror))
        return None
    finally:
        log.close()


def check_timeout() -> float | None:
    """Seconds an exclusive check may run (and so hold the machine lock); JSTI_PRE_PR_CHECK_TIMEOUT=0 disables it."""
    try:
        seconds = float(os.environ.get('JSTI_PRE_PR_CHECK_TIMEOUT', '1800'))
    except ValueError:
        seconds = 1800.0
    return seconds if seconds > 0 else None


def descendants(pid: int) -> list[int]:
    found = subprocess.run(['pgrep', '-P', str(pid)], capture_output=True, text=True).stdout.split()
    tree = []
    for child in map(int, found):
        tree += [child, *descendants(child)]
    return tree


def stop_tree(process: subprocess.Popen) -> None:
    """End a hung check and everything it started (swift test → xctest), politely and then not."""
    tree = [process.pid, *descendants(process.pid)]
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for pid in tree:
            with contextlib.suppress(ProcessLookupError):
                os.kill(pid, sig)
        try:
            process.wait(timeout=15)
            return
        except subprocess.TimeoutExpired:
            continue


def finish(check: Check, process: subprocess.Popen | None, verbose: bool, restore: bool = True) -> None:
    if process is None:
        return
    limit = check_timeout() if check.exclusive else None
    try:
        code = process.wait(timeout=None if limit is None else max(0.0, check.started + limit - time.monotonic()))
        timed_out = False
    except subprocess.TimeoutExpired:
        stop_tree(process)
        code, timed_out = process.wait(), True
    check.duration = time.monotonic() - check.started
    text = check.log.read_text(encoding='utf-8', errors='replace')
    if verbose:
        sys.stdout.write(''.join(f'    {line}\n' for line in text.splitlines()))
    executed = tests_executed(text) if check.counts_tests else None
    drifted = () if check.background else set(check.forbid_drift) & (dirty_tracked() - check.dirty_before)
    settle(check, outcomes().after_exit(advisory=check.advisory, exit_code=code, tests_executed=executed,
                                        drifted=drifted, log=display(check.log)))
    if timed_out:
        check.note = f'timed out after {limit:.0f}s (JSTI_PRE_PR_CHECK_TIMEOUT), likely a hung test; {check.note}'
    if restore and not check.background:
        restore_side_effects(check, check.dirty_before)


def run(check: Check, verbose: bool) -> None:
    finish(check, launch(check), verbose)
