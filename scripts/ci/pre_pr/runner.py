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
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

from pre_pr import environment, mirror
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
    lane: str = ''              # exclusive checks in one lane run in order; lanes run side by side (default: own)
    mirror: bool = False        # a SwiftPM check that may build in the warm build mirror (pre_pr/mirror.py)
    mirrored: Path | None = None  # the mirror it runs in, once relocated
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


def dirty_tracked(cwd: Path = ROOT) -> set[str]:
    return set(filter(None, git('diff', '--name-only', 'HEAD', cwd=cwd).splitlines()))


def workdir(check: Check) -> Path:
    """The checkout the check runs in: the build mirror or this worktree."""
    return check.mirrored or ROOT


def relocate(check: Check, path: Path) -> None:
    """Run the check in the build mirror at path instead of this worktree."""
    check.command = mirror.relocate(check.command, path)
    check.cwd = path / check.cwd.relative_to(ROOT) if check.cwd.is_relative_to(ROOT) else check.cwd
    check.mirrored = path


def restore_side_effects(check: Check, dirty_before: set[str]) -> None:
    """Undo tracked-file changes a check made (the portable graph deletes Package.resolved)."""
    touched = sorted(dirty_tracked(workdir(check)) - dirty_before)
    if touched:
        git('checkout', 'HEAD', '--', *touched, cwd=workdir(check))
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
    check.dirty_before = dirty_tracked(workdir(check)) if not check.background else set()
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


def wait(check: Check, process: subprocess.Popen, cancel: threading.Event | None) -> tuple[int, str]:
    """The exit code, and 'timeout' or 'cancelled' when the check was stopped (its process tree killed)."""
    limit = check_timeout() if check.exclusive else None
    deadline = None if limit is None else check.started + limit
    while True:
        remaining = None if deadline is None else max(0.0, deadline - time.monotonic())
        step = remaining if cancel is None else min(remaining if remaining is not None else 1.0, 1.0)
        try:
            return process.wait(timeout=step), ''
        except subprocess.TimeoutExpired:
            if deadline is not None and time.monotonic() >= deadline:
                stop_tree(process)
                return process.wait(), 'timeout'
            if cancel is not None and cancel.is_set():
                stop_tree(process)
                return process.wait(), 'cancelled'


def finish(check: Check, process: subprocess.Popen | None, verbose: bool, restore: bool = True,
           cancel: threading.Event | None = None) -> None:
    """Wait for the check and settle it; cancel, once set, stops it as not run (another lane failed)."""
    if process is None:
        return
    code, stopped = wait(check, process, cancel)
    check.duration = time.monotonic() - check.started
    text = check.log.read_text(encoding='utf-8', errors='replace')
    if check.mirrored:
        text = mirror.unmirror(text, check.mirrored)
        check.log.write_text(text, encoding='utf-8')
    if verbose:
        sys.stdout.write(''.join(f'    {line}\n' for line in text.splitlines()))
    if stopped == 'cancelled':
        settle(check, outcomes().not_run('stopped after an earlier failure'))
    else:
        executed = tests_executed(text) if check.counts_tests else None
        drifted = () if check.background else (set(check.forbid_drift)
                                                & (dirty_tracked(workdir(check)) - check.dirty_before))
        settle(check, outcomes().after_exit(advisory=check.advisory, exit_code=code, tests_executed=executed,
                                            drifted=drifted, log=display(check.log)))
    if stopped == 'timeout':
        limit = check_timeout()
        check.note = f'timed out after {limit:.0f}s (JSTI_PRE_PR_CHECK_TIMEOUT), likely a hung test; {check.note}'
    if restore and not check.background:
        restore_side_effects(check, check.dirty_before)


def run(check: Check, verbose: bool, cancel: threading.Event | None = None) -> None:
    finish(check, launch(check), verbose, cancel=cancel)
