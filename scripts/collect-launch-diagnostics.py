#!/usr/bin/env python3
"""Project launch diagnostics onto bounded, content-free evidence."""
import argparse
import json
import os
import re
import subprocess
import time
from datetime import datetime
from itertools import islice
from pathlib import Path

from launch_diagnostics import drain

MAX_REPORT_BYTES = 1024 * 1024
MAX_SCAN_ENTRIES = 256
MAX_CANDIDATES = 8
MAX_REPORTS = 3
EXCEPTIONS = {"EXC_BAD_ACCESS", "EXC_BAD_INSTRUCTION", "EXC_ARITHMETIC",
              "EXC_BREAKPOINT", "EXC_CRASH", "EXC_RESOURCE", "EXC_GUARD"}
IMAGES = {"libswiftCore.dylib", "SwiftUI", "SwiftUICore", "Combine",
          "Foundation", "AppKit", "dyld", "libsystem_kernel.dylib"}


def unsigned(value):
    return value if type(value) is int and 0 <= value < 2 ** 64 else None


def timestamp(value):
    if not isinstance(value, str):
        return None
    try:
        # Apple .ips/.crash timestamps separate the numeric UTC offset with a
        # space, unlike ISO 8601. Preserve timezone information when normalising.
        result = datetime.fromisoformat(re.sub(r" ([+-]\d{4})$", r"\1", value))
        return result.timestamp() if result.tzinfo else None
    except ValueError:
        return None


def matches_path(path, process_name, bundle_id, args):
    if path == args.executable:
        return True
    # Apple replaces the user-owned prefix in native reports with /Users/USER/*.
    # Only accept that specific redaction with the full bundle suffix and the
    # separately recorded bundle/process identity, never an arbitrary basename.
    suffix = f"/{Path(args.executable).parents[2].name}/Contents/MacOS/{args.name}"
    return (isinstance(path, str) and path.startswith("/Users/USER/*/")
            and path.endswith(suffix) and process_name == args.name
            and bool(args.bundle_id) and bundle_id == args.bundle_id)


def project_report(data, suffix, args):
    text = data.decode("utf-8", errors="replace")
    if suffix == ".crash":
        fields = {}
        for line in text.splitlines():
            key, separator, value = line.partition(":")
            if separator:
                fields[key.strip()] = value.strip()
        pid = re.search(r"\[(\d+)\]$", fields.get("Process", ""))
        crash_time = timestamp(fields.get("Date/Time"))
        name = fields.get("Process", "").partition(" [")[0]
        if (not pid or int(pid[1]) != args.pid
                or not matches_path(fields.get("Path"), name, fields.get("Identifier"), args)
                or crash_time is None or not args.start <= crash_time <= args.end):
            return None
        exception = fields.get("Exception Type", "").split(" ")[0]
        return {"pid": args.pid, "exceptionType": exception if exception in EXCEPTIONS else None}

    decoder = json.JSONDecoder()
    report = None
    while text.strip():
        value, end = decoder.raw_decode(text.lstrip())
        if isinstance(value, dict) and "pid" in value:
            report = value
        text = text.lstrip()[end:]
    if not report:
        return None
    launch = timestamp(report.get("procLaunch"))
    capture = timestamp(report.get("captureTime"))
    if (report.get("pid") != args.pid
            or not matches_path(report.get("procPath"), report.get("procName"),
                                report.get("bundleInfo", {}).get("CFBundleIdentifier"), args)
            or launch is None or not args.start - 1 <= launch <= min(args.start + 1, args.end)
            or capture is None or not args.start <= capture <= args.end):
        return None
    exception = report.get("exception", {})
    kind = exception.get("type")
    projection = {
        "pid": args.pid, "exceptionType": kind if kind in EXCEPTIONS else None,
        "rawCodes": [unsigned(code) for code in exception.get("rawCodes", [])[:4]],
        "frames": [],
    }
    images = report.get("usedImages", [])
    for thread in report.get("threads", [])[:32]:
        if not thread.get("triggered"):
            continue
        for frame in thread.get("frames", [])[:128]:
            index = unsigned(frame.get("imageIndex"))
            image = images[index] if index is not None and index < len(images) else {}
            name = image.get("name")
            uuid = image.get("uuid", "")
            projection["frames"].append({
                "image": name if name in IMAGES or name == args.name else "other",
                "uuid": uuid if isinstance(uuid, str) and re.fullmatch(r"[0-9a-fA-F-]{36}", uuid) else None,
                "imageOffset": unsigned(frame.get("imageOffset")),
                "symbolLocation": unsigned(frame.get("symbolLocation")),
            })
        break
    return projection


