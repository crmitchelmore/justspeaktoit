#!/usr/bin/env python3
"""Run a test command in an exclusively owned checkout with bounded peer cleanup.

The caller must retain exclusive checkout ownership from admission through cleanup;
no editor, agent or watcher may write concurrently. Admission and exclusive restore
protect preexisting/current paths, not deletion attribution against outside writers.
Stop and reconcile if checkout ownership is lost.
"""
import argparse
import collections
import importlib.util
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import threading


SUITE = "ModulateOpeningAudioQualificationTests"
REQUIRED_CASES = (
    "testHeldHTTP101PreservesOpeningAndLivePCMExactlyOnceInCaptureOrder",
    "testPrestartPrerollIsSeparateAndPostStopAudioDoesNotLeakIntoRestart",
    "testFailedHeldUpgradeReportsTransportFailureAndClearsPendingAudioBeforeRestart",
    "testStopDuringHeldUpgradeSeparatesRestartFromLateOldUpgrade",
)
_SPEC = importlib.util.spec_from_file_location("core_journey_gate", Path(__file__).with_name("run-core-journey-e2e.py"))
COVERAGE = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(COVERAGE)


def qualification(output):
    errors, counts = COVERAGE.coverage_errors(output, (SUITE,))
    results = [result for result in COVERAGE.case_results(output) if result["suite"] == SUITE]
    if any(result["module"] != "SpeakPortableTests" for result in results):
        errors.append("Required Modulate cases must belong to the actual SpeakPortableTests module")
    actual = collections.Counter(result["case"] for result in results)
    if actual != collections.Counter(REQUIRED_CASES):
        errors.append("Every exact required Modulate XCTest case must complete once, without missing/extra/duplicate cases")
    return errors, counts, results


class OwnedSignal(RuntimeError):
    def __init__(self, number):
        super().__init__(f"Owned runner interrupted by signal {number}")
        self.number = number


def snapshot_portable_lock(root):
    if os.environ.get("SPEAK_PORTABLE_CORE") != "1":
        return None
    path = root / "Package.resolved"
    try:
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode):
            return None
        expected = subprocess.check_output(["git", "show", "HEAD:Package.resolved"], cwd=root,
                                           stderr=subprocess.DEVNULL)
        if path.read_bytes() != expected:
            return None
        return {"path": path, "bytes": expected, "mode": stat.S_IMODE(metadata.st_mode), "root": root}
    except (OSError, subprocess.CalledProcessError):
        return None


def admit_portable_lock(root):
    snapshot = snapshot_portable_lock(root)
    if os.environ.get("SPEAK_PORTABLE_CORE") == "1":
        try:
            (root / "Package.resolved").lstat()
        except FileNotFoundError:
            return None
        if snapshot is None:
            raise RuntimeError("Portable lockfile is not an owned HEAD-identical regular file; command refused")
    return snapshot


def restore_deleted_portable_lock(snapshot):
    """Restore an admitted deletion under the caller's exclusive-checkout contract."""
    if snapshot is None:
        return False
    path = snapshot["path"]
    try:
        path.lstat()
        return False  # Never replace an existing regular file, symlink or user edit.
    except FileNotFoundError:
        pass
    change = subprocess.check_output(["git", "diff", "--name-status", "--", "Package.resolved"],
                                     cwd=snapshot["root"], text=True).strip()
    if change != "D\tPackage.resolved":
        return False
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, snapshot["mode"])
    except FileExistsError:
        return False  # Another writer won; its contents must remain untouched.
    with os.fdopen(descriptor, "wb") as restored:
        os.fchmod(restored.fileno(), snapshot["mode"])
        restored.write(snapshot["bytes"])
    return True


def stop_owned(process):
    """Only process groups created here via start_new_session belong to this runner."""
    if process is None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=3)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--test-timeout", type=int, default=120)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or not 1 <= args.test_timeout <= 300 or os.name != "posix":
        parser.error("requires a POSIX test command and timeout between 1 and 300 seconds")
    args.output_dir.mkdir(parents=True, exist_ok=False)
    lock_snapshot = None

    def interrupted(number, _frame):
        raise OwnedSignal(number)

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    ready_file = args.output_dir / "peer-ready.json"
    ready = threading.Event()
    state = {}
    peer = child = reader = None
    status = 1
    errors = []
    with (args.output_dir / "peer.log").open("w") as log:
        try:
            lock_snapshot = admit_portable_lock(Path.cwd())
            peer = subprocess.Popen([
                sys.executable, "-B", str(Path(__file__).with_name("modulate-opening-audio-probe.py")),
                "--ready-file", str(ready_file), "--max-seconds", str(args.test_timeout + 10),
            ], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)

            def capture():
                for line in peer.stdout:
                    log.write(line)
                    log.flush()
                    try:
                        event = json.loads(line)
                    except ValueError:
                        continue
                    if event.get("event") == "ready":
                        state.update(event)
                        ready.set()

            reader = threading.Thread(target=capture, daemon=True)
            reader.start()
            if not ready.wait(5) or state.get("host") != "127.0.0.1" or not 1 <= state.get("port", 0) <= 65535:
                raise RuntimeError("owned synthetic peer did not signal bounded loopback readiness")
            environment = {**os.environ, "JSTI_MODULATE_OPENING_PROBE_PORT": str(state["port"])}
            with (args.output_dir / "tests.log").open("w") as test_log:
                child = subprocess.Popen(command, env=environment, stdout=test_log, stderr=subprocess.STDOUT,
                                         start_new_session=True)
                print("Owned Modulate test command started", flush=True)
                try:
                    status = child.wait(timeout=args.test_timeout)
                except subprocess.TimeoutExpired:
                    errors.append("Synthetic test command exceeded its owned-process deadline")
                    status = 124
        except OwnedSignal as error:
            status = 128 + error.number
            errors.append(str(error))
        except (OSError, RuntimeError) as error:
            errors.append(str(error))
        finally:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            for process in (child, peer):
                try:
                    stop_owned(process)
                except (OSError, subprocess.TimeoutExpired) as error:
                    errors.append(f"Owned process cleanup failed: {type(error).__name__}")
            if reader:
                reader.join(timeout=3)
                if reader.is_alive():
                    errors.append("Owned peer output reader did not terminate")
    restored_lockfile = False
    if child is not None:
        try:
            restored_lockfile = restore_deleted_portable_lock(lock_snapshot)
        except (OSError, subprocess.CalledProcessError) as error:
            errors.append(f"Owned portable lockfile restoration failed: {type(error).__name__}")
    test_log_path = args.output_dir / "tests.log"
    output = test_log_path.read_text(errors="replace") if test_log_path.exists() else ""
    print(output, end="", flush=True)
    coverage_errors, counts, results = qualification(output)
    errors.extend(coverage_errors)
    exit_code = status if status != 0 else (1 if errors else 0)
    try:
        revision = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
        dirty = bool(subprocess.check_output(["git", "status", "--porcelain"], text=True).strip())
    except (OSError, subprocess.CalledProcessError):
        revision, dirty = None, None
        errors.append("Could not record qualification source revision")
        if exit_code == 0:
            exit_code = 1
    receipt = {"restoredPortableLockfile": restored_lockfile, "ownedCommandPID": child.pid if child else None,
               "ownedPeerPID": peer.pid if peer else None, "sourceRevision": revision, "sourceDirty": dirty, "suite": SUITE, "requiredCases": REQUIRED_CASES, "caseResults": results,
               "counts": counts, "errors": errors, "commandExitCode": status, "qualificationExitCode": exit_code}
    (args.output_dir / "qualification.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    for error in errors:
        print(error, file=sys.stderr)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
