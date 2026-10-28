#!/usr/bin/env python3
"""Run the required macOS contract suites and reject silent coverage loss."""

import collections
import heapq
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
    "CoreJourneyRecordingSourceTests",
    "CoreJourneyPolishFixtureTests",
    "LiveTranscriptSessionIsolationTests",
    "HistoryPersistenceFailureTests",
)

# Apple XCTest uses '-[Module.Suite method]'; swift-corelibs uses
# 'Module.Suite.method' or 'Suite.method'. Match case completion, never a suite
# heading or the unrelated Swift Testing runner's "0 tests passed" summary.
CASE_RESULT = re.compile(
    r"^Test Case '(?:-\[(?:(?P<apple_module>\w+)\.)?(?P<apple>\w+) (?P<apple_case>[^\]]+)\]"
    r"|(?:(?P<portable_module>\w+)\.)?(?P<portable>\w+)\.(?P<portable_case>\w+))' "
    r"(?P<status>passed|failed|skipped)\b",
    re.MULTILINE,
)

# XCTest and the Apple console can write concurrently without a newline. Only
# recover complete Apple results after a typed console prefix, not arbitrary
# embedded/quoted examples. Keep the original line-start formats unchanged.
INTERLEAVED_CASE_RESULT = re.compile(
    r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{1,9}[+-]\d{4} "
    r"[^\s\[\]]+\[\d+:\d+\] \[[^\]\r\n]+\] [^'\"\r\n]*?"
    + CASE_RESULT.pattern[1:]
    + r" \([0-9]+(?:\.[0-9]+)? seconds\)\.\r?$",
    re.MULTILINE,
)


# A console record can splice between an Apple case's closing bracket and its
# completion quote. Recover only this typed, two-physical-line shape; never join
# arbitrary lines or allow a multiline case identity/console payload.
SPLICED_CASE_RESULT = re.compile(
    r"^Test Case '-\[(?:(?P<apple_module>\w+)\.)?(?P<apple>\w+) (?P<apple_case>[^\]\r\n]+)\]"
    r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{1,9}[+-]\d{4} "
    r"[^\s\[\]]+\[\d+:\d+\] \[[^\]\r\n]+\] [^'\"\r\n]*\r?\n"
    r"' (?P<status>passed|failed|skipped) \([0-9]+(?:\.[0-9]+)? seconds\)\.\r?$",
    re.MULTILINE,
)


def case_results(output):
    """Yield completed XCTest cases, retaining module identity when emitted."""
    interleaved = (match for match in INTERLEAVED_CASE_RESULT.finditer(output)
                   if match.group("apple") and not any(char in match.group("apple_case") for char in "\r\n"))
    for match in heapq.merge(CASE_RESULT.finditer(output), interleaved, SPLICED_CASE_RESULT.finditer(output), key=lambda result: result.start()):
        groups = match.groupdict()
        yield {
            "module": groups.get("apple_module") or groups.get("portable_module"),
            "suite": groups.get("apple") or groups.get("portable"),
            "case": groups.get("apple_case") or groups.get("portable_case"),
            "status": match.group("status"),
        }


def coverage_errors(output, required_suites):
    counts = {suite: collections.Counter() for suite in required_suites}
    for result in case_results(output):
        suite = result["suite"]
        if suite in counts:
            counts[suite][result["status"]] += 1
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


def run_gate(command, artifacts_dir, budget, required_suites=REQUIRED_SUITES, stage="test"):
    artifacts_dir = Path(artifacts_dir)
    started = time.monotonic()
    command_elapsed = None
    exit_code = 1
    errors = []
    counts = {}
    process = None
    log_path = artifacts_dir / "test.log"

    def record_error(message):
        nonlocal exit_code
        errors.append(message)
        # Diagnostic failures must fail a successful gate, but never replace
        # the test command's original failure or timeout status.
        if exit_code == 0:
            exit_code = 1

    try:
        artifacts_dir.mkdir(parents=True, exist_ok=True)
        with log_path.open("w", encoding="utf-8") as log:
            log.write("command: " + " ".join(command) + "\n")
            log.flush()
            # A separate process group lets a timeout terminate XCTest and any
            # compiler descendants too. Killing only `swift` leaks those jobs.
            command_started = time.monotonic()
            try:
                process = subprocess.Popen(
                    command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True
                )
                try:
                    exit_code = process.wait(timeout=budget)
                    if exit_code != 0:
                        errors.append(f"{stage.capitalize()} command exited with status {exit_code}; see {log_path}.")
                except subprocess.TimeoutExpired:
                    exit_code = 124
                    errors.append(f"Core journey gate exceeded its {budget}s {stage} budget.")
                    stop_process_group(process)
            finally:
                # The budget covers the command, not log replay, coverage
                # parsing, or writing diagnostics after the command finishes.
                command_elapsed = time.monotonic() - command_started
        output = log_path.read_text(encoding="utf-8", errors="replace")
        print(output, end="", flush=True)
        if exit_code == 0:
            errors, counts = coverage_errors(output, required_suites)
            if errors:
                exit_code = 1
    except (OSError, ValueError) as error:
        record_error(str(error))
    finally:
        if process is not None and process.poll() is None:
            try:
                stop_process_group(process)
            except OSError as error:
                record_error(f"Could not stop test process group: {error}")
        elapsed = time.monotonic() - started
        timing = f"core_journey_elapsed_seconds={elapsed:.3f}\n"
        try:
            (artifacts_dir / "timing.txt").write_text(timing, encoding="utf-8")
        except OSError as error:
            record_error(f"Could not write timing.txt: {error}")
        try:
            (artifacts_dir / "result.json").write_text(
                json.dumps(
                    {
                        "exit_code": exit_code,
                        "stage": stage,
                        "command": command,
                        "elapsed_seconds": elapsed,
                        "command_elapsed_seconds": command_elapsed,
                        "budget_seconds": budget,
                        "required_suites": list(required_suites),
                        "executed_cases": counts,
                        "errors": errors,
                    },
                    indent=2,
                ) + "\n",
                encoding="utf-8",
            )
        except OSError as error:
            record_error(f"Could not write result.json: {error}")
        print(timing, end="", flush=True)
        for error in errors:
            print(error, file=sys.stderr)
    return exit_code


def main():
    def interrupted(signum, _frame):
        raise InterruptedError(f"Core journey gate interrupted by signal {signum}")

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    import runpy
    stages = runpy.run_path(str(Path(__file__).with_name("run-core-journey-stages.py")))
    return stages["main"](["swift", *sys.argv[1:]])


if __name__ == "__main__":
    sys.exit(main())
