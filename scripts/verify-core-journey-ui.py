#!/usr/bin/env python3
"""Reject zero, missing, failed, or skipped launched-app XCTest suites."""

import json
from pathlib import Path
import runpy
import sys

REQUIRED_SUITES = (
    "LaunchUITests",
    "CoreJourneyFixtureUITests",
    "CoreJourneyHotKeyUITests",
    "CoreJourneyBatchUITests",
)


def main():
    log_path = Path(sys.argv[1])
    gate = runpy.run_path(str(Path(__file__).with_name("run-core-journey-e2e.py")))
    errors, counts = gate["coverage_errors"](
        log_path.read_text(encoding="utf-8", errors="replace"), REQUIRED_SUITES
    )
    result = {"required_suites": REQUIRED_SUITES, "counts": counts, "errors": errors}
    log_path.with_name("coverage.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    for error in errors:
        print(error, file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
