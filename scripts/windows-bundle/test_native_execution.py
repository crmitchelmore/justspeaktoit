#!/usr/bin/env python3
"""Unit tests for verify-native-execution.py; Windows process calls are faked."""
import base64
import contextlib
import datetime
import importlib.util
import io
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
sys.dont_write_bytecode = True


def load(name, file_name):
    spec = importlib.util.spec_from_file_location(name, HERE / file_name)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


NATIVE = load("verify_native_execution", "verify-native-execution.py")
BUNDLE_TESTS = load("test_windows_bundle", "test_windows_bundle.py")
PE = NATIVE.windows_pe
AMD64, ARM64 = PE.IMAGE_FILE_MACHINE_AMD64, PE.IMAGE_FILE_MACHINE_ARM64


class FakeAPI:
    def __init__(self, machine=ARM64, native=ARM64, wow64=0, modules=(), machine_error=False):
        self.machine, self.native, self.wow64_machine = machine, native, wow64
        self.samples, self.machine_error = [list(sample) for sample in modules], machine_error
        self.closed = []

    def open(self, pid):
        return ("handle", pid)

    def close(self, handle):
        self.closed.append(handle)

    def current(self):
        return "current"

    def wow64(self, handle):
        return self.wow64_machine, self.native

    def process_machine(self, handle):
        if self.machine_error:
            raise OSError(87, "GetProcessInformation(ProcessMachineTypeInfo) failed")
        return self.machine, 1

    def modules(self, handle, known):
        return self.samples.pop(0) if len(self.samples) > 1 else (self.samples[0] if self.samples else [])


class FakeProcess:
    def __init__(self, polls=2, exit_code=0):
        self.pid, self.polls, self.exit_code = 4242, polls, exit_code
        self.returncode, self.killed = None, False

    def poll(self):
        self.polls -= 1
        if self.polls <= 0:
            self.returncode = self.exit_code
        return self.returncode

    def kill(self):
        self.killed = True
        self.returncode = 1

    def wait(self):
        return self.returncode


class Clock:
    def __init__(self, step=1.0):
        self.now, self.step = 0.0, step

    def __call__(self):
        self.now += self.step
        return self.now


def native_image(path, architecture):
    return {"path": path, "architecture": "arm64x" if path.endswith("vcruntime140.dll") else "arm64", "native": True}


APP = "C:\\a\\SpeakWindows.exe"
SYSTEM = ["C:\\Windows\\System32\\ntdll.dll", "C:\\Windows\\System32\\KERNEL32.DLL"]


class ObservationTests(unittest.TestCase):
    def observe(self, api, process=None, timeout=60.0):
        return NATIVE.observe(process or FakeProcess(), api, clock=Clock(), sleep=lambda _: None, timeout=timeout)

    def test_native_arm64_process_passes_with_its_modules_recorded(self):
        api = FakeAPI(modules=[[APP] + SYSTEM, [APP] + SYSTEM + ["C:\\a\\swiftCore.dll", "C:\\a\\vcruntime140.dll"]])
        observation = self.observe(api)
        self.assertEqual(observation["processMachine"], ARM64)
        self.assertEqual(len(observation["modules"]), 5)
        self.assertEqual(api.closed, [("handle", 4242)])
        failures, images = NATIVE.assess_run(observation, "arm64", "C:\\Windows", native_image)
        self.assertEqual(failures, [])
        self.assertEqual([record["path"] for record in images],
                         [APP, "C:\\a\\swiftCore.dll", "C:\\a\\vcruntime140.dll"])

    def test_emulated_x64_process_on_an_arm64_host_fails(self):
        api = FakeAPI(machine=AMD64, modules=[[APP, "C:\\Windows\\System32\\xtajit64.dll"] + SYSTEM])
        failures, _ = NATIVE.assess_run(self.observe(api), "arm64", "C:\\Windows", native_image)
        self.assertIn("Windows reported a x64 process, not arm64", failures)
        self.assertTrue(any("emulation modules were loaded" in failure and "xtajit64.dll" in failure
                            for failure in failures))

    def test_foreign_modules_exit_codes_and_missing_evidence_fail(self):
        def reader(path, architecture):
            return {"path": path, "architecture": "x64" if "ggml" in path else "arm64", "native": "ggml" not in path}
        api = FakeAPI(modules=[[APP, "C:\\rt\\ggml-cpu.dll"] + SYSTEM])
        failures, _ = NATIVE.assess_run(self.observe(api, FakeProcess(exit_code=3)), "arm64", "C:\\Windows", reader)
        self.assertIn("exited with 3", failures)
        self.assertIn("loaded a x64 module: C:\\rt\\ggml-cpu.dll", failures)
        failures, _ = NATIVE.assess_run(self.observe(FakeAPI()), "arm64", "C:\\Windows", reader)
        self.assertIn("no loaded modules were observed", failures)

    def test_timeout_kills_the_process(self):
        process = FakeProcess(polls=1000)
        observation = self.observe(FakeAPI(modules=[[APP]]), process, timeout=3.0)
        self.assertTrue(process.killed)
        self.assertTrue(observation["timedOut"])
        failures, _ = NATIVE.assess_run(observation, "arm64", "C:\\Windows", native_image)
        self.assertIn("did not exit before its deadline", failures)

    def test_machine_is_only_inferred_without_process_machine_info_on_x64_hosts(self):
        x64 = FakeAPI(machine=None, native=AMD64, machine_error=True)
        self.assertEqual(NATIVE.query_machine(x64, "h"), (AMD64, None, AMD64))
        wow = FakeAPI(native=AMD64, wow64=PE.IMAGE_FILE_MACHINE_I386, machine_error=True)
        with self.assertRaises(OSError):
            NATIVE.query_machine(wow, "h")
        arm = FakeAPI(machine_error=True, modules=[[APP]])
        with self.assertRaises(OSError):
            NATIVE.query_machine(arm, "h")
        observation = self.observe(arm)
        self.assertIsNone(observation["processMachine"])
        self.assertTrue(observation["queryErrors"])
        failures, _ = NATIVE.assess_run(observation, "arm64", "C:\\Windows", native_image)
        self.assertIn("Windows reported a missing process, not arm64", failures)


class ImageAndHostTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)

    def write(self, name, **options):
        path = self.root / name
        path.write_bytes(BUNDLE_TESTS.build_pe(["KERNEL32.dll"], **options))
        return path

    def test_images_must_run_natively_on_the_target(self):
        arm64 = self.write("SpeakWindows.exe", machine=ARM64)
        hybrid = self.write("msvcp140.dll", machine=ARM64, dll=True, hybrid_metadata=0x180105050)
        records = NATIVE.check_images([arm64, hybrid], "arm64")
        self.assertEqual([record["architecture"] for record in records], ["arm64", "arm64x"])
        self.assertEqual(records[0]["sha256"], NATIVE.sha256_file(arm64))
        for name, options in [("x64.exe", {}), ("ec.dll", {"dll": True, "hybrid_metadata": 0x18000A2E8})]:
            with self.assertRaisesRegex(NATIVE.ExecutionError, "not native arm64 images"):
                NATIVE.check_images([self.write(name, **options)], "arm64")
        with self.assertRaisesRegex(NATIVE.ExecutionError, "not native x64 images"):
            NATIVE.check_images([arm64], "x64")

    def test_host_must_be_native_for_the_target(self):
        toolchain = self.write("swift.exe", machine=ARM64)
        record = NATIVE.check_host(FakeAPI(), "arm64", [toolchain])
        self.assertEqual(record["nativeMachine"], "arm64")
        self.assertEqual(record["pythonProcessMachine"], "arm64")
        self.assertEqual(record["toolchain"][0]["architecture"], "arm64")
        with self.assertRaisesRegex(NATIVE.ExecutionError, "native machine is x64, not arm64"):
            NATIVE.check_host(FakeAPI(machine=AMD64, native=AMD64), "arm64")

    def test_run_requires_native_success_and_expected_output(self):
        executable = self.write("SpeakWindows.exe", machine=ARM64)
        stdout, stderr = self.root / "out.log", self.root / "err.log"

        def launch(arguments, stdout, stderr):
            self.assertEqual(arguments, [str(executable), "--self-test"])
            stdout.write(b"Windows native self-test passed\n")
            return FakeProcess()

        api = FakeAPI(modules=[[str(executable)] + SYSTEM])
        record = NATIVE.run([str(executable), "--self-test"], api, "arm64", "self-test", 30, stdout, stderr,
                            ["self-test passed"], "C:\\Windows", launch, native_image)
        self.assertEqual(record["failures"], [])
        self.assertEqual(record["processMachine"], "arm64")
        self.assertEqual(record["executable"]["architecture"], "arm64")
        record = NATIVE.run([str(executable), "--self-test"], FakeAPI(modules=[[str(executable)]]), "arm64",
                            "self-test", 30, stdout, stderr, ["window passed"], "C:\\Windows", launch, native_image)
        self.assertIn("output lacks 'window passed'", record["failures"])
        with self.assertRaisesRegex(NATIVE.ExecutionError, "not native arm64 images"):
            NATIVE.run([str(self.write("x64.exe"))], api, "arm64", "x", 30, stdout, stderr, (), "C:\\Windows",
                       launch, native_image)


class DiagnosticInventoryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="private-canary-")
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)

    def inventory(self, files, version=None, **options):
        windows = types.SimpleNamespace(name="nt", fstat=options.get("fstat", os.fstat))
        with mock.patch.object(NATIVE, "os", windows), mock.patch.object(NATIVE, "DIAGNOSTIC_CANDIDATES", files):
            return NATIVE.diagnostic_tools(read_version=version or (lambda _: None), clock=options.get("clock", lambda: 0))

    def image(self, name, machine=ARM64):
        path = self.root / name
        path.write_bytes(BUNDLE_TESTS.build_pe(machine=machine))
        return path

    def test_fixed_candidates_and_nonwindows_do_not_discover_or_launch_tools(self):
        self.assertEqual(len(NATIVE.DIAGNOSTIC_CANDIDATES), 11)
        self.assertEqual(len(set(label for label, _ in NATIVE.DIAGNOSTIC_CANDIDATES)), 11)
        self.assertTrue(all(path.startswith(("C:\\Program Files (x86)\\Windows Kits\\10\\Debuggers\\",
                                                   "C:\\Windows\\"))
                            for _, path in NATIVE.DIAGNOSTIC_CANDIDATES))
        with mock.patch.object(NATIVE, "os", types.SimpleNamespace(name="posix")), \
                mock.patch.object(NATIVE.pathlib.Path, "lstat", side_effect=AssertionError("no file read")), \
                mock.patch.object(NATIVE.subprocess, "run", side_effect=AssertionError("no launch")):
            self.assertEqual(NATIVE.diagnostic_tools(), {"status": "unsupported", "tools": []})

    def test_owned_fake_pe_hash_architecture_numeric_version_and_no_private_path(self):
        arm, x64 = self.image("gflags.exe"), self.image("cdb.exe", AMD64)
        result = self.inventory((("sdk10-arm64-gflags", str(arm)), ("sdk10-x64-cdb", str(x64))),
                                version=lambda _: [10, 0, 26100, 1])
        self.assertEqual(result["coverage"], "fixed-sdk10-system-candidates-only")
        for row, path, arch in zip(result["tools"], (arm, x64), ("arm64", "x64")):
            self.assertEqual(row["status"], "present")
            self.assertTrue(row["present"])
            self.assertEqual(row["architecture"], arch)
            self.assertEqual(row["sha256"], NATIVE.sha256_file(path))
            self.assertEqual(row["version"], [10, 0, 26100, 1])
        serialized = json.dumps(result)
        self.assertNotIn(str(self.root), serialized)
        self.assertNotIn("private-canary", serialized)
        self.assertNotIn("path", result["tools"][0])

    def test_absent_denied_reparse_and_unexpected_errors_stay_closed(self):
        files = (("sdk10-arm64-cdb", str(self.root / "missing.exe")),)
        self.assertEqual(self.inventory(files)["tools"][0],
                         {"candidate": "sdk10-arm64-cdb", "status": "absent", "present": False})
        for error, status in [(PermissionError("private-canary"), "denied"),
                              (OSError("private-canary"), "unknown")]:
            with mock.patch.object(NATIVE.pathlib.Path, "lstat", side_effect=error):
                result = self.inventory(files)
            self.assertEqual(result["tools"][0]["status"], status)
            self.assertIsNone(result["tools"][0]["present"])
            self.assertNotIn("private-canary", json.dumps(result))
        fake = types.SimpleNamespace(st_mode=0o100600, st_file_attributes=0x400)
        with mock.patch.object(NATIVE.pathlib.Path, "lstat", return_value=fake), \
                mock.patch.object(NATIVE.pathlib.Path, "open", side_effect=AssertionError("no reparse read")):
            self.assertEqual(self.inventory(files)["tools"][0]["status"], "unknown")

    def test_invalid_pe_and_private_or_out_of_range_versions_are_not_exported(self):
        path = self.root / "windbg.exe"
        path.write_bytes(b"not a PE private-canary")
        for version in ("private-canary", [1, 2, 3], [1, 2, 3, 65536], [True, 2, 3, 4], None):
            with self.subTest(version=version):
                result = self.inventory((("sdk10-arm64-windbg", str(path)),), lambda _: version)
                row = result["tools"][0]
                self.assertEqual(row["status"], "present")
                self.assertEqual(row["architecture"], "unknown")
                self.assertIsNone(row["version"])
                self.assertNotIn("private-canary", json.dumps(result))
        result = self.inventory((("sdk10-arm64-windbg", str(path)),),
                                mock.Mock(side_effect=RuntimeError("private-canary")))
        self.assertIsNone(result["tools"][0]["version"])
        self.assertNotIn("private-canary", json.dumps(result))

    def test_file_total_and_between_candidate_time_budgets_remain_unknown(self):
        first, second = self.image("gflags.exe"), self.image("cdb.exe")
        files = (("sdk10-arm64-gflags", str(first)), ("sdk10-arm64-cdb", str(second)))
        reader = mock.Mock(return_value=[1, 2, 3, 4])
        with mock.patch.object(NATIVE, "DIAGNOSTIC_FILE_LIMIT", 16):
            result = self.inventory(files, reader)
        self.assertTrue(all(row["status"] == "unknown" for row in result["tools"]))
        reader.assert_not_called()
        with mock.patch.object(NATIVE, "DIAGNOSTIC_TOTAL_LIMIT", first.stat().st_size):
            result = self.inventory(files)
        self.assertEqual([row["status"] for row in result["tools"]], ["present", "unknown"])
        with mock.patch.object(NATIVE.pathlib.Path, "lstat", side_effect=AssertionError("budget exhausted")):
            result = self.inventory(files, clock=iter((0, 4, 5)).__next__)
        self.assertTrue(all(row["status"] == "unknown" for row in result["tools"]))

    def test_file_replaced_during_version_read_discards_mixed_metadata(self):
        path = self.image("gflags.exe")
        def replace(_):
            path.write_bytes(b"replacement-private-canary")
            return [1, 2, 3, 4]
        result = self.inventory((("sdk10-arm64-gflags", str(path)),), replace)
        self.assertEqual(result["tools"], [
            {"candidate": "sdk10-arm64-gflags", "status": "unknown", "present": None}])
        self.assertNotIn("private-canary", json.dumps(result))

    def test_changed_size_consumes_actual_read_budget_before_validation(self):
        path = self.image("gflags.exe")
        fake = types.SimpleNamespace(st_mode=0o100600, st_size=8, st_ino=1, st_mtime_ns=1)
        stream = mock.MagicMock()
        stream.__enter__.return_value = stream
        stream.read.side_effect = lambda count: b"x" * count
        reader = mock.Mock(return_value=None)
        with mock.patch.object(NATIVE.pathlib.Path, "lstat", return_value=fake), \
                mock.patch.object(NATIVE.pathlib.Path, "open", return_value=stream), \
                mock.patch.object(NATIVE, "DIAGNOSTIC_TOTAL_LIMIT", 16):
            result = self.inventory((("sdk10-arm64-gflags", str(path)), ("sdk10-arm64-cdb", str(path))),
                                    reader, fstat=lambda _: fake)
        # First changing file consumes9 bytes; the second8-byte candidate cannot fit remaining7.
        stream.read.assert_called_once_with(9)
        reader.assert_not_called()
        self.assertTrue(all(row["status"] == "unknown" for row in result["tools"]))
        stream.reset_mock()
        with mock.patch.object(NATIVE.pathlib.Path, "lstat", return_value=fake), \
                mock.patch.object(NATIVE.pathlib.Path, "open", return_value=stream), \
                mock.patch.object(NATIVE, "DIAGNOSTIC_TOTAL_LIMIT", 8):
            self.inventory((("sdk10-arm64-gflags", str(path)),), reader, fstat=lambda _: fake)
        stream.read.assert_called_once_with(8)

    def test_partial_read_error_keeps_reservation_and_no_metadata(self):
        path = self.image("gflags.exe")
        fake = types.SimpleNamespace(st_mode=0o100600, st_size=8, st_ino=1, st_mtime_ns=1)
        consumed = []
        def partial_read_then_error(count):
            consumed.append(count)  # The stream consumed bytes before reporting its IO failure.
            raise OSError("private-canary")
        stream = mock.MagicMock()
        stream.__enter__.return_value = stream
        stream.read.side_effect = partial_read_then_error
        reader = mock.Mock(return_value=[1, 2, 3, 4])
        with mock.patch.object(NATIVE.pathlib.Path, "lstat", return_value=fake), \
                mock.patch.object(NATIVE.pathlib.Path, "open", return_value=stream) as opened, \
                mock.patch.object(NATIVE, "DIAGNOSTIC_TOTAL_LIMIT", 16):
            result = self.inventory((("sdk10-arm64-gflags", str(path)), ("sdk10-arm64-cdb", str(path))), reader)
        self.assertEqual(consumed, [9])
        stream.read.assert_called_once_with(9)
        opened.assert_called_once()
        reader.assert_not_called()
        self.assertEqual(result["tools"][0],
                         {"candidate": "sdk10-arm64-gflags", "status": "unknown", "present": None})
        self.assertEqual(result["tools"][1]["status"], "unknown")
        self.assertTrue(all("sha256" not in row and "version" not in row for row in result["tools"]))
        self.assertNotIn("private-canary", json.dumps(result))

    def test_post_read_denial_discards_previous_hash_and_version(self):
        path = self.image("gflags.exe")
        before = path.lstat()
        reader = mock.Mock(return_value=[1, 2, 3, 4])
        with mock.patch.object(NATIVE.pathlib.Path, "lstat", return_value=before), \
                mock.patch.object(NATIVE.pathlib.Path, "stat", side_effect=PermissionError("private-canary")):
            result = self.inventory((("sdk10-arm64-gflags", str(path)),), reader)
        reader.assert_called_once_with(path)
        self.assertEqual(result["tools"], [
            {"candidate": "sdk10-arm64-gflags", "status": "denied", "present": None}])
        self.assertNotIn("private-canary", json.dumps(result))

    def test_optional_inventory_failure_never_changes_host_verdict(self):
        with mock.patch.object(NATIVE, "diagnostic_tools", side_effect=RuntimeError("private-canary")) as reader:
            result = NATIVE.check_host(FakeAPI(), "arm64")
            self.assertEqual(result["nativeMachine"], "arm64")
            self.assertEqual(result["diagnosticTools"], {"status": "unavailable", "tools": []})
            self.assertNotIn("private-canary", json.dumps(result))
            reader.reset_mock()
            with self.assertRaisesRegex(NATIVE.ExecutionError, "native machine is x64"):
                NATIVE.check_host(FakeAPI(machine=AMD64, native=AMD64), "arm64")
            reader.assert_not_called()


