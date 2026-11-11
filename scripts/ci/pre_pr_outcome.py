"""Terminal outcomes of scripts/pre-pr: how one check settles and what the whole run reports.

This module only classifies. scripts/pre-pr starts processes, reads logs and restores
side effects; it passes the facts here and stores the answer. The truth table is:

Check status, decided in this order (the first rule that applies wins):

    planned skip (skip_reason)            -> skip, note = the reason
    planning failure (failure)            -> fail, note = the failure
    required tool missing                 -> fail  (advisory: warn), "<tool> not installed"
    process cannot start                  -> fail  (advisory: warn), "cannot start: ..."
    non-zero exit                         -> fail  (advisory: warn), "exit N; log ..."
    test run that executed zero tests     -> fail, "no tests matched the filter; log ..."
    exit 0 but modified a forbidden file  -> fail, "modified ... (CI fails on this drift) ..."
    otherwise                             -> pass, "N tests" when the run counts tests
    not run after an earlier failure      -> skip

Run result: fail if any check failed, else incomplete if a required check was
deliberately not run, else pass. Only pass exits 0; warn and skip never fail a run.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable

PASS, FAIL, WARN, SKIP, PENDING = 'pass', 'fail', 'warn', 'skip', 'pending'
INCOMPLETE = 'incomplete'
ICONS = {PASS: '✅', FAIL: '❌', WARN: '⚠️', SKIP: '⏭️', PENDING: '…'}


@dataclass(frozen=True)
class Outcome:
    status: str
    note: str = ''


def _unrunnable(advisory: bool, note: str) -> Outcome:
    """A check that could not do its job: required checks fail closed, advisory ones warn."""
    return Outcome(WARN if advisory else FAIL, note)


def before_launch(*, skip_reason: str, failure: str, missing_tool: str | None, advisory: bool) -> Outcome | None:
    """The outcome of a check settled without running it, or None when it should run."""
    if skip_reason:
        return Outcome(SKIP, skip_reason)
    if failure:
        return Outcome(FAIL, failure)
    if missing_tool:
        return _unrunnable(advisory, f'{missing_tool} not installed')
    return None


def cannot_start(*, advisory: bool, reason: str) -> Outcome:
    return _unrunnable(advisory, f'cannot start: {reason}')


def after_exit(*, advisory: bool, exit_code: int, tests_executed: int | None, drifted: Iterable[str] = (),
               log: str = '') -> Outcome:
    """The outcome of a check that ran. tests_executed is None unless the check counts tests."""
    if exit_code != 0:
        return _unrunnable(advisory, f'exit {exit_code}; log {log}')
    if tests_executed == 0:
        return Outcome(FAIL, f'no tests matched the filter; log {log}')
    drifted = sorted(drifted)
    if drifted:
        return Outcome(FAIL, f'modified {", ".join(drifted)} (CI fails on this drift); commit the regenerated file')
    return Outcome(PASS, f'{tests_executed} tests' if tests_executed else '')


def not_run(note: str) -> Outcome:
    """A check skipped or stopped because an earlier check failed."""
    return Outcome(SKIP, note)


def run_result(statuses: Iterable[str], incomplete: bool) -> str:
    """The whole run's result from its checks' statuses and whether a required check was left unrun."""
    if FAIL in set(statuses):
        return FAIL
    return INCOMPLETE if incomplete else PASS


def exit_status(result: str) -> int:
    return 0 if result == PASS else 1
