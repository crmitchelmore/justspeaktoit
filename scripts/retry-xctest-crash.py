#!/usr/bin/env python3
"""Run a `swift test` command and re-run it once if XCTest itself crashed.

A single segfault in one test kills the whole xctest process, so every test
after it goes unreported and the gate fails without naming a cause. When the
output shows `exited with unexpected signal code` and no test case reported
a failure, the command is re-run once and the crashing case is annotated.
A crash that repeats, or any ordinary test failure, still fails the step.

Usage: scripts/retry-xctest-crash.py <command> [arguments...]
"""

from __future__ import annotations

import re
import subprocess
import sys

CRASH = re.compile(r"exited with unexpected signal code (\d+)")
STARTED = re.compile(r"Test Case '([^'\r\n]{1,512})' started")
FAILED = re.compile(r"(?m)Test Case '[^'\r\n]{1,512}' failed|^\s*✘ Test ")


def run(command: list[str]) -> tuple[int, str]:
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    captured = bytearray()
    assert process.stdout is not None
    while chunk := process.stdout.read1(65536):
        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()
        captured.extend(chunk)
    return process.wait(), captured.decode("utf-8", errors="replace")


def crash_only(status: int, output: str) -> tuple[str, str] | None:
    """Return (signal, last started case) when the run failed only by crashing."""
    crash = CRASH.search(output)
    if status == 0 or crash is None or FAILED.search(output):
        return None
    started = STARTED.findall(output[: crash.start()] + output[crash.end():])
    return crash.group(1), (started[-1] if started else "unknown")


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__, file=sys.stderr)
        return 64
    status, output = run(argv)
    crash = crash_only(status, output)
    if crash is None:
        return status
    signal, case = crash
    print(f"::warning::XCTest crashed with signal {signal} (last started: {case}); re-running once", flush=True)
    status, output = run(argv)
    if status != 0 and CRASH.search(output):
        print(f"::error::XCTest crashed again; last started case before the first crash: {case}", flush=True)
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
