#!/usr/bin/env python3
"""Run the required macOS contract suites and reject silent coverage loss."""

import collections
import heapq
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import threading
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
    r"^Test Case '(?:-\[(?:(?P<apple_module>\w+)\.)?(?P<apple>\w+) (?P<apple_case>[^\]'\"\r\n]+)\]"
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

# A console payload may contain balanced double-quoted values before a full
# XCTest terminal. Recover that separate shape only for an exact Apple case
# whose ordinary started record appeared earlier; a start is never completion.
APPLE_CASE_STARTED = re.compile(
    r"^Test Case '-\[(\w+)\.(\w+) ([^\]'\"\r\n]+)\]' started\.\r?$",
    re.MULTILINE,
)
QUOTED_INTERLEAVED_CASE_RESULT = re.compile(
    r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{1,9}[+-]\d{4} "
    r"[^\s\[\]]+\[\d+:\d+\] \[[^\]\r\n]+\] [^'\"\r\n]*"
    r"(?:\"[^'\"\r\n]*\"[^'\"\r\n]*)+?"
    r"Test Case '-\[(?P<apple_module>\w+)\.(?P<apple>\w+) (?P<apple_case>[^\]'\"\r\n]+)\]' "
    r"(?P<status>passed|failed|skipped) \([0-9]+(?:\.[0-9]+)? seconds\)\.\r?$",
    re.MULTILINE,
)


def quoted_interleaved_results(output):
    started = {}
    for match in APPLE_CASE_STARTED.finditer(output):
        started.setdefault(match.group(1, 2, 3), match.start())
    for match in QUOTED_INTERLEAVED_CASE_RESULT.finditer(output):
        key = match.group("apple_module", "apple", "apple_case")
        if started.get(key, match.start()) < match.start():
            yield match


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

# The observed console splice can also divide the module token itself. Require
# two nonempty token fragments around exactly one typed physical console record;
# the second line must finish a complete Apple XCTest result.
MODULE_SPLICED_CASE_RESULT = re.compile(
    r"^Test Case '-\[(?P<module_prefix>\w+)"
    r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{1,9}[+-]\d{4} "
    r"[^\s\[\]]+\[\d+:\d+\] \[[^\]\r\n]+\] [^'\"\r\n]*\r?\n"
    r"(?P<module_suffix>\w+)\.(?P<apple>\w+) (?P<apple_case>[^\]\r\n]+)\]' "
    r"(?P<status>passed|failed|skipped) \([0-9]+(?:\.[0-9]+)? seconds\)\.\r?$",
    re.MULTILINE,
)


# A typed console record can divide the method token too. This additional
# two-line shape is bounded and needs an earlier ordinary start with the exact
# reconstructed identity; balanced quoted console values are data, not examples.
METHOD_SPLICED_CASE_RESULT = re.compile(
    r"^Test Case '-\[(?P<apple_module>\w{1,128})\.(?P<apple>\w{1,128}) "
    r"(?P<case_prefix>test\w{1,255})"
    r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{1,9}[+-]\d{4} "
    r"[^\s\[\]]{1,128}\[\d{1,10}:\d{1,10}\] \[[^\]\r\n]{1,128}\] "
    r"(?P<console_payload>[^'\r\n\x00]{0,4096})\r?\n"
    r"(?P<case_suffix>\w{1,255})\]' (?P<status>passed|failed|skipped) "
    r"\([0-9]{1,10}(?:\.[0-9]{1,9})? seconds\)\.\r?$",
    re.MULTILINE,
)


def method_spliced_results(output):
    started = {}
    for match in APPLE_CASE_STARTED.finditer(output):
        started.setdefault(match.group(1, 2, 3), match.start())
    for match in METHOD_SPLICED_CASE_RESULT.finditer(output):
        key = (match.group("apple_module"), match.group("apple"),
               match.group("case_prefix") + match.group("case_suffix"))
        if (match.group("console_payload").count('"') % 2 == 0
                and started.get(key, match.start()) < match.start()):
            yield match