def discover(directory, marker, name, statistics):
    candidates = []
    if not directory.is_dir():
        return candidates
    with os.scandir(directory) as entries:
        for index, entry in enumerate(islice(entries, MAX_SCAN_ENTRIES)):
            if index + 1 == MAX_SCAN_ENTRIES:
                statistics["discoveryTruncated"] = True
            statistics["entriesScanned"] += 1
            if not entry.name.startswith(name) or Path(entry.name).suffix not in (".ips", ".crash"):
                continue
            if not entry.is_file(follow_symlinks=False):
                continue
            stat = entry.stat(follow_symlinks=False)
            if stat.st_mtime_ns < marker.stat().st_mtime_ns:
                continue
            candidates.append((stat.st_mtime_ns, entry.path))
            candidates.sort(reverse=True)
            del candidates[MAX_CANDIDATES:]
    return candidates


def collect_reports(args):
    statistics = {"entriesScanned": 0, "reportsRead": 0, "oversized": 0,
                  "invalid": 0, "identityRejected": 0, "discoveryTruncated": False}
    directory = Path.home() / "Library/Logs/DiagnosticReports"
    deadline = time.monotonic() + max(0, min(args.wait, 10))
    seen = set()
    reports = []
    while True:
        try:
            candidates = discover(directory, args.marker, args.name, statistics)
            for modified, path in candidates:
                identity = (modified, path)
                if identity in seen:
                    continue
                # Bound total reads and bookkeeping across polling passes, not just per pass.
                if statistics["reportsRead"] >= MAX_CANDIDATES:
                    statistics["discoveryTruncated"] = True
                    break
                seen.add(identity)
                statistics["reportsRead"] += 1
                try:
                    with open(path, "rb") as handle:
                        data = handle.read(MAX_REPORT_BYTES + 1)
                    if len(data) > MAX_REPORT_BYTES:
                        statistics["oversized"] += 1
                        continue
                    projection = project_report(data, Path(path).suffix, args)
                    if projection is None:
                        statistics["identityRejected"] += 1
                    else:
                        reports.append(projection)
                except (OSError, ValueError, TypeError, AttributeError, IndexError, KeyError):
                    statistics["invalid"] += 1
                if len(reports) == MAX_REPORTS:
                    break
        except OSError:
            statistics["discoveryUnavailable"] = True
            break
        if reports or time.monotonic() >= deadline or statistics["reportsRead"] >= MAX_CANDIDATES:
            break
        time.sleep(0.25)
    for index, report in enumerate(reports):
        (args.output / f"crash-report-{index + 1}.json").write_text(json.dumps(report, indent=2) + "\n")
    statistics["reportsRetained"] = len(reports)
    return statistics


def collect_system_log(args):
    def date(value):
        return datetime.fromtimestamp(value).astimezone().strftime("%Y-%m-%d %H:%M:%S%z")

    statistics = {"contentRetained": False, "available": False}
    try:
        process = subprocess.Popen(
            ["log", "show", "--predicate",
             f"processIdentifier == {args.pid} AND processImagePath == {json.dumps(args.executable)}",
             "--start", date(args.start), "--end", date(args.end), "--style", "compact"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        try:
            try:
                statistics.update(drain(process.stdout.fileno(), time.monotonic() + 5))
            finally:
                # Also covers a descendant keeping the pipe open after log exits.
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=1)
            statistics.update(available=True, exitStatus=process.returncode)
        finally:
            process.stdout.close()
    except (OSError, subprocess.TimeoutExpired):
        statistics["collectionFailed"] = True
    return statistics


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--executable", required=True)
    parser.add_argument("--bundle-id", default="")
    parser.add_argument("--marker", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--stdout", type=Path, required=True)
    parser.add_argument("--start-ns", type=int, required=True)
    parser.add_argument("--end-ns", type=int, required=True)
    parser.add_argument("--wait", type=float, default=10)
    args = parser.parse_args()
    args.start, args.end = args.start_ns / 1e9, args.end_ns / 1e9
    args.output.mkdir(parents=True, exist_ok=True)
    try:
        output = json.loads(args.stdout.read_text())
        if not isinstance(output, dict) or unsigned(output.get("bytesDiscarded")) is None:
            raise ValueError("Invalid stream accounting")
        output_available = True
    except (OSError, ValueError):
        output = {}
        output_available = False
    # Only generated numeric accounting is copied; no stream content is persisted.
    (args.output / "process-output.json").write_text(json.dumps({
        "bytesDiscarded": unsigned(output.get("bytesDiscarded")), "contentRetained": False,
        "captureAvailable": output_available,
    }) + "\n")
    summary = {"crashReports": collect_reports(args), "systemLog": collect_system_log(args)}
    (args.output / "collection.json").write_text(json.dumps(summary, indent=2) + "\n")
    print("Content-free launch diagnostics:", json.dumps(summary))
    print("Launch diagnostics saved; raw output, logs and crash-report text are not retained.")


if __name__ == "__main__":
    main()