class ApplicationErrorTests(unittest.TestCase):
    def setUp(self):
        self.started = datetime.datetime(2026, 10, 28, 7, 20, 0, tzinfo=datetime.timezone.utc)
        self.ended = self.started + datetime.timedelta(seconds=2)

    def event(self, **changes):
        data = {"AppName": "SpeakWindows.exe", "AppPath": APP, "ProcessId": "0x1092",
                "ModuleName": "ntdll.dll", "ModuleVersion": "10.0.26100.1",
                "ExceptionCode": "c0000374", "FaultingOffset": "0000000000012345"}
        data.update(changes)
        return {"time": "2026-10-28T07:20:01Z", "data": data}

    def project(self, events):
        return NATIVE.project_application_error(events, 4242, APP, self.started, self.ended)

    def query(self, payload, **changes):
        def child(arguments, **options):
            self.assertEqual(arguments[:5], ["pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command"])
            self.assertIn("-MaxEvents 16", arguments[5])
            self.assertNotIn(".Message", arguments[5])
            self.assertNotIn("Execution", arguments[5])
            self.assertEqual(options["timeout"], 5)
            self.assertEqual(options["stdin"], NATIVE.subprocess.DEVNULL)
            self.assertEqual(options["stderr"], NATIVE.subprocess.DEVNULL)
            self.assertNotIn("EVENT_TEST_SECRET", options["env"])
            result = {"returncode": 0, "stdout": json.dumps(payload).encode()}
            result.update(changes)
            return types.SimpleNamespace(**result)
        with mock.patch.dict(os.environ, {"EVENT_TEST_SECRET": "private-canary"}):
            return NATIVE.application_error(4242, APP, self.started, self.ended, query=child)

    def test_exact_owned_crash_projects_only_finite_fields(self):
        result = self.query({"status": "ok", "events": [self.event()]})
        self.assertEqual(result, {"status": "observed", "module": "ntdll.dll", "version": "10.0.26100.1",
                                  "exceptionCode": "0xc0000374", "faultOffset": "0x0000000000012345",
                                  "timeUTC": "2026-10-28T07:20:01+00:00"})
        self.assertNotIn(APP, json.dumps(result))

    def test_wrong_process_path_application_and_time_do_not_match(self):
        for changes in ({"ProcessId": "4243"}, {"AppPath": r"C:\other\SpeakWindows.exe"},
                        {"AppName": "other.exe"}):
            with self.subTest(changes=changes):
                self.assertEqual(self.project([self.event(**changes)]), {"status": "no-match"})
        event = self.event()
        event["time"] = "2026-10-28T07:20:03Z"
        self.assertEqual(self.project([event]), {"status": "no-match"})

    def test_faulting_process_alias_is_explicit_and_conflict_is_unknown(self):
        event = self.event()
        del event["data"]["ProcessId"]
        event["data"]["FaultingProcessId"] = "4242"
        self.assertEqual(self.project([event])["status"], "observed")
        self.assertEqual(self.project([self.event(FaultingProcessId="4243")]), {"status": "invalid"})
        event = self.event()
        del event["data"]["ProcessId"]
        event["data"]["ExecutionProcessID"] = "4242"
        self.assertEqual(self.project([event]), {"status": "invalid"})

    def test_ambiguous_missing_and_oversized_sets_remain_unknown(self):
        self.assertEqual(self.project([]), {"status": "no-match"})
        self.assertEqual(self.project([self.event(), self.event()]), {"status": "ambiguous"})
        self.assertEqual(self.project([self.event()] * 17), {"status": "invalid"})

    def test_raw_messages_paths_and_invalid_numeric_values_cannot_escape(self):
        for changes in ({"ModuleName": r"C:\private-canary\ntdll.dll"}, {"ModuleVersion": "private-canary"},
                        {"ExceptionCode": "private-canary"}, {"FaultingOffset": "0x" + "f" * 17},
                        {"ProcessId": "0xprivate-canary"}, {"Message": "private-canary"}):
            with self.subTest(changes=changes):
                result = self.project([self.event(**changes)])
                self.assertEqual(result, {"status": "invalid"})
                self.assertNotIn("private-canary", json.dumps(result))
        for time in ("invalid", "2026-10-28T07:20:01", None):
            event = self.event()
            event["time"] = time
            self.assertEqual(self.project([event]), {"status": "invalid"})

    def test_query_failure_output_and_timeout_remain_fixed_unknown(self):
        for payload, options, expected in [({"status": "unavailable"}, {}, "unavailable"),
                                           ({"private-canary": "raw-response"}, {}, "invalid"),
                                           ({}, {"returncode": 1, "stdout": b"private-canary"}, "unavailable"),
                                           ({}, {"stdout": b"private-canary"}, "unavailable"),
                                           ({}, {"stdout": b"x" * 65537}, "invalid")]:
            with self.subTest(options=list(options), expected=expected):
                self.assertEqual(self.query(payload, **options), {"status": expected})
        for error, expected in [(NATIVE.subprocess.TimeoutExpired("private-canary", 5), "timeout"),
                                (PermissionError("private-canary"), "unavailable"),
                                (RuntimeError("private-canary"), "unavailable")]:
            with self.subTest(type=type(error).__name__):
                self.assertEqual(NATIVE.application_error(4242, APP, self.started, self.ended,
                                                         query=mock.Mock(side_effect=error)), {"status": expected})

    def test_run_queries_only_abnormal_owned_windows_smoke_without_changing_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            executable = root / "SpeakWindows.exe"
            executable.write_bytes(BUNDLE_TESTS.build_pe(machine=ARM64))
            stdout, stderr = root / "out", root / "err"
            reader = mock.Mock(return_value={"status": "observed", "module": "ntdll.dll"})
            windows = types.SimpleNamespace(name="nt", path=os.path, environ=os.environ)
            def launch(arguments, stdout, stderr):
                return FakeProcess(exit_code=3221226356)
            with mock.patch.object(NATIVE, "os", windows):
                result = NATIVE.run([str(executable), "--ui-smoke-test"], FakeAPI(modules=[[str(executable)]]),
                                    "arm64", "ui-smoke-test", 30, stdout, stderr, ["window passed"],
                                    "C:\\Windows", launch, native_image, reader)
            self.assertEqual(result["exitCode"], 3221226356)
            self.assertFalse(result["timedOut"])
            self.assertEqual(result["failures"], ["exited with 3221226356", "output lacks 'window passed'"])
            self.assertEqual(result["applicationError"]["module"], "ntdll.dll")
            self.assertEqual(reader.call_args.args[:2], (4242, os.path.abspath(executable)))
            self.assertLessEqual(reader.call_args.args[2], reader.call_args.args[3])
            reader.side_effect = RuntimeError("private-canary")
            with mock.patch.object(NATIVE, "os", windows):
                failed = NATIVE.run([str(executable), "--ui-smoke-test"], FakeAPI(modules=[[str(executable)]]),
                                    "arm64", "ui-smoke-test", 30, stdout, stderr, ["window passed"],
                                    "C:\\Windows", launch, native_image, reader)
            self.assertEqual(failed["failures"], result["failures"])
            self.assertEqual(failed["applicationError"], {"status": "unavailable"})

    def test_success_other_commands_nonwindows_and_intentional_timeout_never_query(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            executable = root / "SpeakWindows.exe"
            executable.write_bytes(BUNDLE_TESTS.build_pe(machine=ARM64))
            for host, label, arguments, polls, code, timeout in [
                    ("nt", "ui-smoke-test", ["--ui-smoke-test"], 2, 0, 30),
                    ("nt", "self-test", ["--self-test"], 2, 1, 30),
                    ("nt", "ui-smoke-test", ["--self-test"], 2, 1, 30),
                    ("posix", "ui-smoke-test", ["--ui-smoke-test"], 2, 1, 30),
                    ("nt", "ui-smoke-test", ["--ui-smoke-test"], 100, 1, -1)]:
                with self.subTest(host=host, label=label, polls=polls):
                    reader = mock.Mock(side_effect=AssertionError("must not query"))
                    process = FakeProcess(polls=polls, exit_code=code)
                    environment = types.SimpleNamespace(name=host, path=os.path, environ=os.environ)
                    with mock.patch.object(NATIVE, "os", environment):
                        result = NATIVE.run([str(executable)] + arguments, FakeAPI(modules=[[str(executable)]]),
                                            "arm64", label, timeout, root / "out", root / "err", (),
                                            "C:\\Windows", lambda *a, **kw: process, native_image, reader)
                    reader.assert_not_called()
                    self.assertNotIn("applicationError", result)


class StandaloneDiagnosticTests(unittest.TestCase):
    def request(self, **changes):
        value = {"schema": 1, "architecture": "arm64", "label": "ui-smoke", "arguments": ["--ui-smoke-test"],
                 "exitCode": -1073740940, "originalPid": 321, "startedUTC": "2026-10-28T12:00:00+00:00",
                 "endedUTC": "2026-10-28T12:00:03+00:00", "executable": r"C:\Owned κόσμε\SpeakWindows.exe",
                 "expectedSHA256": "a" * 64, "powershell": r"C:\Owned\pwsh.exe", "powershellSHA256": "b" * 64,
                 "parentPid": 123, "deadlineTicks": 30000, "frequency": 1000}
        value.update(changes)
        return value

    def encode(self, value):
        return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")

    def api(self, **changes):
        values = dict(frequency=lambda: 1000, ticks=lambda: 10000, admitted=lambda request: True)
        values.update(changes)
        return types.SimpleNamespace(**values)

    def fixture(self):
        # Deliberately private paths, symbols and absolute PCs must never escape.
        return (b"C:\\private-canary\\secret.pdb\nJSTI_DIAG_READY\nJSTI_DIAG_FAULT 0xc0000374\n"
                b"JSTI_DIAG_IP 00000001`00000042\nJSTI_DIAG_MODULES\n"
                b"00000001`00000000 00000001`00001000 SpeakWindows (export symbols) C:\\private-canary\n"
                b"00000002`00000000 00000002`00001000 private_module (deferred)\n"
                b"JSTI_DIAG_STACK\n00 00000003`00000000 00000002`00000024 SpeakWindows!private_function+0xbad\n"
                b"01 00000003`00000080 00000000`00000000 private_module!private_function+0xfeed\nJSTI_DIAG_END\n")

    def operate(self, value=None, api=None, identity=None, runner=None):
        identity = identity or (lambda path, *args, **kwargs: (path, "same-snapshot"))
        runner = runner or (lambda *args, **kwargs: {"status": "complete", "cleanup": "clean", "exitCode": 0,
                                                   "output": self.fixture() if args[0][0] == NATIVE.CDB_LOCATION
                                                   else b'{"status":"unavailable"}'})
        return NATIVE.standalone_diagnostic(self.encode(value or self.request()), lambda: api or self.api(), identity, runner)

    def test_closed_request_refuses_unowned_or_arbitrary_operation_before_any_effect(self):
        mutations = [dict(extra="private-canary"), dict(schema=True), dict(originalPid=True), dict(parentPid=0),
                     dict(label="ui-smoke-test"), dict(arguments=["--help"]), dict(exitCode=0), dict(architecture="x64"),
                     dict(executable=r"\\server\SpeakWindows.exe"), dict(executable=r"C:\a\..\SpeakWindows.exe"),
                     dict(executable=r"C:\a\SpeakWindows.exe:stream"), dict(powershell=r"C:\a\cmd.exe"),
                     dict(expectedSHA256="X" * 64), dict(powershellSHA256="wrong"),
                     dict(startedUTC="2026-10-28T12:00:00"), dict(endedUTC="2026-10-28T12:00:31Z")]
        for changes in mutations:
            with self.subTest(changes=tuple(changes)):
                with self.assertRaises(ValueError):
                    NATIVE.diagnostic_request(self.encode(self.request(**changes)))
        for encoded in ("", "a" * 10925, "e30=", self.encode({"private-canary": "never"}),
                        base64.urlsafe_b64encode(b'{"schema":1,"schema":1}').decode().rstrip("=")):
            with self.assertRaises((ValueError, UnicodeError)):
                NATIVE.diagnostic_request(encoded)
        identity, runner = mock.Mock(), mock.Mock()
        result = self.operate(api=self.api(admitted=lambda _: False), identity=identity, runner=runner)
        self.assertEqual(result["status"], "invalid")
        identity.assert_not_called()
        runner.assert_not_called()

    def test_qpc_frequency_deadline_and_cleanup_reserve_refuse_before_launch(self):
        for api in (self.api(frequency=lambda: 999), self.api(ticks=lambda: 30000), self.api(ticks=lambda: -1)):
            with self.assertRaises(ValueError):
                NATIVE.DiagnosticBudget(self.request(), api)
        calls = []
        result = self.operate(api=self.api(ticks=lambda: 26000), runner=lambda *a, **k: calls.append(a))
        self.assertEqual(result["status"], "deadline")
        self.assertEqual(calls, [])

    def test_child_job_checks_only_defend_trusted_parent_and_exact_kill_flags(self):
        import ctypes
        for member, flags, parent, query_ok in ((1, 0x2000, 123, True), (0, 0x2000, 123, True),
                                                (1, 0x2800, 123, True), (1, 0x3000, 123, True),
                                                (1, 0x2000, 124, True), (1, 0x2000, 123, False)):
            def in_job(process, job, result):
                self.assertIsNone(job)
                result._obj.value = member
                return 1
            def info(job, kind, limits, size, returned):
                self.assertIsNone(job)
                self.assertEqual(kind, 9)
                limits._obj.basic.flags = flags
                returned._obj.value = size
                return int(query_ok)
            api = NATIVE.StandaloneWindows.__new__(NATIVE.StandaloneWindows)
            api.ctypes = ctypes
            api.api = types.SimpleNamespace(GetCurrentProcess=lambda: -1, IsProcessInJob=in_job,
                                            QueryInformationJobObject=info)
            with mock.patch.object(NATIVE.os, "getppid", return_value=parent):
                self.assertEqual(bool(api.admitted(self.request())), member == 1 and flags == 0x2000 and
                                 parent == 123 and query_ok)

    def test_parser_emits_only_unique_module_rvas_not_raw_paths_symbols_or_addresses(self):
        expected = {"status": "observed", "exceptionCode": "0xc0000374", "frames": [
            {"index": 0, "module": "app", "rva": "0x42"}, {"index": 1, "module": "unknown", "rva": "0x24"}]}
        self.assertEqual(NATIVE.project_debugger(self.fixture()), expected)
        self.assertEqual(NATIVE.project_debugger(self.fixture().replace(b"private-canary", "ιδιωτικό".encode())), expected)
        serialized = json.dumps(expected)
        for private in ("private", "function", "00000001", "00000002", "C:\\", "bad", "feed"):
            self.assertNotIn(private, serialized)
        for suffix in (b"", b"arbitrary target output\n"):
            self.assertEqual(NATIVE.project_debugger(b"JSTI_DIAG_READY\n" + suffix)["status"], "no-reproduction")
        self.assertEqual(NATIVE.project_debugger(b"JSTI_DIAG_READY\n", False)["status"], "unavailable")

    def test_parser_refuses_ambiguous_missing_malformed_spoofed_and_oversized_frames(self):
        original = self.fixture()
        variants = [original.replace(b"JSTI_DIAG_READY\n", b""), original + b"JSTI_DIAG_READY\n",
                    original.replace(b"JSTI_DIAG_END", b""), original.replace(b"c0000374", b"deadbeef"),
                    original.replace(b"JSTI_DIAG_STACK", b"JSTI_DIAG_MODULES"),
                    original.replace(b"00 00000003", b"05 00000003"),
                    original.replace(b"JSTI_DIAG_IP 00000001`00000042", b"JSTI_DIAG_IP 00000009`00000042"),
                    original.replace(b"JSTI_DIAG_STACK", b"00000001`00000000 00000001`00001000 ntdll\nJSTI_DIAG_STACK")]
        for data in variants:
            self.assertEqual(NATIVE.project_debugger(data)["status"], "invalid")
        for data in (b"x" * 65537, b"x" * 2049 + b"\n"):
            self.assertEqual(NATIVE.project_debugger(data)["status"], "truncated")

    def test_actual_python_projection_roundtrips_through_actual_powershell_closed_projector(self):
        host = shutil.which("pwsh")
        if host is None:
            self.skipTest("PowerShell unavailable: actual cross-language projection not executed")
        value = NATIVE.diagnostic_result("observed", "clean")
        value["debugger"] = NATIVE.project_debugger(self.fixture())
        # Definitions-only shared helper has no verifier or native preparation;
        # only its pure closed JSON projection is called.
        script = """
$ErrorActionPreference='Stop'
. $env:JSTI_PROJECTOR
$value=[Console]::In.ReadToEnd() | ConvertFrom-Json -Depth 8
ConvertTo-JstiDiagnosticProjection $value | ConvertTo-Json -Depth 8 -Compress
"""
        with tempfile.TemporaryDirectory() as directory:
            environment = {key: val for key, val in os.environ.items()
                           if key.upper() in {"PATH", "SYSTEMROOT", "WINDIR", "HOME"}}
            environment.update(TEMP=directory, TMP=directory, TMPDIR=directory,
                               JSTI_PROJECTOR=str(HERE / "FailureDiagnostics.ps1"))
            completed = subprocess.run([os.path.abspath(host), "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script],
                                       input=json.dumps(value).encode(), env=environment, cwd=directory,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15, check=False)
        self.assertEqual(completed.returncode, 0, "actual pure projector failed")
        self.assertEqual(completed.stderr, b"")
        self.assertLessEqual(len(completed.stdout), 8192)
        self.assertEqual(json.loads(completed.stdout), value)

    def test_actual_operation_keeps_fixed_argv_private_environment_once_and_owned_temp(self):
        calls, snapshots = [], []
        def identity(path, digest, maximum, budget, **kwargs):
            snapshots.append((path, digest, kwargs))
            return path, digest
        def runner(argv, environment, directory, budget, seconds, **kwargs):
            calls.append(argv)
            self.assertNotIn("OP_SERVICE_ACCOUNT_TOKEN", environment)
            self.assertNotIn("_NT_SYMBOL_PATH", environment)
            self.assertNotIn("ICU_DATA", environment)
            self.assertEqual(environment["TEMP"], directory)
            self.assertEqual(environment["USERPROFILE"], directory)
            self.assertTrue(pathlib.Path(directory).is_dir())
            if argv[0] != NATIVE.CDB_LOCATION:
                self.assertEqual(argv[:4], [self.request()["powershell"], "-NoLogo", "-NoProfile", "-NonInteractive"])
                return dict(status="complete", cleanup="clean", output=b'{"status":"unavailable"}', exitCode=0)
            self.assertLessEqual(seconds, 20)
            self.assertEqual(argv[1:7], ["-hd", "-G", "-sins", "-noshell", "-nosqm", "-netsyms:no"])
            self.assertEqual(argv[-2:], [self.request()["executable"], "--ui-smoke-test"])
            self.assertNotIn("-pd", argv)
            script = pathlib.Path(argv[argv.index("-cf") + 1])
            self.assertEqual(script.read_text(encoding="utf-8"), NATIVE.cdb_commands())
            self.assertEqual(list(pathlib.Path(argv[argv.index("-y") + 1]).iterdir()), [])
            self.assertEqual(script.parent, pathlib.Path(directory))
            return dict(status="complete", cleanup="clean", output=self.fixture(), exitCode=0)
        with mock.patch.dict(NATIVE.os.environ, {"OP_SERVICE_ACCOUNT_TOKEN": "private-canary", "_NT_SYMBOL_PATH": "https://private", "ICU_DATA": "private"}):
            result = self.operate(identity=identity, runner=runner)
        self.assertEqual(result["status"], "observed")
        self.assertEqual(result["cleanup"], "clean")
        self.assertEqual(len(calls), 2)
        self.assertEqual([item[0] for item in snapshots], [self.request()["executable"], self.request()["powershell"],
                                                        NATIVE.CDB_LOCATION, self.request()["executable"], self.request()["powershell"]])
        self.assertEqual(snapshots[2][1], NATIVE.CDB_SHA256)
        self.assertEqual(snapshots[2][2], {"version": [10, 0, 26100, 6584]})
        self.assertNotIn("private", json.dumps(result))
        self.assertNotIn("JSTI_DIAG", json.dumps(result))

    def test_event1000_uses_absolute_host_and_original_owned_identity_then_reprojects(self):
        value = self.request()
        event = {"time": "2026-10-28T12:00:02Z", "data": {"AppName": "SpeakWindows.exe", "AppPath": value["executable"],
                 "ProcessId": "321", "ModuleName": "private_module.dll", "ModuleVersion": "1.2.3.4",
                 "ExceptionCode": "c0000374", "FaultingOffset": "0x123"}}
        def runner(argv, environment, *args, **kwargs):
            if argv[0] == value["powershell"]:
                self.assertEqual(environment["JSTI_EVENT_START"], value["startedUTC"])
                self.assertEqual(environment["JSTI_EVENT_END"], value["endedUTC"])
                return dict(status="complete", cleanup="clean", exitCode=0,
                            output=json.dumps({"status": "ok", "events": [event]}).encode())
            return dict(status="complete", cleanup="clean", exitCode=0, output=b"JSTI_DIAG_READY\n")
        result = self.operate(runner=runner)
        self.assertEqual(result["applicationError"], {"status": "observed", "module": "unknown", "version": "1.2.3.4",
                                                     "exceptionCode": "0xc0000374", "faultOffset": "0x0000000000000123"})
        self.assertEqual(result["status"], "observed")
        self.assertNotIn("timeUTC", json.dumps(result))
        self.assertNotIn("private_module", json.dumps(result))
        event["data"]["ProcessId"] = "999"
        self.assertEqual(self.operate(runner=runner)["applicationError"], {"status": "no-match"})

    def test_identity_or_reader_cleanup_failure_never_launches_or_reports_observed(self):
        for location in (self.request()["executable"], self.request()["powershell"], NATIVE.CDB_LOCATION):
            launches = []
            def identity(path, *args, **kwargs):
                if path == location:
                    raise PermissionError("private-canary")
                return path, "same"
            def runner(*args, **kwargs):
                launches.append(args[0][0])
                return dict(status="complete", cleanup="clean", output=b'{"status":"unavailable"}', exitCode=0)
            result = self.operate(identity=identity, runner=runner)
            self.assertEqual(result["status"], "unavailable")
            self.assertEqual(result["cleanup"], "clean" if location == NATIVE.CDB_LOCATION else "not-started")
            self.assertNotIn(NATIVE.CDB_LOCATION, launches)
            self.assertNotIn("private", json.dumps(result))
        result = self.operate(runner=lambda *a, **k: dict(status="complete", cleanup="failed", output=self.fixture(), exitCode=0))
        self.assertEqual(result["cleanup"], "failed")
        self.assertNotEqual(result["status"], "observed")

    def test_event_work_consumes_same_deadline_and_image_replacement_refuses_cdb(self):
        now, calls = [10000], []
        def query(argv, *args, **kwargs):
            calls.append(argv[0])
            now[0] = 26000
            return dict(status="complete", cleanup="clean", output=b'{"status":"unavailable"}', exitCode=0)
        result = self.operate(api=self.api(ticks=lambda: now[0]), runner=query)
        self.assertEqual(result["status"], "deadline")
        self.assertEqual(calls, [self.request()["powershell"]])
        copies, calls = {}, []
        def identity(path, *args, **kwargs):
            copies[path] = copies.get(path, 0) + 1
            return path, copies[path]
        result = self.operate(identity=identity, runner=lambda argv, *a, **k: calls.append(argv[0]) or
                              dict(status="complete", cleanup="clean", output=b'{"status":"unavailable"}', exitCode=0))
        self.assertEqual(result["status"], "unavailable")
        self.assertEqual(calls, [self.request()["powershell"]])

    def test_collector_faults_and_truncation_are_finite_and_cannot_become_observed(self):
        for status in ("deadline", "truncated", "unavailable", "private-canary"):
            def runner(argv, *args, **kwargs):
                return dict(status=status if argv[0] == NATIVE.CDB_LOCATION else "complete", cleanup="clean",
                            output=b'{"status":"unavailable"}', exitCode=0)
            result = self.operate(runner=runner)
            self.assertEqual(result["status"], status if status in NATIVE.STANDALONE_STATUSES else "unavailable")
            self.assertNotIn("private", json.dumps(result))
        result = self.operate(runner=lambda *a, **k: (_ for _ in ()).throw(OSError("private-canary")))
        self.assertEqual(result["status"], "unavailable")
        self.assertNotIn("private", json.dumps(result))
        with tempfile.TemporaryDirectory() as directory:
            class FailedScratchCleanup:
                name = directory
                def __enter__(self):
                    return self.name
                def __exit__(self, *args):
                    raise OSError("private-canary")
            with mock.patch.object(NATIVE.tempfile, "TemporaryDirectory", return_value=FailedScratchCleanup()):
                result = self.operate()
            self.assertEqual(result["status"], "unavailable")
            self.assertEqual(result["cleanup"], "failed")
            self.assertNotIn("private", json.dumps(result))

    def test_refusal_facts_keep_original_parser_outcomes_for_each_reachable_guard(self):
        original = self.fixture()
        cases = [
            (original.replace(b"JSTI_DIAG_READY\n", b""), "ready-marker-count"),
            (original.replace(b"JSTI_DIAG_END", b""), "fault-boundary"),
            (original.replace(b"c0000374", b"deadbeef"), "fault-code-order"),
            (original.replace(b"JSTI_DIAG_STACK", b"JSTI_DIAG_MODULES"), "section-boundary"),
            (original.replace(b"JSTI_DIAG_IP 00000001`00000042\n", b""), "ip-count"),
            (original.replace(b"00000001`00001000 SpeakWindows", b"00000001`00000000 SpeakWindows"), "module-range"),
            (original.replace(b"00 00000003", b"05 00000003"), "stack-row-order"),
            (b"\n".join(line for line in original.split(b"\n") if not line.startswith((b"00 ", b"01 "))), "stack-row-count"),
            (original.replace(b"JSTI_DIAG_IP 00000001`00000042", b"JSTI_DIAG_IP 00000009`00000042"), "frame-range"),
        ]
        for data, reason in cases:
            with self.subTest(reason=reason):
                projected = NATIVE.project_debugger(data, completion_class="nonzero")
                facts = projected.pop("refusalFacts")
                self.assertEqual(projected, {"status": "invalid", "exceptionCode": None, "frames": []})
                self.assertEqual(facts["reason"], reason)
                self.assertEqual(facts["completionClass"], "nonzero")
                self.assertEqual(set(facts["counts"]), {"ready", "fault", "end", "modules", "stack", "ip", "moduleRanges", "stackRows"})
                self.assertTrue(all(type(count) is int and 0 <= count <= 17 for count in facts["counts"].values()))
        for data in (original, b"JSTI_DIAG_READY\n", b"x" * 65537, b"x" * 2049):
            self.assertNotIn("refusalFacts", NATIVE.project_debugger(data))

    def test_refusal_facts_saturate_counts_without_canaries_utf8_or_raw_fragments(self):
        data = b"JSTI_DIAG_READY\n" * 40 + b"JSTI_DIAG_FAULT 0xc0000374\n" * 35
        data += b"JSTI_DIAG_END\n" * 20 + b"JSTI_DIAG_MODULES\n" * 30 + b"JSTI_DIAG_STACK\n" * 18
        data += b"C:\\PRIVATE_CANARY !private_function 00000001`00000042 \xff " + "ιδιωτικό".encode("utf-8")
        facts = NATIVE.project_debugger(data)["refusalFacts"]
        self.assertEqual(facts["counts"], dict(ready=17, fault=17, end=17, modules=17, stack=17,
                                              ip=0, moduleRanges=0, stackRows=0))
        serialized = json.dumps(facts)
        for private in ("PRIVATE", "private_function", "00000001", "ιδιωτικό", "C:\\", "JSTI_DIAG"):
            self.assertNotIn(private, serialized)
        for value in (True, 0, None, "ZERO", "zero\n", "PRIVATE_CANARY"):
            with self.assertRaises(ValueError):
                NATIVE.project_debugger(data, completion_class=value)

    def test_actual_operation_attaches_completion_class_and_retires_late_refusal_facts(self):
        for code, expected in ((0, "zero"), (42, "nonzero"), (None, "unknown"), (True, "unknown")):
            def runner(argv, *args, **kwargs):
                return dict(status="complete", cleanup="clean", exitCode=code if argv[0] == NATIVE.CDB_LOCATION else 0,
                            output=b"PRIVATE_CANARY" if argv[0] == NATIVE.CDB_LOCATION else b'{"status":"unavailable"}')
            result = self.operate(runner=runner)
            self.assertEqual(result["debugger"]["refusalFacts"]["completionClass"], expected)
            self.assertNotIn("PRIVATE", json.dumps(result))
        for mode in ("cutoff", "scratch", "child-cleanup", "clock"):
            now = [10000]
            def ticks():
                if now[0] is None:
                    raise OSError("PRIVATE_CANARY")
                return now[0]
            with tempfile.TemporaryDirectory() as directory:
                class LateScratch:
                    name = directory
                    def __enter__(self):
                        return self.name
                    def __exit__(self, *args):
                        if mode == "scratch":
                            raise OSError("PRIVATE_CANARY")
                        now[0] = None if mode == "clock" else 28000
                def runner(argv, *args, **kwargs):
                    return dict(status="complete", cleanup="failed" if mode == "child-cleanup" else "clean",
                                exitCode=0, output=b"PRIVATE_CANARY" if argv[0] == NATIVE.CDB_LOCATION
                                else b'{"status":"unavailable"}')
                with mock.patch.object(NATIVE.tempfile, "TemporaryDirectory", return_value=LateScratch()):
                    result = self.operate(api=self.api(ticks=ticks), runner=runner)
                self.assertNotIn("refusalFacts", result["debugger"])
                self.assertNotIn("PRIVATE", json.dumps(result))

    def test_actual_refusal_facts_python_to_powershell_boundary_rejects_malicious_shapes(self):
        host = shutil.which("pwsh")
        if host is None:
            self.skipTest("PowerShell unavailable: actual refusal-facts boundary not executed")
        value = NATIVE.diagnostic_result("invalid", "clean")
        value["debugger"] = NATIVE.project_debugger(b"PRIVATE_CANARY\xff", completion_class="nonzero")
        values = [value]
        def changed(change):
            clone = json.loads(json.dumps(value))
            change(clone)
            values.append(clone)
        for key, item in (("reason", "PRIVATE_CANARY"), ("reason", "READY-MARKER-COUNT"),
                          ("completionClass", "zero\n"), ("completionClass", True), ("extra", "PRIVATE_CANARY")):
            changed(lambda clone, key=key, item=item: clone["debugger"]["refusalFacts"].update({key: item}))
        for count in (True, False, -1, 18, 1.5, "1", "PRIVATE_CANARY", "x" * 9000):
            changed(lambda clone, count=count: clone["debugger"]["refusalFacts"]["counts"].update(ready=count))
        for field in ("reason", "completionClass", "counts"):
            changed(lambda clone, field=field: clone["debugger"]["refusalFacts"].pop(field))
        changed(lambda clone: clone["debugger"]["refusalFacts"]["counts"].pop("ready"))
        changed(lambda clone: clone["debugger"]["refusalFacts"]["counts"].update(extra=0))
        changed(lambda clone: clone["debugger"]["refusalFacts"].update(Counts={}))
        changed(lambda clone: clone["debugger"].update(status="observed"))
        changed(lambda clone: clone.update(cleanup="failed"))
        changed(lambda clone: clone.update(status="observed"))
        changed(lambda clone: clone["debugger"].update(refusalFacts=None))
        changed(lambda clone: clone["debugger"].update(exceptionCode="0xc0000374"))
        changed(lambda clone: clone["debugger"].update(frames=[dict(index=0, module="app", rva="0x1")]))
        script = """
$ErrorActionPreference='Stop'
. $env:JSTI_PROJECTOR
$values=[Console]::In.ReadToEnd() | ConvertFrom-Json -Depth 8
foreach ($encodedValue in $values) {
    try {
        $value = $encodedValue | ConvertFrom-Json -Depth 8
        ConvertTo-JstiDiagnosticProjection $value | ConvertTo-Json -Depth 8 -Compress
    }
    catch { [Console]::WriteLine('refused') }
}
"""
        with tempfile.TemporaryDirectory() as directory:
            environment = {key: val for key, val in os.environ.items()
                           if key.upper() in {"PATH", "SYSTEMROOT", "WINDIR", "HOME"}}
            environment.update(TEMP=directory, TMP=directory, TMPDIR=directory,
                               JSTI_PROJECTOR=str(HERE / "FailureDiagnostics.ps1"))
            completed = subprocess.run([os.path.abspath(host), "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script],
                                       input=json.dumps([json.dumps(value) for value in values]).encode("utf-8"), env=environment, cwd=directory,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15, check=False)
        self.assertEqual(completed.returncode, 0, "actual pure refusal-facts projector failed")
        self.assertEqual(completed.stderr, b"")
        rows = completed.stdout.decode("utf-8").splitlines()
        expected = json.loads(json.dumps(value))
        expected["debugger"].pop("exceptionCode")  # Existing PS projection omits null optional codes.
        self.assertEqual(json.loads(rows[0]), expected)
        self.assertEqual(rows[1:], ["refused"] * (len(values) - 1))
        self.assertNotIn(b"PRIVATE", completed.stdout + completed.stderr)
        self.assertLessEqual(len(rows[0].encode("utf-8")), 8192)

    def test_completed_pre_ready_collector_classifies_exact_exit_values_without_replaying(self):
        cases = [(0, "zero"), (42, "otherNonzero"), (-2147483648, "otherNonzero"), (4294967295, "otherNonzero")]
        for code, label in ((0xC0000135, "dllNotFoundStatus"), (0xC000007B, "invalidImageFormatStatus"),
                            (0xC0000139, "entryPointNotFoundStatus")):
            cases.extend(((code, label), (code - (1 << 32), label)))
        for code, label in cases:
            for output in (b"", b"PRIVATE_OUTPUT_CANARY\xff"):
                with self.subTest(code=code, empty=not output):
                    calls = []
                    def runner(argv, environment, directory, budget, seconds, **kwargs):
                        calls.append(argv)
                        if argv[0] != NATIVE.CDB_LOCATION:
                            return dict(status="complete", cleanup="clean", exitCode=0, output=b'{"status":"unavailable"}')
                        self.assertEqual(argv[1:8], ["-hd", "-G", "-sins", "-noshell", "-nosqm", "-netsyms:no", "-cf"])
                        self.assertEqual(pathlib.Path(argv[8]).read_text(encoding="ascii"), NATIVE.cdb_commands())
                        self.assertEqual(argv[-2:], [self.request()["executable"], "--ui-smoke-test"])
                        self.assertEqual(seconds, 18)
                        return dict(status="complete", cleanup="clean", exitCode=code, output=output)
                    result = self.operate(runner=runner)
                    self.assertEqual([call[0] for call in calls], [self.request()["powershell"], NATIVE.CDB_LOCATION])
                    self.assertEqual((result["status"], result["cleanup"]), ("invalid", "clean"))
                    facts = result["debugger"]["refusalFacts"]
                    self.assertEqual(facts.pop("processFacts"), {"exitStatusClass": label,
                                                               "outputClass": "nonempty" if output else "empty"})
                    expected = NATIVE.project_debugger(output, code == 0, completion_class="zero" if code == 0 else "nonzero")
                    self.assertEqual(result["debugger"], expected)
                    self.assertNotIn("PRIVATE", json.dumps(result))

    def test_pre_ready_process_facts_omit_non_integer_or_out_of_range_status(self):
        for code in (None, True, False, 0.0, 3221225781.0, "3221225781", -(1 << 31) - 1, 1 << 32):
            with self.subTest(kind=type(code).__name__):
                def runner(argv, *args, **kwargs):
                    return dict(status="complete", cleanup="clean", exitCode=code,
                                output=b"PRIVATE_CANARY" if argv[0] == NATIVE.CDB_LOCATION else b'{"status":"unavailable"}')
                result = self.operate(runner=runner)
                self.assertEqual(result["status"], "invalid")
                self.assertNotIn("processFacts", result["debugger"]["refusalFacts"])
                self.assertNotIn("PRIVATE", json.dumps(result))

    def test_process_facts_are_absent_after_ready_or_incomplete_or_failed_collector(self):
        cases = [("complete", "clean", b"JSTI_DIAG_READY\n"),
                 ("complete", "clean", b"JSTI_DIAG_READY\nJSTI_DIAG_READY\n"),
                 ("complete", "clean", self.fixture().replace(b"JSTI_DIAG_END", b"")),
                 ("complete", "clean", b"x" * 65537), ("deadline", "clean", b""),
                 ("truncated", "clean", b""), ("complete", "failed", b"")]
        expected = ("no-reproduction", "invalid", "invalid", "truncated", "deadline", "truncated", "unavailable")
        for (status, cleanup, output), expected_status in zip(cases, expected):
            calls = []
            def runner(argv, *args, **kwargs):
                calls.append(argv[0])
                if argv[0] != NATIVE.CDB_LOCATION:
                    return dict(status="complete", cleanup="clean", exitCode=0, output=b'{"status":"unavailable"}')
                return dict(status=status, cleanup=cleanup, exitCode=0, output=output)
            result = self.operate(runner=runner)
            self.assertEqual(result["status"], expected_status)
            self.assertEqual(calls, [self.request()["powershell"], NATIVE.CDB_LOCATION])
            self.assertNotIn("processFacts", result["debugger"].get("refusalFacts", {}))

    def test_actual_pre_ready_process_facts_roundtrip_and_fail_closed_at_powershell_boundary(self):
        host = shutil.which("pwsh")
        if host is None:
            self.skipTest("PowerShell unavailable: actual process-facts boundary not executed")
        accepted = []
        for code in (0, 42, 0xC0000135, -1073741701, 0xC0000139):
            for output in (b"", b"PRIVATE_CANARY"):
                def runner(argv, *args, **kwargs):
                    return dict(status="complete", cleanup="clean", exitCode=code if argv[0] == NATIVE.CDB_LOCATION else 0,
                                output=output if argv[0] == NATIVE.CDB_LOCATION else b'{"status":"unavailable"}')
                accepted.append(self.operate(runner=runner))
        values = list(accepted)
        def changed(change):
            value = json.loads(json.dumps(accepted[-1]))
            change(value)
            values.append(value)
        for key in ("exitStatusClass", "outputClass"):
            for invalid in (None, True, False, 1, -1, 1.5, [], {}, "PRIVATE_CANARY", "nonempty\n", "ZERO"):
                changed(lambda v, key=key, invalid=invalid: v["debugger"]["refusalFacts"]["processFacts"].update({key: invalid}))
            changed(lambda v, key=key: v["debugger"]["refusalFacts"]["processFacts"].pop(key))
        for invalid in (None, True, [], "PRIVATE_CANARY"):
            changed(lambda v, invalid=invalid: v["debugger"]["refusalFacts"].update(processFacts=invalid))
        changed(lambda v: v["debugger"]["refusalFacts"]["processFacts"].update(schema=1))
        changed(lambda v: v["debugger"]["refusalFacts"]["processFacts"].update(OutputClass="nonempty"))
        changed(lambda v: v["debugger"]["refusalFacts"].update(ProcessFacts={}))
        changed(lambda v: v["debugger"]["refusalFacts"].update(completionClass="zero"))
        changed(lambda v: v["debugger"]["refusalFacts"]["processFacts"].update(exitStatusClass="zero"))
        changed(lambda v: v["debugger"]["refusalFacts"].update(reason="fault-boundary"))
        changed(lambda v: v["debugger"]["refusalFacts"]["counts"].update(ready=1))
        for field in ("fault", "end", "modules", "stack", "ip", "moduleRanges", "stackRows"):
            for count in (1, 17):
                def impossible_empty(value, field=field, count=count):
                    value["debugger"]["refusalFacts"]["processFacts"]["outputClass"] = "empty"
                    value["debugger"]["refusalFacts"]["counts"][field] = count
                changed(impossible_empty)
        changed(lambda v: v.update(schema=True))
        script = """
$ErrorActionPreference='Stop'
. $env:JSTI_PROJECTOR
foreach ($encoded in ([Console]::In.ReadToEnd() | ConvertFrom-Json -Depth 8)) {
    try { ConvertTo-JstiDiagnosticProjection ($encoded | ConvertFrom-Json -Depth 8) | ConvertTo-Json -Depth 8 -Compress }
    catch { [Console]::WriteLine('refused') }
}
"""
        with tempfile.TemporaryDirectory() as directory:
            environment = {key: val for key, val in os.environ.items()
                           if key.upper() in {"PATH", "SYSTEMROOT", "WINDIR", "HOME"}}
            environment.update(TEMP=directory, TMP=directory, TMPDIR=directory,
                               JSTI_PROJECTOR=str(HERE / "FailureDiagnostics.ps1"))
            completed = subprocess.run([os.path.abspath(host), "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script],
                                       input=json.dumps([json.dumps(v) for v in values]).encode("utf-8"), env=environment,
                                       cwd=directory, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15, check=False)
        self.assertEqual(completed.returncode, 0, "actual pure process-facts projection failed")
        self.assertEqual(completed.stderr, b"")
        rows = completed.stdout.decode("utf-8").splitlines()
        expected = json.loads(json.dumps(accepted))
        for value in expected:
            value["debugger"].pop("exceptionCode")
        self.assertEqual([json.loads(row) for row in rows[:len(accepted)]], expected)
        self.assertEqual(rows[len(accepted):], ["refused"] * (len(values) - len(accepted)))
        self.assertNotIn(b"PRIVATE", completed.stdout + completed.stderr)
        self.assertTrue(all(len(row.encode("utf-8")) <= 8192 for row in rows))

    def test_actual_identity_checks_hash_pe_alias_version_and_between_read_change(self):
        budget = types.SimpleNamespace(remaining=lambda: 20)
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory).resolve() / "SpeakWindows.exe"
            data = BUNDLE_TESTS.build_pe(["KERNEL32.dll"], machine=ARM64)
            path.write_bytes(data)
            digest = NATIVE.hashlib.sha256(data).hexdigest()
            self.assertEqual(NATIVE.diagnostic_identity(str(path), digest, 1 << 20, budget)[2], len(data))
            with self.assertRaises(ValueError):
                NATIVE.diagnostic_identity(str(path), "a" * 64, 1 << 20, budget)
            path.write_bytes(BUNDLE_TESTS.build_pe(["KERNEL32.dll"], machine=AMD64))
            with self.assertRaises(ValueError):
                NATIVE.diagnostic_identity(str(path), NATIVE.sha256_file(path), 1 << 20, budget)
            path.write_bytes(data)
            alias = pathlib.Path(directory).resolve() / "alias.exe"
            alias.symlink_to(path)
            with self.assertRaises(ValueError):
                NATIVE.diagnostic_identity(str(alias), digest, 1 << 20, budget)
            def changed(_):
                path.write_bytes(data + b"changed")
                return NATIVE.CDB_VERSION
            with mock.patch.object(NATIVE, "numeric_file_version", side_effect=changed):
                with self.assertRaises(ValueError):
                    NATIVE.diagnostic_identity(str(path), digest, 1 << 20, budget, version=NATIVE.CDB_VERSION)

    def test_peek_adapter_reads_only_available_bytes_and_maps_closed_not_idle(self):
        import ctypes
        stream = types.SimpleNamespace(fileno=lambda: 7)
        reader = NATIVE.DiagnosticPipeReader.__new__(NATIVE.DiagnosticPipeReader)
        reader.ctypes, reader.handle = ctypes, lambda fd: fd + 10
        def peek(handle, data, size, read, available, left):
            self.assertEqual(handle, 17)
            available._obj.value = 9
            return 1
        reader.peek = peek
        with mock.patch.object(NATIVE.os, "read", return_value=b"available") as read:
            self.assertEqual(reader.read(stream), (b"available", False))
            read.assert_called_once_with(7, 9)
        with mock.patch.object(NATIVE.os, "read", return_value=b"ava") as read:
            self.assertEqual(reader.read(stream, 3), (b"ava", False))
            read.assert_called_once_with(7, 3)
        with mock.patch.object(NATIVE.os, "read") as read:
            with self.assertRaises(OverflowError):
                reader.read(stream, 0)
            read.assert_not_called()
        reader.peek = lambda *args: 0
        with mock.patch.object(ctypes, "get_last_error", return_value=109, create=True):
            self.assertEqual(reader.read(stream), (b"", True))
        with mock.patch.object(ctypes, "get_last_error", return_value=5, create=True):
            with self.assertRaises(OSError):
                reader.read(stream)

    def test_actual_bounded_runner_caps_splits_drains_both_and_preserves_child_cleanup(self):
        class Process:
            def __init__(self, running=False, fail_wait=False):
                self.stdout, self.stderr = io.BytesIO(), io.BytesIO()
                self.returncode, self.fail_wait, self.killed = (None if running else 0), fail_wait, False
            def poll(self):
                return self.returncode
            def kill(self):
                self.killed, self.returncode = True, -9
            def wait(self, timeout):
                if self.fail_wait or self.returncode is None:
                    raise subprocess.TimeoutExpired("fixed-owned-child", timeout)
                return self.returncode
        budget = types.SimpleNamespace(remaining=lambda: 10)
        row = b"a" * 1023 + b"\n"
        for data, error, expected in ((b"a" * 2048 + b"\n", b"stderr\n", "complete"),
                                      (b"a" * 2049, b"stderr\n", "truncated"),
                                      (row * 65, b"stderr\n", "truncated"),
                                      (row * 33, row * 33, "truncated"),
                                      (row * 32, row * 32, "complete")):
            process = Process()
            remaining, consumed = {process.stdout: data, process.stderr: error}, []
            def read(stream, maximum):
                if not remaining[stream]:
                    return b"", True
                if maximum == 0:
                    raise OverflowError()
                chunk = remaining[stream][:min(1024, maximum)]
                remaining[stream] = remaining[stream][len(chunk):]
                consumed.append(len(chunk))
                return chunk, False
            def launch(argv, **options):
                self.assertEqual(options["creationflags"], 0)
                self.assertEqual(options["executable"], argv[0])
                self.assertTrue(options["close_fds"])
                self.assertEqual(options["bufsize"], 0)
                return process
            result = NATIVE.bounded_diagnostic_process(["fixed-owned-cdb"], {}, "owned", budget, 5,
                     launch=launch, pipe_factory=lambda: types.SimpleNamespace(read=read))
            self.assertEqual(result["status"], expected)
            self.assertLessEqual(len(result["output"]), 65536)
            self.assertLessEqual(sum(consumed), 65536)
            if len(data) + len(error) >= 65536 and expected == "complete":
                self.assertEqual(sum(consumed), 65536)
            if len(data) + len(error) > 65536 and not any(len(line) > 2048 for line in data.splitlines()):
                self.assertEqual(sum(consumed), 65536)
                self.assertTrue(any(remaining.values()))
            self.assertEqual(result["cleanup"], "clean")
            self.assertTrue(process.stdout.closed and process.stderr.closed)
        for fail_wait in (False, True):
            process = Process(running=True, fail_wait=fail_wait)
            result = NATIVE.bounded_diagnostic_process(["fixed"], {}, "owned", budget, .03,
                     launch=lambda *a, **k: process,
                     pipe_factory=lambda: types.SimpleNamespace(read=lambda *_: (b"", False)),
                     clock=Clock(.01), sleep=lambda _: None)
            self.assertEqual(result["status"], "deadline")
            self.assertTrue(process.killed)
            self.assertEqual(result["cleanup"], "failed" if fail_wait else "clean")
        # Child exit is not pipe EOF / descendant cleanup. The outer PS job is
        # still authoritative even when this one exact child already exited.
        process = Process()
        result = NATIVE.bounded_diagnostic_process(["fixed"], {}, "owned", budget, .03,
                 launch=lambda *a, **k: process,
                 pipe_factory=lambda: types.SimpleNamespace(read=lambda *_: (b"", False)),
                 clock=Clock(.01), sleep=lambda _: None)
        self.assertEqual(result["status"], "deadline")
        self.assertFalse(process.killed)
        self.assertTrue(process.stdout.closed and process.stderr.closed)

    def test_cli_invalid_input_is_one_bounded_closed_json_without_private_error(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            NATIVE.dispatch_main(["standalone-diagnostic", "--request", "private-canary"])
        self.assertEqual(len(output.getvalue().splitlines()), 1)
        result = json.loads(output.getvalue())
        self.assertEqual(set(result), {"schema", "status", "cleanup", "applicationError", "debugger"})
        self.assertIn(result["status"], NATIVE.STANDALONE_STATUSES)
        self.assertLess(len(output.getvalue()), 8192)
        self.assertNotIn("private", output.getvalue())


class DiagnosticRuntimeClosureTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="owned-diagnostic-runtime-")
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        self.source, self.config = self.root / "source", self.root / "config"
        self.source.mkdir(); self.config.mkdir()
        self.parent = r"C:\Users\Owned\AppData\Local\Programs\Swift\Runtimes\6.2.3\usr\bin"
        policy = json.loads((HERE / "runtime-policy.json").read_text(encoding="utf-8"))
        lock = json.loads((HERE / "swift-runtime-lock-arm64.json").read_text(encoding="utf-8"))
        self.names = policy["swiftRuntimeModules"][:14]
        self.data = BUNDLE_TESTS.build_pe(["KERNEL32.dll"], machine=ARM64, dll=True)
        self.rows = []
        for name in self.names:
            (self.source / name).write_bytes(self.data)
            row = next(row for row in lock["files"] if row["path"] == name)
            row.update(bytes=len(self.data), sha256=NATIVE.hashlib.sha256(self.data).hexdigest())
            self.rows.append(dict(name=name, path=self.parent + "\\" + name, bytes=row["bytes"], sha256=row["sha256"]))
        # Retain actual canonical installer provenance/policy; only the14 owned
        # synthetic PE payload rows replace real runtime bytes for this fixture.
        (self.config / "runtime-policy.json").write_text(json.dumps(policy), encoding="utf-8")
        (self.config / "swift-runtime-lock-arm64.json").write_text(json.dumps(lock), encoding="utf-8")
        self.real_path = pathlib.Path

    def mapped_path(self, value):
        if isinstance(value, str) and value == self.parent:
            return self.source
        if isinstance(value, str) and value.startswith(self.parent + "\\"):
            return self.source / value[len(self.parent) + 1:]
        return self.real_path(value)

    def operate(self, rows=None, runner=None, api=None):
        fixture = StandaloneDiagnosticTests()
        with mock.patch.object(NATIVE, "HERE", self.config), \
                mock.patch.object(NATIVE.pathlib, "Path", side_effect=self.mapped_path):
            return fixture.operate(value=fixture.request(runtimeModules=self.rows if rows is None else rows),
                                   runner=runner, api=api)

    def test_actual_canonical_layout_uses_existing_arm_installer_pin_and_policy(self):
        version, layout = NATIVE.diagnostic_runtime_layout()
        policy = json.loads((HERE / "runtime-policy.json").read_text(encoding="utf-8"))
        lock = json.loads((HERE / "swift-runtime-lock-arm64.json").read_text(encoding="utf-8"))
        self.assertEqual(version, NATIVE.windows_targets.swift_runtime_installer("arm64")[0])
        self.assertEqual(set(layout), set(policy["swiftRuntimeModules"]))
        self.assertEqual(layout, {row["path"]: row for row in lock["files"] if row["path"] in layout})
        source = self.config / "swift-runtime-lock-arm64.json"
        value = json.loads(source.read_text(encoding="utf-8")); value["installer"]["sha256"] = "0" * 64
        source.write_text(json.dumps(value), encoding="utf-8")
        with mock.patch.object(NATIVE, "HERE", self.config), self.assertRaises(ValueError):
            NATIVE.diagnostic_runtime_layout()

    def test_actual_operation_copies_only_verified_fourteen_and_changes_only_debugger_path(self):
        (self.source / "PRIVATE_UNOBSERVED_CANARY.dll").write_bytes(b"never admitted")
        calls, private_paths = [], []
        def runner(argv, environment, directory, budget, seconds, **kwargs):
            calls.append(argv[0])
            system = NATIVE.ntpath.join(environment.get("SystemRoot", r"C:\Windows"), "System32")
            if argv[0] != NATIVE.CDB_LOCATION:
                self.assertEqual(environment["PATH"], system)
                return dict(status="complete", cleanup="clean", exitCode=0, output=b'{"status":"unavailable"}')
            private = self.real_path(directory) / "runtime"; private_paths.append(private)
            self.assertEqual(environment["PATH"], system + ";" + str(private))
            self.assertNotIn(self.parent, environment["PATH"])
            self.assertNotIn("PRIVATE_INHERITED", json.dumps(environment))
            self.assertEqual(set(p.name for p in private.iterdir()), set(self.names))
            for path in private.iterdir():
                self.assertEqual(path.read_bytes(), self.data)
            self.assertEqual(argv[1:8], ["-hd", "-G", "-sins", "-noshell", "-nosqm", "-netsyms:no", "-cf"])
            self.assertEqual(self.real_path(argv[8]).read_text(encoding="ascii"), NATIVE.cdb_commands())
            self.assertEqual(argv[-2:], [StandaloneDiagnosticTests().request()["executable"], "--ui-smoke-test"])
            self.assertEqual(seconds, 18)
            return dict(status="complete", cleanup="clean", exitCode=0xC0000135, output=b"")
        with mock.patch.dict(os.environ, {"PATH": "PRIVATE_INHERITED", "PROVIDER_TOKEN": "PRIVATE_INHERITED"}):
            result = self.operate(runner=runner)
        self.assertEqual(calls, [StandaloneDiagnosticTests().request()["powershell"], NATIVE.CDB_LOCATION])
        self.assertEqual((result["status"], result["cleanup"]), ("invalid", "clean"))
        self.assertTrue(private_paths)
        self.assertFalse(private_paths[0].exists())
        self.assertNotIn(self.parent, json.dumps(result))
        self.assertNotIn("PRIVATE", json.dumps(result))

    def test_supplied_malformed_runtime_context_never_downgrades_to_legacy_or_launches(self):
        values = [None, [], self.rows[:13], self.rows + self.rows[:1], True, "PRIVATE_CANARY"]
        def change(index, **changes):
            rows = json.loads(json.dumps(self.rows)); rows[index].update(changes); return rows
        values.extend(change(0, **{key: value}) for key, value in (("bytes", True), ("bytes", 0),
            ("bytes", 67108865), ("bytes", 1.5), ("sha256", "PRIVATE_CANARY"), ("path", r"\\server\a.dll"),
            ("path", self.parent + r"\..\a.dll"), ("path", self.parent + ';x\\' + self.names[0]),
            ("name", "../a.dll"), ("extra", "PRIVATE_CANARY")))
        values.append(change(1, name=self.rows[0]["name"], path=self.rows[0]["path"]))
        values.append(change(1, name=self.rows[0]["name"].upper(), path=self.parent + "\\" + self.rows[0]["name"].upper()))
        values.append(change(0, path=self.parent.replace("Owned", "Other") + "\\" + self.names[0]))
        too_large = json.loads(json.dumps(self.rows))
        for row in too_large: row["bytes"] = 5 << 20
        values.append(too_large)
        for rows in values:
            with self.subTest(kind=type(rows).__name__):
                runner = mock.Mock(side_effect=AssertionError("no collector"))
                result = self.operate(rows=rows, runner=runner) if rows is not None else NATIVE.standalone_diagnostic(
                    StandaloneDiagnosticTests().encode(StandaloneDiagnosticTests().request(runtimeModules=None)), runner=runner)
                runner.assert_not_called()
                self.assertEqual(result["status"], "unavailable")
                self.assertNotIn("PRIVATE", json.dumps(result))

    def test_pinned_missing_foreign_alias_and_changed_sources_refuse_before_cdb(self):
        for mode in ("missing", "size", "hash", "foreign", "not-dll", "file-alias", "directory-alias", "changed"):
            with self.subTest(mode=mode):
                first = self.source / self.names[0]; first.write_bytes(self.data)
                calls = []
                def runner(argv, *args, **kwargs):
                    calls.append(argv[0])
                    self.assertNotEqual(argv[0], NATIVE.CDB_LOCATION)
                    return dict(status="complete", cleanup="clean", exitCode=0, output=b'{"status":"unavailable"}')
                if mode == "missing": first.unlink()
                if mode == "size": first.write_bytes(self.data + b"x")
                if mode == "hash": first.write_bytes(self.data[:-1] + bytes([self.data[-1] ^ 1]))
                if mode in ("foreign", "not-dll"):
                    data = BUNDLE_TESTS.build_pe(["KERNEL32.dll"], machine=AMD64 if mode == "foreign" else ARM64,
                                                dll=mode == "foreign")
                    first.write_bytes(data)
                    lock = json.loads((self.config / "swift-runtime-lock-arm64.json").read_text(encoding="utf-8"))
                    pinned = next(row for row in lock["files"] if row["path"] == self.names[0])
                    pinned.update(bytes=len(data), sha256=NATIVE.hashlib.sha256(data).hexdigest())
                    self.rows[0].update(bytes=len(data), sha256=pinned["sha256"])
                    (self.config / "swift-runtime-lock-arm64.json").write_text(json.dumps(lock), encoding="utf-8")
                if mode == "file-alias":
                    first.unlink(); first.symlink_to(self.source / self.names[1])
                source = self.source
                if mode == "directory-alias":
                    moved = source.with_name("source-original"); source.rename(moved); source.symlink_to(moved, target_is_directory=True)
                real_image = NATIVE.windows_pe.PEImage
                def changed_image(*args, **kwargs):
                    image = real_image(*args, **kwargs)
                    if mode == "changed" and not getattr(changed_image, "done", False):
                        changed_image.done = True; first.write_bytes(self.data + b"changed")
                    return image
                with mock.patch.object(NATIVE.windows_pe, "PEImage", side_effect=changed_image):
                    result = self.operate(runner=runner)
                self.assertEqual(calls, [StandaloneDiagnosticTests().request()["powershell"]])
                self.assertEqual(result["status"], "unavailable")
                self.assertNotIn(self.parent, json.dumps(result))
                if mode == "directory-alias": source.unlink(); moved.rename(source)
                if first.is_symlink(): first.unlink()
                first.write_bytes(self.data)
                lock = json.loads((self.config / "swift-runtime-lock-arm64.json").read_text(encoding="utf-8"))
                pinned = next(row for row in lock["files"] if row["path"] == self.names[0])
                pinned.update(bytes=len(self.data), sha256=NATIVE.hashlib.sha256(self.data).hexdigest())
                self.rows[0].update(bytes=len(self.data), sha256=pinned["sha256"])
                (self.config / "swift-runtime-lock-arm64.json").write_text(json.dumps(lock), encoding="utf-8")

    def test_copy_recheck_private_mutation_exclusive_destination_and_budget_refuse(self):
        for mode in ("copy-mutation", "extra-copy", "deadline", "preexisting"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                calls = [0]
                def remaining():
                    calls[0] += 1
                    return 2 if mode == "deadline" and calls[0] >= 3 else 20
                budget = types.SimpleNamespace(remaining=remaining)
                real_bytes = NATIVE.diagnostic_runtime_bytes
                def tampered(path, row, budget):
                    if mode == "copy-mutation" and path.parent.name == "runtime":
                        path.write_bytes(b"x" * row["bytes"])
                    if mode == "extra-copy" and path.parent.name == "runtime":
                        (path.parent / "PRIVATE_UNOBSERVED_CANARY.dll").write_bytes(self.data)
                    return real_bytes(path, row, budget)
                if mode == "preexisting": (self.real_path(directory) / "runtime").mkdir()
                with mock.patch.object(NATIVE, "HERE", self.config), \
                        mock.patch.object(NATIVE.pathlib, "Path", side_effect=self.mapped_path), \
                        mock.patch.object(NATIVE, "diagnostic_runtime_bytes", side_effect=tampered), \
                        self.assertRaises((ValueError, TimeoutError, FileExistsError)):
                    NATIVE.prepare_diagnostic_runtime(self.rows, directory, budget)


    def test_actual_powershell_closed_runtime_projection_refuses_unknown_and_partial_fields(self):
        host = shutil.which("pwsh")
        if host is None:
            self.skipTest("PowerShell unavailable: actual runtime projection not executed")
        values = [self.rows]
        for kind in ("partial", "null", "bool", "unknown", "case", "duplicate", "mixed", "range", "hash"):
            rows = json.loads(json.dumps(self.rows))
            if kind == "partial": rows.pop()
            if kind == "null": rows = None
            if kind == "bool": rows[0]["bytes"] = True
            if kind == "unknown": rows[0]["private"] = "PRIVATE_CANARY"
            if kind == "case": rows[0]["Name"] = rows[0].pop("name")
            if kind == "duplicate": rows[1] = rows[0]
            if kind == "mixed": rows[0]["path"] = rows[0]["path"].replace("Owned", "Other")
            if kind == "range": rows[0]["bytes"] = 67108865
            if kind == "hash": rows[0]["sha256"] = "PRIVATE_CANARY"
            values.append(rows)
        script = r'''
$ErrorActionPreference='Stop'
. $env:JSTI_PROJECTOR
foreach ($encoded in ([Console]::In.ReadToEnd() | ConvertFrom-Json -Depth 8)) {
    try { ConvertTo-JstiDiagnosticRuntimeModules ($encoded | ConvertFrom-Json -Depth 8) | ConvertTo-Json -Depth 4 -Compress }
    catch { [Console]::WriteLine('refused') }
}
'''
        environment = dict(os.environ, JSTI_PROJECTOR=str(HERE / "FailureDiagnostics.ps1"))
        completed = subprocess.run([host, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script],
            input=json.dumps([json.dumps(value) for value in values]).encode("utf-8"), cwd=self.root, env=environment,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15, check=False)
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(completed.stderr, b"")
        lines = completed.stdout.decode("utf-8").splitlines()
        self.assertEqual(json.loads(lines[0]), self.rows)
        self.assertEqual(lines[1:], ["refused"] * (len(values) - 1))
        self.assertNotIn(b"PRIVATE", completed.stdout)

    def test_actual_native_adapter_and_standalone_request_preserve_observations_without_launch(self):
        host = shutil.which("pwsh")
        if host is None:
            self.skipTest("PowerShell unavailable: actual runtime request not executed")
        script = r'''
$ErrorActionPreference='Stop'
. $env:JSTI_PROJECTOR
$workspace=(Get-Location).Path; $systemRoot='C:\Windows'; $isolatedPath='C:\Windows\System32'
$script:captured=$null; $script:bootstrapCalls=0
$identity=(Get-Item Function:Get-JstiDiagnosticIdentity).ScriptBlock
$adapter=(Get-Item Function:New-JstiDiagnosticAdapter).ScriptBlock
$bootstrap=(Get-Item Function:Invoke-JstiDiagnosticBootstrap).ScriptBlock
try {
    Set-Item Function:Get-JstiDiagnosticIdentity { param($path,$names) return @{Path=$path;Hash=('0'*64)} }
    Set-Item Function:New-JstiDiagnosticAdapter {
        param($Frequency,$State) $script:ownedState=$State; return @{}
    }
    Set-Item Function:Invoke-JstiDiagnosticBootstrap {
        param($Adapter,$Request,$DeadlineTicks,$Frequency)
        $script:bootstrapCalls++
        $encoded=$Request.Arguments[-1].Replace('-','+').Replace('_','/')
        $encoded += '=' * ((4 - $encoded.Length % 4) % 4)
        $bytes=[Convert]::FromBase64String($encoded)
        if ($bytes.Length -gt 8192) { throw 'PRIVATE_CANARY' }
        $script:captured=[Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -Depth 8
        $response=[Text.Encoding]::UTF8.GetBytes('{"schema":1,"status":"unavailable","cleanup":"clean","applicationError":{"status":"unavailable"},"debugger":{"status":"unavailable","frames":[]}}')
        $script:ownedState.Output.Write($response,0,$response.Length)
        return @{status='finished';cleanup='complete';resumed=$true;streamBytes=$response.Length}
    }
    $rows=[Console]::In.ReadToEnd() | ConvertFrom-Json -Depth 8
    $frequency=[Diagnostics.Stopwatch]::Frequency
    $deadline=[Diagnostics.Stopwatch]::GetTimestamp()+30*$frequency
    $moment=[DateTime]::UtcNow.ToString('o')
    $modules=@($rows | ForEach-Object { @{name=$_.name;path=$_.path;bytes=$_.bytes;sha256=$_.sha256;dll=$true;native=$true;architecture='arm64'} })
    $run=@{label='ui-smoke-test';arguments=@('--ui-smoke-test');timedOut=$false;processMachine='arm64';nativeMachine='arm64';
        exitCode=3221226356L;failures=@('owned abnormal exit');modulesOutsideSystemRoot=$modules;
        executable=@{name='SpeakWindows.exe';path='C:\Owned\SpeakWindows.exe';sha256=('0'*64);architecture='arm64';native=$true;dll=$false};
        diagnosticOwnerContext=@{schema=1;originalPid=314;startedUTC=$moment;endedUTC=$moment;deadlineTicks=$deadline;frequency=$frequency;exitCode=-1073740940}}
    $before=$run | ConvertTo-Json -Depth 12 -Compress
    $setup=@{Host=@{Path='C:\Owned\pwsh.exe';Hash=('0'*64)};Python=@{Path='C:\Owned\python.exe';Hash=('0'*64)}}
    $result=Invoke-JstiNativeFailureDiagnostic $setup $run 'C:\Owned\SpeakWindows.exe' ('0'*64) $deadline $frequency
    @{request=$script:captured;result=$result;calls=$script:bootstrapCalls;unchanged=(($run|ConvertTo-Json -Depth 12 -Compress)-ceq$before)} |
        ConvertTo-Json -Depth 12 -Compress
} finally {
    Set-Item Function:Get-JstiDiagnosticIdentity $identity
    Set-Item Function:New-JstiDiagnosticAdapter $adapter
    Set-Item Function:Invoke-JstiDiagnosticBootstrap $bootstrap
}
'''
        environment = dict(os.environ, JSTI_PROJECTOR=str(HERE / "FailureDiagnostics.ps1"))
        completed = subprocess.run([host, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script],
            input=json.dumps(self.rows).encode("utf-8"), cwd=self.root, env=environment,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15, check=False)
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(completed.stderr, b"")
        value = json.loads(completed.stdout)
        self.assertEqual(value["calls"], 1)
        self.assertTrue(value["unchanged"])
        self.assertEqual(value["request"]["runtimeModules"], self.rows)
        self.assertEqual(set(value["request"]), NATIVE.STANDALONE_KEYS | {"runtimeModules"})
        self.assertEqual(value["result"]["status"], "unavailable")
        self.assertTrue(value["result"]["originalFailurePreserved"])
        NATIVE.diagnostic_request(StandaloneDiagnosticTests().encode(value["request"]))
        self.assertEqual(list(self.root.glob("failure-diagnostic-*/runtime")), [])
        self.assertNotIn(b"PRIVATE", completed.stdout)



    def test_reparse_attribute_and_noncanonical_version_or_location_refuse(self):
        alias = types.SimpleNamespace(parents=(), lstat=lambda: types.SimpleNamespace(st_file_attributes=0x400))
        with self.assertRaises(ValueError):
            NATIVE.diagnostic_runtime_stamp(alias)
        for parent in (self.parent.replace("6.2.3", "6.2.4"), r"C:\Untrusted\Swift\Runtimes\6.2.3\usr\bin"):
            rows = [dict(row, path=parent + "\\" + row["name"]) for row in self.rows]
            with tempfile.TemporaryDirectory() as directory, mock.patch.object(NATIVE, "HERE", self.config), \
                    self.assertRaises(ValueError):
                NATIVE.prepare_diagnostic_runtime(rows, directory, types.SimpleNamespace(remaining=lambda: 20))
            self.assertFalse((self.real_path(directory) / "runtime").exists())


    def test_actual_copy_rechecks_original_minimum_start_window_before_cdb(self):
        for ended_ticks in (24000, 27000, 23000):
            with self.subTest(remaining=(30000 - ended_ticks) / 1000):
                now, calls, private_paths = [10000], [], []
                request = StandaloneDiagnosticTests().request(runtimeModules=self.rows)
                before = json.loads(json.dumps(request))
                original_prepare = NATIVE.prepare_diagnostic_runtime
                def consumed_copy(*args):
                    runtime = original_prepare(*args)
                    private_paths.append(self.real_path(runtime))
                    now[0] = ended_ticks
                    return runtime
                def runner(argv, environment, directory, budget, seconds, **kwargs):
                    calls.append(argv[0])
                    if argv[0] == NATIVE.CDB_LOCATION:
                        self.assertEqual(seconds, 5)
                        return dict(status="complete", cleanup="clean", exitCode=0, output=b"JSTI_DIAG_READY\n")
                    return dict(status="complete", cleanup="clean", exitCode=0, output=b'{"status":"unavailable"}')
                with mock.patch.object(NATIVE, "HERE", self.config), \
                        mock.patch.object(NATIVE.pathlib, "Path", side_effect=self.mapped_path), \
                        mock.patch.object(NATIVE, "prepare_diagnostic_runtime", side_effect=consumed_copy):
                    result = StandaloneDiagnosticTests().operate(value=request,
                        api=StandaloneDiagnosticTests().api(ticks=lambda: now[0]), runner=runner)
                self.assertEqual(request, before)
                self.assertEqual(request["exitCode"], -1073740940)
                self.assertEqual(result["cleanup"], "clean")
                self.assertTrue(private_paths)
                self.assertTrue(all(not path.exists() for path in private_paths))
                expected = [request["powershell"]]
                if ended_ticks == 23000:
                    expected.append(NATIVE.CDB_LOCATION)
                    self.assertEqual(result["status"], "no-reproduction")
                else:
                    self.assertEqual(result["status"], "deadline")
                    self.assertEqual(result["debugger"]["status"], "deadline")
                self.assertEqual(calls, expected)


class DiagnosticBootstrapTests(unittest.TestCase):
    def test_actual_powershell_ownership_controller_with_pure_fake_adapter(self):
        host = shutil.which("pwsh")
        if host is None:
            self.skipTest("PowerShell unavailable: actual bootstrap fake checks not executed")
        # No native adapter, Add-Type, debugger or target is reachable in this
        # explicit inert import. Keep the fixture's environment and temp owned.
        with tempfile.TemporaryDirectory() as directory:
            environment = {key: value for key, value in os.environ.items()
                           if key.upper() in {"PATH", "SYSTEMROOT", "WINDIR", "HOME"}}
            environment.update(TEMP=directory, TMP=directory, TMPDIR=directory)
            completed = subprocess.run([
                os.path.abspath(host), "-NoLogo", "-NoProfile", "-NonInteractive", "-File",
                str(HERE / "test-failure-diagnostic-bootstrap.ps1")],
                cwd=directory, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                timeout=30, check=False)
        self.assertEqual(completed.returncode, 0, "actual PowerShell bootstrap fake checks failed")
        self.assertEqual(completed.stdout.strip(), b"Diagnostic bootstrap pure-fake checks passed.")
        self.assertEqual(completed.stderr, b"")


class CommandLineTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        self.evidence = self.root / "evidence.json"

    def test_image_evidence_accumulates_and_keeps_its_architecture(self):
        first, second = self.root / "a.exe", self.root / "b.dll"
        first.write_bytes(BUNDLE_TESTS.build_pe(machine=ARM64))
        second.write_bytes(BUNDLE_TESTS.build_pe(machine=ARM64, dll=True))
        with contextlib.redirect_stdout(io.StringIO()) as output:
            NATIVE.main(["--architecture", "arm64", "--evidence", str(self.evidence), "images", str(first)])
            NATIVE.main(["--architecture", "arm64", "--evidence", str(self.evidence), "images", str(second)])
        self.assertEqual(output.getvalue().splitlines(), ["1 native arm64 images"] * 2)
        evidence = json.loads(self.evidence.read_text(encoding="utf-8"))
        self.assertEqual([record["name"] for record in evidence["images"]], ["a.exe", "b.dll"])
        with self.assertRaisesRegex(NATIVE.ExecutionError, "records arm64, not x64"):
            NATIVE.main(["--architecture", "x64", "--evidence", str(self.evidence), "images", str(first)])

    def test_failures_still_write_evidence(self):
        foreign = self.root / "x64.exe"
        foreign.write_bytes(BUNDLE_TESTS.build_pe())
        with self.assertRaises(NATIVE.ExecutionError):
            NATIVE.main(["--architecture", "arm64", "--evidence", str(self.evidence), "images", str(foreign)])
        self.assertEqual(json.loads(self.evidence.read_text(encoding="utf-8"))["images"], [])

    def test_program_arguments_after_the_separator_are_passed_unchanged(self):
        args = NATIVE.parse_arguments([
            "--architecture", "arm64", "--evidence", "e.json", "run", "--label", "local", "--timeout", "480",
            "--stdout", "o.log", "--stderr", "e.log", "--expect-output", "Local transcription self-test passed", "--",
            "C:\\app\\SpeakWindows.exe", "--local-transcription-self-test", "C:\\a b\\jfk.wav", "--expect",
            "ask not what your country can do for you"])
        self.assertEqual(args.arguments, ["C:\\app\\SpeakWindows.exe", "--local-transcription-self-test",
                                          "C:\\a b\\jfk.wav", "--expect", "ask not what your country can do for you"])
        self.assertEqual(args.expect_output, ["Local transcription self-test passed"])
        self.assertEqual(args.timeout, 480.0)
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            NATIVE.parse_arguments(["--architecture", "arm64", "--evidence", "e.json", "run", "--label", "x",
                                    "--timeout", "1", "--stdout", "o", "--stderr", "e", "--"])

    @unittest.skipIf(os.name == "nt", "the refusal applies to hosts without the Windows process API")
    def test_process_checks_refuse_to_run_off_windows(self):
        with self.assertRaisesRegex(NATIVE.ExecutionError, "runs on Windows only"):
            NATIVE.main(["--architecture", "arm64", "--evidence", str(self.evidence), "host"])



class NativeOwnerRoutingTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="owned-routing-")
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        self.executable = self.root / "SpeakWindows.exe"
        self.executable.write_bytes(BUNDLE_TESTS.build_pe(machine=ARM64))
        self.launches = []

    def operate(self, code=3221226356, polls=2, ticks=(1000, 11000), frequency=1000,
                context=True, deadline=31000, target_frequency=1000, launch_hook=None, **changes):
        samples, events = iter(ticks), []
        def next_tick():
            events.append("ticks")
            sample = next(samples)
            if isinstance(sample, Exception):
                raise sample
            return sample
        api_clock = types.SimpleNamespace(frequency=lambda: frequency, ticks=mock.Mock(side_effect=next_tick),
                                          events=events)
        process = FakeProcess(polls=polls, exit_code=code)
        event_reader = mock.Mock(side_effect=AssertionError("no optional process launch"))
        def launch(arguments, stdout, stderr):
            self.launches.append(arguments)
            events.append("launch")
            if launch_hook:
                launch_hook()
            return process
        launcher = mock.Mock(side_effect=launch)
        original_observe = NATIVE.observe
        observer = mock.Mock(side_effect=lambda process, api, timeout: original_observe(
            process, api, timeout=timeout, clock=Clock(step=0.25), sleep=lambda _: None))
        host = changes.pop("host", "nt")
        executable = changes.pop("executable", self.executable)
        argv = changes.pop("argv", ["--ui-smoke-test"])
        label = changes.pop("label", "ui-smoke-test")
        architecture = changes.pop("architecture", "arm64")
        timeout = changes.pop("timeout", 30)
        with mock.patch.object(NATIVE, "os", types.SimpleNamespace(name=host, path=os.path, environ=os.environ)), \
                mock.patch.object(NATIVE, "observe", observer), \
                mock.patch.object(NATIVE.subprocess, "run", side_effect=AssertionError("no PS/CDB")):
            result = NATIVE.run([str(executable)] + argv, FakeAPI(modules=[[str(executable)]]),
                                architecture, label, timeout, self.root / "out", self.root / "err", (),
                                "C:\\Windows", launcher, native_image, event_reader,
                                diagnostic_owner_context=context, deadline_ticks=deadline,
                                deadline_frequency=target_frequency, deadline_api_factory=lambda: api_clock,
                                **changes)
        return result, process, observer, api_clock, event_reader

    def test_actual_run_caps_after_popen_and_emits_closed_owned_context_without_launching_diagnostics(self):
        marker = []
        record, process, observer, clock, reader = self.operate(launch_hook=lambda: marker.append("launched"))
        self.assertEqual(marker, ["launched"])
        self.assertEqual(observer.call_args.kwargs["timeout"], 20)
        self.assertEqual(clock.ticks.call_count, 2)
        self.assertEqual(clock.events, ["ticks", "launch", "ticks"])
        self.assertEqual(len(self.launches), 1)
        self.assertEqual(record["exitCode"], 3221226356)
        self.assertEqual(record["failures"], ["exited with 3221226356"])
        context = record["diagnosticOwnerContext"]
        self.assertEqual(set(context), {"schema", "originalPid", "startedUTC", "endedUTC",
                                        "deadlineTicks", "frequency", "exitCode"})
        self.assertEqual((context["schema"], context["originalPid"], context["deadlineTicks"],
                          context["frequency"], context["exitCode"]), (1, process.pid, 31000, 1000, -1073740940))
        self.assertLessEqual(datetime.datetime.fromisoformat(context["startedUTC"]),
                             datetime.datetime.fromisoformat(context["endedUTC"]))
        self.assertNotIn(str(self.root), json.dumps(context))
        reader.assert_not_called()
        self.assertNotIn("applicationError", record)

    def test_known_signed_and_unsigned_crashes_preserve_original_exit_and_failure(self):
        for signed in NATIVE.CRASH_CODES:
            for code in (signed, signed + 0x100000000):
                with self.subTest(code=code):
                    record, _, _, _, _ = self.operate(code=code)
                    self.assertEqual(record["diagnosticOwnerContext"]["exitCode"], signed)
                    self.assertEqual(record["exitCode"], code)
                    self.assertEqual(record["failures"], ["exited with %s" % code])

    def test_unknown_success_and_noninteger_crash_codes_do_not_normalize(self):
        for code in (None, True, False, 0, 1, "3221226356", 3221226356.0, 3221226356 + 0x100000000,
                     -1073740940 - 0x100000000):
            with self.subTest(code=code):
                self.assertIsNone(NATIVE.normalize_native_crash(code))
        for code in (0, 1, 0xc000001d, 0x100000000 + 0xc0000374):
            record, _, _, _, reader = self.operate(code=code)
            self.assertNotIn("diagnosticOwnerContext", record)
            reader.assert_not_called()

    def test_exhausted_after_launch_kills_owned_process_and_preserves_timeout_without_context(self):
        result, process, observer, _, reader = self.operate(polls=1000, ticks=(1000, 32000))
        self.assertEqual(observer.call_args.kwargs["timeout"], 0)
        self.assertTrue(process.killed)
        self.assertTrue(result["timedOut"])
        self.assertIn("did not exit before its deadline", result["failures"])
        self.assertNotIn("diagnosticOwnerContext", result)
        reader.assert_not_called()

    def test_clock_error_after_launch_still_observes_and_reaps_owned_process(self):
        result, process, observer, _, _ = self.operate(polls=1000, ticks=(1000, OSError("private-canary")))
        self.assertEqual(observer.call_args.kwargs["timeout"], 0)
        self.assertTrue(process.killed)
        self.assertTrue(result["timedOut"])
        self.assertNotIn("private-canary", json.dumps(result))
        self.assertNotIn("diagnosticOwnerContext", result)

    def test_fast_natural_exit_after_qpc_error_retains_failure_without_optional_context(self):
        result, process, observer, _, reader = self.operate(polls=1, ticks=(1000, OSError("private-canary")))
        self.assertEqual(observer.call_args.kwargs["timeout"], 0)
        self.assertFalse(process.killed)
        self.assertFalse(result["timedOut"])
        self.assertEqual(result["failures"], ["exited with 3221226356"])
        self.assertNotIn("diagnosticOwnerContext", result)
        reader.assert_not_called()

    def test_qpc_remaining_cannot_extend_original_timeout(self):
        record, _, observer, _, _ = self.operate(timeout=7, ticks=(1000, 2000))
        self.assertEqual(observer.call_args.kwargs["timeout"], 7)
        self.assertEqual(record["diagnosticOwnerContext"]["deadlineTicks"], 31000)

    def test_invalid_qpc_frequency_bounds_and_missing_fields_refuse_before_launch(self):
        invalid = [dict(deadline=None), dict(deadline=True), dict(deadline=0), dict(deadline=1 << 63),
                   dict(target_frequency=None), dict(target_frequency=0), dict(target_frequency=True),
                   dict(target_frequency=1 << 63), dict(frequency=2000), dict(ticks=(1000,), deadline=32001),
                   dict(ticks=(31000,)), dict(ticks=(32000,))]
        for changes in invalid:
            with self.subTest(changes=changes), \
                    mock.patch.object(NATIVE, "observe", side_effect=AssertionError("no child observation")), \
                    mock.patch.object(NATIVE.subprocess, "Popen", side_effect=AssertionError("no launch")):
                # Factory admission happens before the fixture's launcher; output files aren't opened.
                with self.assertRaises(NATIVE.ExecutionError):
                    self.operate(**changes)
                self.assertFalse((self.root / "out").exists())
                self.assertEqual(self.launches, [])

    def test_optin_wrong_host_target_label_program_arguments_or_timeout_refuses_before_launch(self):
        other = self.root / "Other.exe"
        other.write_bytes(BUNDLE_TESTS.build_pe(machine=ARM64))
        x64 = self.root / "x64" / "SpeakWindows.exe"
        x64.parent.mkdir()
        x64.write_bytes(BUNDLE_TESTS.build_pe(machine=AMD64))
        for changes in [dict(host="posix"), dict(architecture="x64", executable=x64),
                        dict(label="self-test"), dict(executable=other), dict(argv=["--self-test"]),
                        dict(argv=["--ui-smoke-test", "private-canary"]), dict(timeout=31),
                        dict(timeout=0), dict(timeout=float("nan"))]:
            with self.subTest(changes=changes), self.assertRaises(NATIVE.ExecutionError):
                self.operate(**changes)
            self.assertFalse((self.root / "out").exists())
            self.assertEqual(self.launches, [])

    def test_deadline_without_optin_refuses_but_no_flags_preserve_legacy_arm_behavior(self):
        with self.assertRaises(NATIVE.ExecutionError):
            self.operate(context=False)
        record, _, observer, clock, _ = self.operate(context=False, deadline=None, target_frequency=None,
                                                   host="posix", code=0)
        self.assertEqual(observer.call_args.kwargs["timeout"], 30)
        clock.ticks.assert_not_called()
        self.assertEqual(record["failures"], [])
        self.assertNotIn("diagnosticOwnerContext", record)

    def test_context_refuses_wrong_machine_bad_pid_timeout_or_invalid_utc_interval(self):
        start = datetime.datetime(2026, 10, 28, tzinfo=datetime.timezone.utc)
        observation = {"exitCode": 0xc0000374, "timedOut": False, "processMachine": ARM64, "nativeMachine": ARM64}
        deadline = types.SimpleNamespace(end=31000, frequency=1000)
        for pid, changes, seconds in [(True, {}, 1), (0, {}, 1), (1 << 32, {}, 1),
                                     (1, {"processMachine": AMD64}, 1), (1, {"nativeMachine": AMD64}, 1),
                                     (1, {"timedOut": True}, 1), (1, {}, -1), (1, {}, 30.001)]:
            with self.subTest(pid=pid, changes=changes, seconds=seconds):
                self.assertIsNone(NATIVE.native_owner_context(types.SimpleNamespace(pid=pid),
                    {**observation, **changes}, start, start + datetime.timedelta(seconds=seconds), deadline))

    def test_actual_python_owned_record_roundtrips_through_shared_powershell_native_adapter(self):
        host = shutil.which("pwsh")
        if host is None:
            self.skipTest("PowerShell unavailable: actual native context boundary not executed")
        with tempfile.TemporaryDirectory() as directory:
            environment = {key: value for key, value in os.environ.items()
                           if key.upper() in {"PATH", "SYSTEMROOT", "WINDIR", "HOME"}}
            environment.update(TEMP=directory, TMP=directory, TMPDIR=directory,
                               JSTI_PROJECTOR=str(HERE / "FailureDiagnostics.ps1"))
            query = subprocess.run([os.path.abspath(host), "-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
                                    "@{frequency=[System.Diagnostics.Stopwatch]::Frequency;ticks=[System.Diagnostics.Stopwatch]::GetTimestamp()} | ConvertTo-Json -Compress"],
                                   env=environment, cwd=directory, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, timeout=10, check=False)
            self.assertEqual(query.returncode, 0)
            self.assertEqual(query.stderr, b"")
            clock = json.loads(query.stdout)
            frequency, ticks = clock["frequency"], clock["ticks"]
            self.assertTrue(0 < frequency <= 1000000000)
            self.assertTrue(ticks > 0)
            image = {"path": APP, "name": "SpeakWindows.exe", "architecture": "arm64", "native": True,
                     "dll": False, "sha256": "a" * 64}
            with mock.patch.object(NATIVE, "check_images", return_value=[image]):
                record, _, _, _, _ = self.operate(executable=APP, frequency=frequency,
                    target_frequency=frequency, deadline=ticks + 30 * frequency, ticks=(ticks, ticks + 10 * frequency))
            script = r"""
$ErrorActionPreference='Stop'
. $env:JSTI_PROJECTOR
$document=[System.Text.Json.JsonDocument]::Parse([Console]::In.ReadToEnd())
$run=ConvertFrom-JstiEvidenceElement $document.RootElement
$original=(Get-Item Function:Invoke-JstiStandaloneDiagnostic).ScriptBlock
try {
    Set-Item Function:Invoke-JstiStandaloneDiagnostic {
        param($Setup,$Run,$Process,$Executable,$ExpectedSHA256,$DeadlineTicks,$Frequency,$StartedUTC,$EndedUTC)
        $script:handoff=@{adapted=$Run;pid=$Process.Id;deadline=$DeadlineTicks;frequency=$Frequency;
            executable=$Executable;hash=$ExpectedSHA256;start=$StartedUTC.ToString('o');end=$EndedUTC.ToString('o')}
        return @{status='unavailable'}
    }
    $result=Invoke-JstiNativeFailureDiagnostic @{Host=@{};Python=@{}} $run $run.executable.path `
        $run.executable.sha256 $run.diagnosticOwnerContext.deadlineTicks $run.diagnosticOwnerContext.frequency
    @{result=$result;handoff=$script:handoff;originalExit=$run.exitCode;failures=$run.failures} |
        ConvertTo-Json -Depth 12 -Compress
} finally {
    Set-Item Function:Invoke-JstiStandaloneDiagnostic $original
    $document.Dispose()
}
"""
            completed = subprocess.run([os.path.abspath(host), "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script],
                                       input=json.dumps(record).encode(), env=environment, cwd=directory,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15, check=False)
        self.assertEqual(completed.returncode, 0, "actual shared native adapter failed")
        self.assertEqual(completed.stderr, b"")
        self.assertLessEqual(len(completed.stdout), 8192)
        actual = json.loads(completed.stdout)
        self.assertEqual(actual["result"], {"status": "unavailable"})
        self.assertEqual(actual["originalExit"], record["exitCode"])
        self.assertEqual(actual["failures"], record["failures"])
        handoff = actual["handoff"]
        self.assertEqual(handoff["adapted"], {"label": "ui-smoke", "arguments": "--ui-smoke-test",
                                              "exitCode": -1073740940, "processMachine": "0xAA64"})
        self.assertEqual((handoff["pid"], handoff["deadline"], handoff["frequency"]),
                         (4242, ticks + 30 * frequency, frequency))
        self.assertEqual((handoff["executable"], handoff["hash"]), (APP, "a" * 64))
        for key, context_key in (("start", "startedUTC"), ("end", "endedUTC")):
            self.assertEqual(datetime.datetime.fromisoformat(handoff[key]),
                             datetime.datetime.fromisoformat(record["diagnosticOwnerContext"][context_key]))

    def test_actual_cli_forwards_owned_deadline_and_persists_original_failed_record(self):
        stdout, stderr, evidence = self.root / "out", self.root / "err", self.root / "evidence.json"
        stdout.write_text("owned smoke output", encoding="utf-8")
        stderr.write_text("", encoding="utf-8")
        record = {"label": "ui-smoke-test", "processMachine": "arm64", "exitCode": 3221226356,
                  "modulesObserved": 1, "seconds": 1, "failures": ["exited with 3221226356"],
                  "diagnosticOwnerContext": {"schema": 1, "originalPid": 4242}}
        windows = types.SimpleNamespace(name="nt", path=os.path, environ=os.environ, replace=os.replace)
        with mock.patch.object(NATIVE, "os", windows), mock.patch.object(NATIVE, "WindowsAPI", return_value=FakeAPI()), \
                mock.patch.object(NATIVE, "run", return_value=record) as invoke, contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(NATIVE.ExecutionError, "exited with 3221226356"):
                NATIVE.main(["--architecture", "arm64", "--evidence", str(evidence), "run",
                    "--label", "ui-smoke-test", "--timeout", "30", "--stdout", str(stdout), "--stderr", str(stderr),
                    "--diagnostic-owner-context", "--deadline-ticks", "31000", "--deadline-frequency", "1000",
                    "--", str(self.executable), "--ui-smoke-test"])
        self.assertEqual(invoke.call_args.kwargs, {"diagnostic_owner_context": True,
                                                   "deadline_ticks": 31000, "deadline_frequency": 1000})
        self.assertEqual(invoke.call_args.args[0], [str(self.executable), "--ui-smoke-test"])
        self.assertEqual(json.loads(evidence.read_text(encoding="utf-8"))["runs"], [record])

    def test_parser_carries_exact_context_options_without_consuming_program_arguments(self):
        args = NATIVE.parse_arguments(["--architecture", "arm64", "--evidence", "owned.json", "run",
            "--label", "ui-smoke-test", "--timeout", "30", "--stdout", "out", "--stderr", "err",
            "--diagnostic-owner-context", "--deadline-ticks", "31000", "--deadline-frequency", "1000",
            "--", "SpeakWindows.exe", "--ui-smoke-test"])
        self.assertTrue(args.diagnostic_owner_context)
        self.assertEqual((args.deadline_ticks, args.deadline_frequency), (31000, 1000))
        self.assertEqual(args.arguments, ["SpeakWindows.exe", "--ui-smoke-test"])



class PackagedApplicationErrorTests(unittest.TestCase):
    def request(self, **changes):
        value = dict(schema=1, architecture="arm64", label="base-ui-smoke-test", exitCode=-1073741819,
                     originalPid=4242, parentPid=123, startedUTC="2026-10-28T12:00:00Z",
                     endedUTC="2026-10-28T12:00:02Z", executable=r"C:\Owned\SpeakWindows.exe",
                     expectedSHA256="0" * 64, powershell=r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe",
                     powershellSHA256="1" * 64, startedTicks=1000, endedTicks=3000,
                     originalDeadlineTicks=61000, deadlineTicks=11000, frequency=1000)
        return dict(value, **changes)

    def encode(self, value):
        return base64.urlsafe_b64encode(json.dumps(value).encode("utf-8")).decode("ascii").rstrip("=")

    def event(self, **changes):
        data = dict(AppName="SpeakWindows.exe", AppPath=self.request()["executable"], ProcessId="4242",
                    ModuleName="PRIVATE_EVENT_CANARY.dll", ModuleVersion="1.2.3.4",
                    ExceptionCode="c0000005", FaultingOffset="00000123")
        data.update(changes)
        return dict(time="2026-10-28T12:00:01Z", data=data)

    def operate(self, value=None, runner=None, api=None, identity=None):
        api = api or types.SimpleNamespace(frequency=lambda: 1000, ticks=lambda: 3000, admitted=lambda _: True)
        runner = runner or (lambda *a, **k: dict(status="complete", cleanup="clean", exitCode=0,
            output=json.dumps(dict(status="ok", events=[self.event()])).encode("utf-8")))
        identity = identity or (lambda path, *a: (path, "same"))
        with mock.patch.dict(NATIVE.os.environ, {"SystemRoot": r"C:\Windows"}):
            return NATIVE.packaged_application_error(self.encode(value or self.request()),
                api_factory=lambda: api, runner=runner, identity=identity)

    def test_exact_event_only_request_and_long_original_span_do_not_widen_standalone(self):
        value = self.request(endedUTC="2026-10-28T12:00:59Z")
        self.assertEqual(NATIVE.packaged_event_request(self.encode(value)), value)
        old = StandaloneDiagnosticTests().request(endedUTC=value["endedUTC"])
        with self.assertRaises(ValueError):
            NATIVE.diagnostic_request(self.encode(old))

    def test_closed_request_all_unknown_missing_duplicate_and_oversize_refuse_without_query(self):
        runner = mock.Mock()
        for key in self.request():
            value = self.request(); value.pop(key)
            self.assertNotEqual(self.operate(value=value, runner=runner)["status"], "observed")
        self.assertEqual(self.operate(self.request(extra="PRIVATE_EVENT_CANARY"), runner)["status"], "invalid")
        for raw in (b'{"schema":1,"schema":1}', b'\xff', b' ' * 8193):
            encoded = base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")
            self.assertEqual(NATIVE.packaged_application_error(encoded)["status"], "invalid")
        runner.assert_not_called()

    def test_foreign_target_contracts_and_unsigned_or_unknown_exits_refuse_before_identity(self):
        identity, runner = mock.Mock(), mock.Mock()
        changes = [dict(schema=True), dict(exitCode=3221225477), dict(exitCode=0), dict(exitCode=42),
                   dict(architecture="x64"), dict(label="ui-smoke"), dict(originalPid=True), dict(parentPid=-1),
                   dict(executable=r"C:\Owned\other.exe"), dict(executable=r"C:\Owned\..\SpeakWindows.exe"),
                   dict(executable=r"\\server\SpeakWindows.exe"), dict(executable=r"C:\Owned\SpeakWindows.exe:ads"),
                   dict(expectedSHA256="F" * 64), dict(powershell=r"C:\Owned\powershell.exe"),
                   dict(startedUTC="2026-10-28T12:00:00"), dict(endedUTC="2026-10-28T12:01:01Z"),
                   dict(endedUTC="2026-10-28T11:59:59Z"), dict(frequency=True), dict(frequency=1000000001),
                   dict(startedTicks=2), dict(endedTicks=999), dict(originalDeadlineTicks=61001),
                   dict(deadlineTicks=62000)]
        for change in changes:
            with self.subTest(change=tuple(change)):
                self.assertEqual(self.operate(self.request(**change), runner=runner, identity=identity)["status"], "invalid")
        identity.assert_not_called(); runner.assert_not_called()

    def test_job_membership_clock_frequency_and_ended_tick_checks_precede_image_reads(self):
        identity, runner = mock.Mock(), mock.Mock()
        for frequency, now, admitted in ((999, 3000, True), (1000, 2000, True), (1000, 11001, True),
                                          (1000, 3000, False), (1000, 0, True)):
            api = types.SimpleNamespace(frequency=lambda: frequency, ticks=lambda: now, admitted=lambda _: admitted)
            self.assertNotEqual(self.operate(api=api, identity=identity, runner=runner)["status"], "observed")
        identity.assert_not_called(); runner.assert_not_called()

    def test_budget_consumed_by_image_admission_prevents_event_launch(self):
        clock = [3000]
        api = types.SimpleNamespace(frequency=lambda: 1000, ticks=lambda: clock[0], admitted=lambda _: True)
        def identity(*args):
            clock[0] = 6000
            return "snapshot"
        runner = mock.Mock()
        self.assertEqual(self.operate(api=api, identity=identity, runner=runner)["status"], "deadline")
        runner.assert_not_called()

    def test_one_fixed_query_returns_only_closed_original_event_and_no_replay(self):
        calls = []
        def query(argv, environment, directory, budget, seconds, **kwargs):
            calls.append(argv)
            self.assertEqual(argv, [self.request()["powershell"], "-NoLogo", "-NoProfile", "-NonInteractive",
                                    "-Command", NATIVE.APPLICATION_ERROR_QUERY])
            self.assertEqual(seconds, 5)
            self.assertEqual((environment["JSTI_EVENT_START"], environment["JSTI_EVENT_END"]),
                             (self.request()["startedUTC"], self.request()["endedUTC"]))
            self.assertNotIn("PRIVATE_PARENT_CANARY", environment)
            return dict(status="complete", cleanup="clean", exitCode=0,
                        output=json.dumps(dict(status="ok", events=[self.event()])).encode("utf-8"))
        with mock.patch.dict(NATIVE.os.environ, {"PRIVATE_PARENT_CANARY": "secret"}), \
                mock.patch.object(NATIVE, "cdb_commands", side_effect=AssertionError("no debugger")):
            result = self.operate(runner=query)
        self.assertEqual(len(calls), 1)
        self.assertEqual(result, dict(schema=1, status="observed", cleanup="clean", applicationError=dict(
            status="observed", module="unknown", version="1.2.3.4", exceptionCode="0xc0000005",
            faultOffset="0x0000000000000123")))
        self.assertNotIn("PRIVATE", json.dumps(result)); self.assertNotIn("timeUTC", json.dumps(result))

    def test_pid_path_time_and_multiple_event_matching_is_not_broadened(self):
        cases = [([self.event(ProcessId="4243")], "no-match"),
                 ([self.event(AppPath=r"C:\Elsewhere\SpeakWindows.exe")], "no-match"),
                 ([dict(self.event(), time="2026-10-28T12:00:03Z")], "no-match"),
                 ([self.event(ExceptionCode="c0000409")], "invalid"),
                 ([self.event(), self.event()], "ambiguous")]
        for events, expected in cases:
            query = lambda *a, **k: dict(status="complete", cleanup="clean", exitCode=0,
                                        output=json.dumps(dict(status="ok", events=events)).encode("utf-8"))
            result = self.operate(runner=query)
            self.assertEqual(result["applicationError"], dict(status=expected))
            self.assertNotEqual(result["status"], "observed")

    def test_bad_output_error_timeout_cap_and_failed_cleanup_never_publish_observed(self):
        for event in [dict(status="complete", cleanup="clean", exitCode=0, output=b"PRIVATE_CANARY"),
                      dict(status="complete", cleanup="clean", exitCode=0, output=b"x" * 65537),
                      dict(status="complete", cleanup="clean", exitCode=0, output=b'{"status":"ok","status":"ok","events":[]}'),
                      dict(status="complete", cleanup="clean", exitCode=42, output=b"PRIVATE_CANARY"),
                      dict(status="deadline", cleanup="clean", exitCode=None, output=b"PRIVATE_CANARY"),
                      dict(status="truncated", cleanup="clean", exitCode=0, output=b"PRIVATE_CANARY"),
                      dict(status="complete", cleanup="failed", exitCode=0, output=b"PRIVATE_CANARY")]:
            result = self.operate(runner=lambda *a, **k: event)
            self.assertNotEqual(result["status"], "observed")
            self.assertNotIn("PRIVATE", json.dumps(result))
            self.assertNotIn("debugger", result)

    def test_image_changes_after_query_discard_observation(self):
        calls = []
        def identity(path, *args):
            calls.append(path)
            return path, len(calls) > 2
        self.assertNotEqual(self.operate(identity=identity)["status"], "observed")
        self.assertGreater(len(calls), 2)

    def test_private_scratch_cleanup_failure_disposes_observed_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            scratch = types.SimpleNamespace(name=directory, cleanup=mock.Mock(side_effect=OSError("PRIVATE_CANARY")))
            for runner in (None, lambda *a, **k: dict(status="complete", cleanup="clean", exitCode=0,
                                                      output=b"x" * 65537)):
                with mock.patch.object(NATIVE.tempfile, "TemporaryDirectory", return_value=scratch):
                    result = self.operate(runner=runner)
                self.assertEqual(result, NATIVE.packaged_event_result("unavailable", "failed"))

    def test_internal_dispatch_never_routes_event_only_to_legacy_or_debugger(self):
        with mock.patch.object(NATIVE, "main", side_effect=AssertionError("legacy")), \
                mock.patch.object(NATIVE, "standalone_main", side_effect=AssertionError("debugger")), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            NATIVE.dispatch_main(["packaged-application-error", "--wrong", "PRIVATE_CANARY"])
        result = json.loads(output.getvalue())
        self.assertEqual(result, NATIVE.packaged_event_result("invalid"))
        self.assertLess(len(output.getvalue()), 8192)

    @unittest.skipUnless(shutil.which("pwsh"), "pure PowerShell projector needs pwsh")
    def test_actual_event_json_passes_actual_ps_projection_and_private_unknown_fields_refuse(self):
        projection = self.operate()
        with tempfile.TemporaryDirectory() as directory:
            script = pathlib.Path(directory) / "projection.ps1"
            script.write_text(". '" + str(HERE / "FailureDiagnostics.ps1").replace("'", "''") + "'\n" +
                "$v=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" +
                base64.b64encode(json.dumps(projection).encode("utf-8")).decode("ascii") + "'))|ConvertFrom-Json\n" +
                "$safe=ConvertTo-JstiPackagedEventProjection $v\n" +
                "if($safe.applicationError.faultOffset -cne '0x0000000000000123'){throw 'projection'}\n" +
                "foreach($key in @('debugger','frames','private')){\n" +
                "$v|Add-Member -NotePropertyName $key -NotePropertyValue 'PRIVATE_CANARY'\n" +
                "$refused=$false;try{$null=ConvertTo-JstiPackagedEventProjection $v}catch{$refused=$true}\n" +
                "if(-not $refused){throw 'unknown field'};$v.PSObject.Properties.Remove($key)}\n" +
                "if('JstiDiagnosticNative' -as [type]){throw 'native load'}\n", encoding="utf-8")

            script.write_text(script.read_text(encoding="utf-8") + r"""
$script:eventProjection=$v
function Get-JstiDiagnosticIdentity { param($path,$names,[switch]$FrameworkPath)
 if(-not $FrameworkPath){throw 'framework option'};return @{Path=$path;Hash='0'*64} }
function New-JstiDiagnosticAdapter { param($frequency,$state);$script:eventState=$state;return @{} }
function Invoke-JstiDiagnosticBootstrap { param($adapter,$launch,[long]$cutoff,[long]$frequency)
 if($launch.Arguments[3] -cne 'packaged-application-error'){throw 'mode'}
 $bytes=[Text.Encoding]::UTF8.GetBytes(($script:eventProjection|ConvertTo-Json -Depth 8 -Compress))
 $script:eventState.Output.Write($bytes,0,$bytes.Length)
 return @{status='finished';cleanup='complete'} }
$env:SystemRoot='C:\Windows';$systemRoot=$env:SystemRoot;$isolatedPath='C:\Windows\System32'
$workspace=[IO.Path]::GetDirectoryName($PSCommandPath)
$f=[Diagnostics.Stopwatch]::Frequency;$t=[Diagnostics.Stopwatch]::GetTimestamp()
$ctx=@{originalPid=4242;startedUTC=[datetime]::UtcNow.AddSeconds(-2);endedUTC=[datetime]::UtcNow.AddSeconds(-1)
 startedTicks=$t-2*$f;endedTicks=$t-$f;originalDeadlineTicks=$t+58*$f;frequency=$f}
$setup=@{Host=@{Path='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe';Hash='0'*64}
 Python=@{Path='C:\Owned\python.exe';Hash='0'*64}}
$run=@{label='base-ui-smoke-test';arguments='--ui-smoke-test';exitCode=-1073741819
 packageFullName='owned';identityError=$null;modules=@{passed=$true}}
$before=$run|ConvertTo-Json -Depth 8 -Compress
$receipt=Invoke-JstiPackagedEventDiagnostic $setup $run $ctx 'C:\Owned\SpeakWindows.exe' ('0'*64) 'owned'
if($receipt.status -cne 'observed' -or $receipt.applicationErrorEvidence.applicationError.faultOffset -cne '0x0000000000000123'){throw 'wrapper interop'}
if(($run|ConvertTo-Json -Depth 8 -Compress) -cne $before){throw 'original changed'}
if('JstiDiagnosticNative' -as [type]){throw 'native load'}
""", encoding="utf-8")
            result = subprocess.run([shutil.which("pwsh"), "-NoProfile", "-NonInteractive", "-File", str(script)],
                                    capture_output=True, timeout=15, check=False)
            self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", errors="replace"))


if __name__ == "__main__":
    unittest.main()
