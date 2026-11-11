#!/usr/bin/env python3
"""ci.yml's isolated History fixture diagnostic, run after a failed macOS test job.

    capture <dir>                                   copy stdin to <dir>/output.log, keeping the first MiB
    summarise <dir> <command-exit> <capture-exit>   write <dir>/result.json; exit 0 only on an exact pass

Diagnostic only: it never qualifies parity. The summary trusts a result only
when the capture is complete and every expected case started and finished
exactly once.
"""
import json
from pathlib import Path
import re
import sys


def capture(directory: Path) -> int:
    limit = 1024 * 1024
    received = saved = 0
    with (directory / "output.log").open("xb") as output:
        while data := sys.stdin.buffer.read1(65536):
            received += len(data)
            kept = data[:max(0, limit - saved)]
            output.write(kept)
            output.flush()
            saved += len(kept)
    (directory / "capture.json").write_text(json.dumps({
        "received_bytes": received, "saved_bytes": saved,
        "truncated": received > saved
    }) + "\n", encoding="ascii")
    return 0


def summarise(directory: Path, command_status: int, capture_status: int) -> int:
    command = ["python3", "scripts/with-test-keychain.py", "swift", "test",
               "--skip-build", "--enable-code-coverage", "--disable-dependency-cache", "--filter",
               "DesktopLivePolishHistoryTests"]
    methods = [
        "testControlRecordWithoutSession_RoundTripsRawAndPolishedValues",
        "testControlResultAfterFinish_RoundTripsSuccessfulPolish",
        "testNativeAndPortableHistory_RoundTripRawAndSuccessfulPolishWithoutRerunningClient",
    ]
    expected = ["SpeakDesktopTests.DesktopLivePolishHistoryTests." + method for method in methods]
    accepted = {}
    for method, canonical in zip(methods, expected):
        for alias in (canonical, "DesktopLivePolishHistoryTests." + method,
                      "-[SpeakDesktopTests.DesktopLivePolishHistoryTests " + method + "]"):
            accepted[alias] = canonical
    capture_file = directory / "capture.json"
    capture = (json.loads(capture_file.read_text(encoding="ascii")) if capture_file.exists()
               else {"status": "unavailable", "truncated": True})
    log_file = directory / "output.log"
    data = log_file.read_bytes() if log_file.exists() else b""
    pattern = rb"(?m)^Test Case '([^'\r\n]{1,512})' (started|passed|failed|skipped)(?=[ .])"
    events = [(identity.decode("utf-8", errors="replace"), state.decode("ascii"))
              for identity, state in re.findall(pattern, data)]
    unparsed = data.count(b"Test Case '") - len(events)
    counts = {state: sum(event == state for _, event in events)
              for state in ("started", "passed", "failed", "skipped")}
    per_case = {identity: [] for identity in expected}
    unknown = 0
    for identity, state in events:
        canonical = accepted.get(identity)
        if canonical is None:
            unknown += 1
        else:
            per_case[canonical].append(state)
    complete = capture_status == 0 and capture_file.exists() and not capture["truncated"]
    selection_verified = (
        complete and unparsed == 0 and unknown == 0
        and all(len(states) == 2 and states[0] == "started"
                and states[1] in ("passed", "failed", "skipped") for states in per_case.values())
    )
    passed = (command_status == 0 and selection_verified
              and all(states == ["started", "passed"] for states in per_case.values()))
    result = {
        "purpose": "isolated_history_fixture_diagnostic",
        "command": command, "command_exit_code": command_status,
        "capture_exit_code": capture_status, "capture": capture,
        "expected_cases": expected, "expected_case_count": len(expected),
        "observed_case_event_counts": counts,
        "observed_expected_case_events": {identity: states[:8] for identity, states in per_case.items()},
        "unknown_case_event_count": unknown,
        "unparsed_test_case_lines": unparsed,
        "observed_case_events": events[:16], "case_counts_complete": complete,
        "selection_verified": selection_verified, "parity_qualification": False,
        "status": ("isolated_pass" if passed else
                   "isolated_failure" if command_status else "selection_or_capture_unverified"),
    }
    text = json.dumps(result, indent=2, sort_keys=True) + "\n"
    temporary = directory / ".result.json.tmp"
    temporary.write_text(text, encoding="ascii")
    temporary.replace(directory / "result.json")
    print(text, end="")
    if not selection_verified:
        print("Isolated diagnostic: exact-case execution or complete capture NOT established.",
              file=sys.stderr)
    return 0 if passed else 1


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[0] == "capture":
        return capture(Path(argv[1]))
    if len(argv) == 4 and argv[0] == "summarise":
        return summarise(Path(argv[1]), int(argv[2]), int(argv[3]))
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
