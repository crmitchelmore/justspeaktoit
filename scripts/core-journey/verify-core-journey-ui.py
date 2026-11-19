#!/usr/bin/env python3
"""Reject zero, missing, failed, or skipped launched-app XCTest suites."""

import json
import os
import runpy
import sys
from pathlib import Path

# Each hotkey journey spends ~60s in real gesture windows, so the suites run as
# parallel CI shards that each keep the unchanged 600s UI runtime budget. Every
# required suite belongs to exactly one shard; the default selects them all.
SHARDS = {
    "foundation": (
        "LaunchUITests",
        "CoreJourneyFixtureUITests",
        "CoreJourneyHotKeyUITests",
        "CoreJourneyBatchUITests",
        "SettingsCredentialUITests",
        "CoreJourneyPostProcessingUITests",
    ),
    "p0": (
        "CoreJourneyP0UITests",
    ),
}

REQUIRED_SUITES = tuple(suite for suites in SHARDS.values() for suite in suites)

REQUIRED_CASES = {
    "CoreJourneyPostProcessingUITests": (
        "testBatchPolishing_DeliversProcessedTextAndRetainsRawHistory",
        "testBatchPolishing_FailureThenFreshRecordingRecoversInSameProcess",
    ),
    "CoreJourneyP0UITests": (
        "testStreaming_partialsBecomeOneFinalTranscriptWithoutDuplication",
        "testTargetChange_duringRecordingDeliversToCapturedAppNotNewFrontmostApp",
        "testSilentInput_leavesClipboardAndFieldUntouchedAndStoresNoTranscript",
        "testMissingTranscriptionKey_failsVisiblyThenNextRunSucceeds",
    ),
}


def selected_suites(shard=None):
    shard = shard if shard is not None else os.environ.get("CORE_JOURNEY_UI_SHARD", "all")
    if shard == "all":
        return REQUIRED_SUITES
    if shard not in SHARDS:
        raise ValueError(f"Unknown core journey UI shard: {shard!r}")
    return SHARDS[shard]


def coverage_errors(output, suites=None):
    suites = selected_suites() if suites is None else suites
    gate = runpy.run_path(str(Path(__file__).with_name("run-core-journey-e2e.py")))
    errors, counts = gate["coverage_errors"](output, suites)
    executed = list(gate["case_results"](output))
    for suite, cases in REQUIRED_CASES.items():
        if suite not in suites:
            continue
        for case in cases:
            statuses = [row["status"] for row in executed if row["suite"] == suite and row["case"] == case]
            if statuses != ["passed"]:
                errors.append(f"{suite}/{case}: expected exactly one passing execution, got {statuses}")
    return errors, counts


def main():
    log_path = Path(sys.argv[1])
    errors, counts = coverage_errors(log_path.read_text(encoding="utf-8", errors="replace"))
    result = {"required_suites": selected_suites(), "required_cases": REQUIRED_CASES,
              "counts": counts, "errors": errors}
    log_path.with_name("coverage.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    for error in errors:
        print(error, file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
