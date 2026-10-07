#!/usr/bin/env python3
"""Collect bounded diagnostics for the exact child owned by verify-launch.sh."""
import argparse
import json
import re
import subprocess
import tempfile
import time
from pathlib import Path

MAX_REPORT_BYTES = 1024 * 1024
MAX_LOG_BYTES = 64 * 1024
MAX_EXCERPT_BYTES = 16 * 1024


def matching_reports(directory, marker, name, pid):
    if not directory.is_dir():
        return []
    reports = []
    for path in directory.glob(f"{name}*"):
        if path.is_symlink() or not path.is_file() or path.suffix not in (".ips", ".crash"):
            continue
        try:
            if path.stat().st_mtime_ns < marker.stat().st_mtime_ns:
                continue
            with path.open("rb") as handle:
                data = handle.read(MAX_REPORT_BYTES + 1)
            if len(data) > MAX_REPORT_BYTES:
                print(f"  Skipping oversized crash report: {path.name}")
                continue
            text = data.decode("utf-8", errors="replace")
            if path.suffix == ".crash":
                match = re.search(r"^Process:.*\[(\d+)\]\s*$", text, re.MULTILINE)
                matches = match is not None and int(match[1]) == pid
            else:
                # .ips has a metadata JSON object followed by the report object.
                decoder = json.JSONDecoder()
                matches = False
                while text.strip():
                    value, end = decoder.raw_decode(text.lstrip())
                    if isinstance(value, dict) and value.get("pid") == pid:
                        matches = True
                    text = text.lstrip()[end:]
            if matches:
                reports.append((path.stat().st_mtime_ns, path, data))
        except (OSError, ValueError) as error:
            print(f"  Cannot read crash report {path.name}: {error}")
    return sorted(reports, key=lambda report: report[0], reverse=True)[:3]


def tail(path, limit):
    with path.open("rb") as handle:
        handle.seek(0, 2)
        handle.seek(max(0, handle.tell() - limit))
        return handle.read(limit)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--marker", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--stdout", type=Path, required=True)
    parser.add_argument("--wait", type=float, default=10)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    output = tail(args.stdout, MAX_LOG_BYTES)
    (args.output / "process-output.txt").write_bytes(output)
    print("--- Candidate stdout/stderr (bounded tail) ---")
    print(output[-MAX_EXCERPT_BYTES:].decode("utf-8", errors="replace"))

    deadline = time.monotonic() + max(0, min(args.wait, 10))
    directory = Path.home() / "Library/Logs/DiagnosticReports"
    while True:
        reports = matching_reports(directory, args.marker, args.name, args.pid)
        if reports or time.monotonic() >= deadline:
            break
        time.sleep(0.25)
    if not reports:
        print(f"No new crash report for candidate PID {args.pid} within the diagnostic budget.")
    for _, path, data in reports:
        destination = args.output / path.name
        destination.write_bytes(data)
        print(f"--- Crash report: {destination} (bounded excerpt) ---")
        print(data[:MAX_EXCERPT_BYTES].decode("utf-8", errors="replace"))

    # Filter by PID, not name: another Alpha or Stable install is not our child.
    with tempfile.TemporaryFile() as handle:
        try:
            result = subprocess.run(
                ["log", "show", "--predicate", f"processIdentifier == {args.pid}",
                 "--last", "30s", "--style", "compact"],
                stdout=handle, stderr=handle, timeout=5, check=False,
            )
            if result.returncode:
                print(f"System log query failed with exit status {result.returncode}.")
        except (OSError, subprocess.TimeoutExpired) as error:
            print(f"System log query unavailable: {error}")
        handle.seek(0, 2)
        handle.seek(max(0, handle.tell() - MAX_LOG_BYTES))
        data = handle.read(MAX_LOG_BYTES)
    (args.output / "system-log.txt").write_bytes(data)
    print("--- Candidate system log (bounded tail) ---")
    print(data[-MAX_EXCERPT_BYTES:].decode("utf-8", errors="replace"))
    print(f"Launch diagnostics saved to: {args.output}")


if __name__ == "__main__":
    main()
