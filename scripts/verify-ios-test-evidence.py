#!/usr/bin/env python3
"""Require iOS XCTest execution and retain small, transcript-free summaries."""

import argparse
import collections
import json
from pathlib import Path
import runpy
import sys

PARSER = runpy.run_path(str(Path(__file__).with_name("run-core-journey-e2e.py")))["case_results"]
REQUIRED_TARGETS = ("SpeakiOSTests", "SpeakiOSUITests")
REQUIRED_SUITES = {
    "SpeakiOSTests": ("OpenRouterAudioSettingsTests", "OpenRouterVoiceCancellationTests"),
}
STATUSES = ("passed", "failed", "skipped")
MAX_LOG_BYTES = 64 * 1024 * 1024


def counts(statuses):
    counter = collections.Counter(statuses)
    return {status: counter[status] for status in STATUSES}


def read_log(path):
    with path.open("rb") as log:
        data = log.read(MAX_LOG_BYTES + 1)
    if len(data) > MAX_LOG_BYTES:
        raise ValueError(f"iOS test log exceeds {MAX_LOG_BYTES}-byte limit; execution evidence not parsed")
    return data.decode("utf-8", errors="replace")


def summarize(output, test_outcome):
    # A repeated console line is not another test. Preserve different outcomes
    # for the same case so a passing retry cannot hide a failure or skip.
    cases = collections.defaultdict(set)
    for result in PARSER(output):
        if result["module"] in REQUIRED_TARGETS:
            key = (result["module"], result["suite"], result["case"])
            cases[key].add(result["status"])

    targets = {}
    errors = []
    if test_outcome != "success":
        errors.append(f"iOS test command outcome was {test_outcome}, not success")
    for target in REQUIRED_TARGETS:
        target_cases = {key: statuses for key, statuses in cases.items() if key[0] == target}
        suites = {}
        suite_names = {key[1] for key in target_cases} | set(REQUIRED_SUITES.get(target, ()))
        for suite in sorted(suite_names):
            suites[suite] = counts(status for key, statuses in target_cases.items()
                                   if key[1] == suite for status in statuses)
        totals = counts(status for statuses in target_cases.values() for status in statuses)
        targets[target] = {"unique_cases": len(target_cases), "counts": totals, "suites": suites}
        if not totals["passed"]:
            errors.append(f"{target}: no passing XCTest cases executed with this target identity")
        if totals["failed"]:
            errors.append(f"{target}: {totals['failed']} failed XCTest cases")
        for suite in REQUIRED_SUITES.get(target, ()):
            results = suites[suite]
            if not results["passed"]:
                errors.append(f"{target}.{suite}: no passing XCTest cases executed")
            if results["failed"] or results["skipped"]:
                errors.append(f"{target}.{suite}: {results['failed']} failed, {results['skipped']} skipped cases")

    return {
        "test_outcome": test_outcome,
        "required_targets": REQUIRED_TARGETS,
        "required_suites": REQUIRED_SUITES,
        "unique_cases": len(cases),
        "counts": counts(status for statuses in cases.values() for status in statuses),
        "targets": targets,
        "errors": errors,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--test-outcome", required=True, choices=("success", "failure", "cancelled", "skipped"))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    read_error = None
    try:
        output = read_log(args.log)
    except (OSError, ValueError) as error:
        output = ""
        read_error = f"Cannot read iOS test log: {error}"
    summary = summarize(output, args.test_outcome)
    if read_error:
        summary["errors"].append(read_error)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    for target, result in summary["targets"].items():
        print(f"{target}: {result['unique_cases']} unique cases; {result['counts']}")
    for error in summary["errors"]:
        print(error, file=sys.stderr)
    return 1 if summary["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())
