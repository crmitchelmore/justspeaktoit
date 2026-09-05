#!/usr/bin/env python3
"""Run the required macOS contract suites and reject silent coverage loss."""

import collections
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

# Exact suite names, not source filenames: one file can contain several suites.
REQUIRED_SUITES = (
    "GestureDetectorTests",
    "LiveTextInserterStreamingTests",
    "PostProcessingManagerTests",
    "OpenAITranscriptionProviderTests",
    "OpenAITranscriptionProviderErrorTests",
    "MissingLiveAPIKeyAlertTests",
    "TextOutputTests",
    "ClipboardFieldIdentityPolicyTests",
    "StreamingClientContractTests",
    "AutomationServerTests",
    "AutomationDeadlineTests",
    "CaptureSessionOwnershipTests",
    "LiveTranscriptSessionIsolationTests",
    "HistoryPersistenceFailureTests",
)

# Apple XCTest uses '-[Module.Suite method]'; swift-corelibs uses
# 'Module.Suite.method' or 'Suite.method'. Match case completion, never a suite
# heading or the unrelated Swift Testing runner's "0 tests passed" summary.
CASE_RESULT = re.compile(
    r"^Test Case '(?:-\[(?:\w+\.)?(?P<apple>\w+) [^\]]+\]"
    r"|(?:\w+\.)?(?P<portable>\w+)\.\w+)' "
    r"(?P<status>passed|failed|skipped)\b",
    re.MULTILINE,
)


def coverage_errors(output, required_suites):
    counts = {suite: collections.Counter() for suite in required_suites}
    for match in CASE_RESULT.finditer(output):
        suite = match.group("apple") or match.group("portable")
        if suite in counts:
            counts[suite][match.group("status")] += 1
    errors = []
    for suite, results in counts.items():
        if not results["passed"]:
            errors.append(f"{suite}: no passing XCTest cases executed")
        if results["failed"] or results["skipped"]:
            errors.append(
                f"{suite}: {results['failed']} failed, {results['skipped']} skipped cases"
            )
    return errors, counts


def stop_process_group(process):
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def run_gate(command, artifacts_dir, budget, required_suites=REQUIRED_SUITES):
    artifacts_dir = Path(artifacts_dir)
    artifacts_dir.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    exit_code = 1
    errors = []
    counts = {}
    process = None
    log_path = artifacts_dir / "test.log"
    try:
        with log_path.open("w", encoding="utf-8") as log:
            log.write("command: " + " ".join(command) + "\n")
            log.flush()
            # A separate process group lets a timeout terminate XCTest and any
            # compiler descendants too. Killing only `swift` leaks those jobs.
            process = subprocess.Popen(
                command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True
            )
            try:
                exit_code = process.wait(timeout=budget)
            except subprocess.TimeoutExpired:
                stop_process_group(process)
                exit_code = 124
                errors.append(f"Core journey gate exceeded its {budget}s test budget.")
        output = log_path.read_text(encoding="utf-8", errors="replace")
        print(output, end="", flush=True)
        if exit_code == 0:
            errors, counts = coverage_errors(output, required_suites)
            if errors:
                exit_code = 1
    except (OSError, ValueError) as error:
        errors.append(str(error))
        exit_code = 1
    finally:
        if process is not None and process.poll() is None:
            stop_process_group(process)
        elapsed = time.monotonic() - started
        if elapsed > budget and exit_code == 0:
            exit_code = 124
            errors.append(f"Core journey gate exceeded its {budget}s test budget.")
        timing = f"core_journey_elapsed_seconds={elapsed:.3f}\n"
        (artifacts_dir / "timing.txt").write_text(timing, encoding="utf-8")
        (artifacts_dir / "result.json").write_text(
            json.dumps(
                {
                    "exit_code": exit_code,
                    "elapsed_seconds": elapsed,
                    "budget_seconds": budget,
                    "required_suites": list(required_suites),
                    "executed_cases": counts,
                    "errors": errors,
                },
                indent=2,
            ) + "\n",
            encoding="utf-8",
        )
        print(timing, end="", flush=True)
        for error in errors:
            print(error, file=sys.stderr)
    return exit_code


def main():
    def interrupted(signum, _frame):
        raise InterruptedError(f"Core journey gate interrupted by signal {signum}")

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        budget = int(os.environ.get("CORE_JOURNEY_BUDGET_SECONDS", "480"))
        if budget <= 0:
            raise ValueError("budget must be positive")
    except ValueError as error:
        print(f"Invalid CORE_JOURNEY_BUDGET_SECONDS: {error}", file=sys.stderr)
        return 2
    test_filter = "|".join(f"{suite}/" for suite in REQUIRED_SUITES)
    return run_gate(
        ["swift", "test", "--filter", test_filter],
        os.environ.get("CORE_JOURNEY_ARTIFACTS_DIR", ".artifacts/core-journey-e2e"),
        budget,
    )


if __name__ == "__main__":
    sys.exit(main())
