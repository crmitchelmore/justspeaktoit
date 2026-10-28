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
        # Explicit inert dot-source returns before native preparation or the
        # original verifier; only its pure closed JSON projection is called.
        script = """
$ErrorActionPreference='Stop'
. $env:JSTI_PROJECTOR -BundleDirectory '__jsti_bootstrap_fake__' -Workspace '__jsti_bootstrap_fake__' -ExpectedCommit '__jsti_bootstrap_fake__'
$value=[Console]::In.ReadToEnd() | ConvertFrom-Json -Depth 8
ConvertTo-JstiDiagnosticProjection $value | ConvertTo-Json -Depth 8 -Compress
"""
        with tempfile.TemporaryDirectory() as directory:
            environment = {key: val for key, val in os.environ.items()
                           if key.upper() in {"PATH", "SYSTEMROOT", "WINDIR", "HOME"}}
            environment.update(TEMP=directory, TMP=directory, TMPDIR=directory,
                               JSTI_PROJECTOR=str(HERE / "verify-windows-bundle.ps1"))
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


if __name__ == "__main__":
    unittest.main()