def case_results(output):
    """Yield completed XCTest cases, retaining module identity when emitted."""
    interleaved = (match for match in INTERLEAVED_CASE_RESULT.finditer(output)
                   if match.group("apple") and not any(char in match.group("apple_case") for char in "\r\n"))
    for match in heapq.merge(CASE_RESULT.finditer(output), interleaved, quoted_interleaved_results(output),
                            SPLICED_CASE_RESULT.finditer(output),
                            MODULE_SPLICED_CASE_RESULT.finditer(output), method_spliced_results(output),
                            key=lambda result: result.start()):
        groups = match.groupdict()
        yield {
            "module": (groups.get("module_prefix", "") + groups.get("module_suffix", "")
                       or groups.get("apple_module") or groups.get("portable_module")),
            "suite": groups.get("apple") or groups.get("portable"),
            "case": (groups.get("case_prefix", "") + groups.get("case_suffix", "")
                     or groups.get("apple_case") or groups.get("portable_case")),
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


class BuildProgressObserver:
    """Optional log observations, never compiler activity or emission timestamps."""

    command = ("swift", "build", "--build-tests", "--enable-code-coverage")
    interval = 5
    maximum_samples = 192
    maximum_read = 16 * 1024
    maximum_total_read = 3 * 1024 * 1024
    maximum_json = 64 * 1024
    progress = re.compile(rb"^\[([0-9]{1,7})/([0-9]{1,7})\] (.*)$")
    phases = ((b"Compiling ", "compiling"), (b"Emitting module ", "emittingModule"),
              (b"Linking ", "linking"), (b"Copying ", "copying"), (b"Wrapping AST ", "wrappingAST"))

    def __init__(self, log_path, identity=None):
        self.log_path = log_path
        self.identity = identity
        self.started = time.monotonic()
        self.stopped = False
        self.exited = False
        self.remaining = self.maximum_total_read
        self.attempts = 0
        self.previous_size = None
        self.previous_elapsed = 0
        self.lock = threading.Lock()
        self.samples = []
        self.read_status = "notObserved"

    @classmethod
    def project_progress(cls, data, offset):
        # A tail read may cut either boundary. Only complete physical records
        # count; no suffix, filename, module name or arbitrary text is retained.
        lines = data.split(b"\n")[:-1]
        if offset:
            lines = lines[1:]
        result = None
        for line in lines:
            match = cls.progress.fullmatch(line.rstrip(b"\r"))
            if match is None:
                continue
            completed, total = int(match[1]), int(match[2])
            if not 0 <= completed <= total <= 1_000_000 or total == 0:
                continue
            phase = next((label for prefix, label in cls.phases if match[3].startswith(prefix)), "other")
            result = {"completed": completed, "total": total, "phase": phase}
        return result

    def sample(self, descriptor):
        if self.attempts >= self.maximum_samples or self.remaining <= 0:
            return False
        self.attempts += 1
        elapsed = min(86_400_000, max(self.previous_elapsed, int((time.monotonic() - self.started) * 1000)))
        self.previous_elapsed = elapsed
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or (self.identity is not None
                and (metadata.st_dev, metadata.st_ino) != self.identity):
            raise ValueError("unavailable owned regular log")
        size = metadata.st_size
        if not 0 <= size <= 2 ** 53 - 1:
            raise ValueError("unavailable log size")
        count = min(size, self.maximum_read, self.remaining)
        offset = max(0, size - count)
        # Reserve before reading: a partial read followed by an OS exception
        # cannot regain allowance for another read. No shared lock covers I/O.
        self.remaining -= count
        data = os.pread(descriptor, count, offset)
        if len(data) > count:
            raise ValueError("unavailable log read")
        self.remaining += count - len(data)
        sample = {"elapsedMilliseconds": elapsed, "logBytes": size,
                  "logGrowth": self.previous_size is not None and size > self.previous_size,
                  "tailTruncated": offset > 0,
                  "progress": self.project_progress(data, offset)}
        self.previous_size = size
        with self.lock:
            self.samples.append(sample)
            self.read_status = "sampled"
        return True

    def run(self):
        descriptor = None
        try:
            descriptor = os.open(self.log_path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
            # Only this daemon waits. The command owner never joins or waits
            # for a read/close/sleep, including when the filesystem is stuck.
            pause = threading.Event()
            while not self.stopped and self.sample(descriptor):
                if not self.stopped:
                    pause.wait(self.interval)
        except Exception:
            # Optional diagnostics never expose OS errors or affect the gate.
            with self.lock:
                self.read_status = "unavailable"
        finally:
            if descriptor is not None:
                try:
                    os.close(descriptor)
                except OSError:
                    pass
            self.exited = True

    def start(self):
        threading.Thread(target=self.run, name="build-log-observer", daemon=True).start()

    def finish(self, artifacts_dir):
        # Called only after command timing capture and any owned kill/reap.
        # A blocked worker can retain its descriptor until wrapper exit.
        self.stopped = True
        samples = None
        read_status = "unknown"
        remaining = None
        if self.lock.acquire(blocking=False):
            try:
                samples = list(self.samples)
                read_status = self.read_status
                remaining = self.remaining
            finally:
                self.lock.release()
        payload = {"schemaVersion": 1, "snapshotStatus": "captured" if samples is not None else "lockBusy",
                   "stopRequested": True, "workerExitObserved": self.exited,
                   "compilerActivityObserved": False, "timeOrigin": "observerBootstrap",
                   "sampleCapReached": None if samples is None else len(samples) >= self.maximum_samples,
                   "reservedReadBytes": None if remaining is None else self.maximum_total_read - remaining,
                   "readStatus": read_status, "samples": samples}
        try:
            encoded = json.dumps(payload, separators=(",", ":")) + "\n"
            if len(encoded.encode("utf-8")) <= self.maximum_json:
                (artifacts_dir / "progress.json").write_text(encoded, encoding="utf-8")
        except Exception:
            pass


def run_gate(command, artifacts_dir, budget, required_suites=REQUIRED_SUITES, stage="test"):
    artifacts_dir = Path(artifacts_dir)
    started = time.monotonic()
    command_elapsed = None
    exit_code = 1
    errors = []
    counts = {}
    process = None
    observer = None
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
            if stage == "build" and tuple(command) == BuildProgressObserver.command:
                try:
                    metadata = os.fstat(log.fileno())
                    observer = BuildProgressObserver(log_path, (metadata.st_dev, metadata.st_ino))
                    observer.start()
                except InterruptedError:
                    raise
                except Exception:
                    pass
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
        if observer is not None:
            try:
                observer.finish(artifacts_dir)
            except Exception:
                pass
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
