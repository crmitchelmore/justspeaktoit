#!/usr/bin/env python3
"""Host, image and diagnostic-tool inventory evidence (native_execution_host).

Unit tests for verify-native-execution.py; Windows process calls are faked.
"""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(HERE))
import native_execution_host as HOST  # noqa: E402
import native_execution_run as RUN  # noqa: E402
from native_execution_fakes import (  # noqa: E402
    AMD64,
    ARM64,
    FIXTURES,
    SYSTEM,
    FakeAPI,
    FakeProcess,
    native_image,
)


class ImageAndHostTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)

    def write(self, name, **options):
        path = self.root / name
        path.write_bytes(FIXTURES.build_pe(["KERNEL32.dll"], **options))
        return path

    def test_images_must_run_natively_on_the_target(self):
        arm64 = self.write("SpeakWindows.exe", machine=ARM64)
        hybrid = self.write("msvcp140.dll", machine=ARM64, dll=True, hybrid_metadata=0x180105050)
        records = HOST.check_images([arm64, hybrid], "arm64")
        self.assertEqual([record["architecture"] for record in records], ["arm64", "arm64x"])
        self.assertEqual(records[0]["sha256"], HOST.sha256_file(arm64))
        for name, options in [("x64.exe", {}), ("ec.dll", {"dll": True, "hybrid_metadata": 0x18000A2E8})]:
            with self.assertRaisesRegex(HOST.ExecutionError, "not native arm64 images"):
                HOST.check_images([self.write(name, **options)], "arm64")
        with self.assertRaisesRegex(HOST.ExecutionError, "not native x64 images"):
            HOST.check_images([arm64], "x64")

    def test_host_must_be_native_for_the_target(self):
        toolchain = self.write("swift.exe", machine=ARM64)
        record = HOST.check_host(FakeAPI(), "arm64", [toolchain])
        self.assertEqual(record["nativeMachine"], "arm64")
        self.assertEqual(record["pythonProcessMachine"], "arm64")
        self.assertEqual(record["toolchain"][0]["architecture"], "arm64")
        with self.assertRaisesRegex(HOST.ExecutionError, "native machine is x64, not arm64"):
            HOST.check_host(FakeAPI(machine=AMD64, native=AMD64), "arm64")

    def test_run_requires_native_success_and_expected_output(self):
        executable = self.write("SpeakWindows.exe", machine=ARM64)
        stdout, stderr = self.root / "out.log", self.root / "err.log"

        def launch(arguments, stdout, stderr):
            self.assertEqual(arguments, [str(executable), "--self-test"])
            stdout.write(b"Windows native self-test passed\n")
            return FakeProcess()

        api = FakeAPI(modules=[[str(executable)] + SYSTEM])
        record = RUN.run([str(executable), "--self-test"], api, "arm64", "self-test", 30, stdout, stderr,
                            ["self-test passed"], "C:\\Windows", launch, native_image)
        self.assertEqual(record["failures"], [])
        self.assertEqual(record["processMachine"], "arm64")
        self.assertEqual(record["executable"]["architecture"], "arm64")
        record = RUN.run([str(executable), "--self-test"], FakeAPI(modules=[[str(executable)]]), "arm64",
                            "self-test", 30, stdout, stderr, ["window passed"], "C:\\Windows", launch, native_image)
        self.assertIn("output lacks 'window passed'", record["failures"])
        with self.assertRaisesRegex(HOST.ExecutionError, "not native arm64 images"):
            RUN.run([str(self.write("x64.exe"))], api, "arm64", "x", 30, stdout, stderr, (), "C:\\Windows",
                       launch, native_image)


class DiagnosticInventoryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="private-canary-")
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)

    def inventory(self, files, version=None, **options):
        windows = types.SimpleNamespace(name="nt", fstat=options.get("fstat", os.fstat))
        with mock.patch.object(HOST, "os", windows), mock.patch.object(HOST, "DIAGNOSTIC_CANDIDATES", files):
            return HOST.diagnostic_tools(read_version=version or (lambda _: None), clock=options.get("clock", lambda: 0))

    def image(self, name, machine=ARM64):
        path = self.root / name
        path.write_bytes(FIXTURES.build_pe(machine=machine))
        return path

    def test_fixed_candidates_and_nonwindows_do_not_discover_or_launch_tools(self):
        self.assertEqual(len(HOST.DIAGNOSTIC_CANDIDATES), 11)
        self.assertEqual(len(set(label for label, _ in HOST.DIAGNOSTIC_CANDIDATES)), 11)
        self.assertTrue(all(path.startswith(("C:\\Program Files (x86)\\Windows Kits\\10\\Debuggers\\",
                                                   "C:\\Windows\\"))
                            for _, path in HOST.DIAGNOSTIC_CANDIDATES))
        with mock.patch.object(HOST, "os", types.SimpleNamespace(name="posix")), \
                mock.patch.object(pathlib.Path, "lstat", side_effect=AssertionError("no file read")), \
                mock.patch.object(subprocess, "run", side_effect=AssertionError("no launch")):
            self.assertEqual(HOST.diagnostic_tools(), {"status": "unsupported", "tools": []})

    def test_owned_fake_pe_hash_architecture_numeric_version_and_no_private_path(self):
        arm, x64 = self.image("gflags.exe"), self.image("cdb.exe", AMD64)
        result = self.inventory((("sdk10-arm64-gflags", str(arm)), ("sdk10-x64-cdb", str(x64))),
                                version=lambda _: [10, 0, 26100, 1])
        self.assertEqual(result["coverage"], "fixed-sdk10-system-candidates-only")
        for row, path, arch in zip(result["tools"], (arm, x64), ("arm64", "x64")):
            self.assertEqual(row["status"], "present")
            self.assertTrue(row["present"])
            self.assertEqual(row["architecture"], arch)
            self.assertEqual(row["sha256"], HOST.sha256_file(path))
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
            with mock.patch.object(pathlib.Path, "lstat", side_effect=error):
                result = self.inventory(files)
            self.assertEqual(result["tools"][0]["status"], status)
            self.assertIsNone(result["tools"][0]["present"])
            self.assertNotIn("private-canary", json.dumps(result))
        fake = types.SimpleNamespace(st_mode=0o100600, st_file_attributes=0x400)
        with mock.patch.object(pathlib.Path, "lstat", return_value=fake), \
                mock.patch.object(pathlib.Path, "open", side_effect=AssertionError("no reparse read")):
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
        with mock.patch.object(HOST, "DIAGNOSTIC_FILE_LIMIT", 16):
            result = self.inventory(files, reader)
        self.assertTrue(all(row["status"] == "unknown" for row in result["tools"]))
        reader.assert_not_called()
        with mock.patch.object(HOST, "DIAGNOSTIC_TOTAL_LIMIT", first.stat().st_size):
            result = self.inventory(files)
        self.assertEqual([row["status"] for row in result["tools"]], ["present", "unknown"])
        with mock.patch.object(pathlib.Path, "lstat", side_effect=AssertionError("budget exhausted")):
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
        with mock.patch.object(pathlib.Path, "lstat", return_value=fake), \
                mock.patch.object(pathlib.Path, "open", return_value=stream), \
                mock.patch.object(HOST, "DIAGNOSTIC_TOTAL_LIMIT", 16):
            result = self.inventory((("sdk10-arm64-gflags", str(path)), ("sdk10-arm64-cdb", str(path))),
                                    reader, fstat=lambda _: fake)
        # First changing file consumes9 bytes; the second8-byte candidate cannot fit remaining7.
        stream.read.assert_called_once_with(9)
        reader.assert_not_called()
        self.assertTrue(all(row["status"] == "unknown" for row in result["tools"]))
        stream.reset_mock()
        with mock.patch.object(pathlib.Path, "lstat", return_value=fake), \
                mock.patch.object(pathlib.Path, "open", return_value=stream), \
                mock.patch.object(HOST, "DIAGNOSTIC_TOTAL_LIMIT", 8):
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
        with mock.patch.object(pathlib.Path, "lstat", return_value=fake), \
                mock.patch.object(pathlib.Path, "open", return_value=stream) as opened, \
                mock.patch.object(HOST, "DIAGNOSTIC_TOTAL_LIMIT", 16):
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
        with mock.patch.object(pathlib.Path, "lstat", return_value=before), \
                mock.patch.object(pathlib.Path, "stat", side_effect=PermissionError("private-canary")):
            result = self.inventory((("sdk10-arm64-gflags", str(path)),), reader)
        reader.assert_called_once_with(path)
        self.assertEqual(result["tools"], [
            {"candidate": "sdk10-arm64-gflags", "status": "denied", "present": None}])
        self.assertNotIn("private-canary", json.dumps(result))

    def test_optional_inventory_failure_never_changes_host_verdict(self):
        with mock.patch.object(HOST, "diagnostic_tools", side_effect=RuntimeError("private-canary")) as reader:
            result = HOST.check_host(FakeAPI(), "arm64")
            self.assertEqual(result["nativeMachine"], "arm64")
            self.assertEqual(result["diagnosticTools"], {"status": "unavailable", "tools": []})
            self.assertNotIn("private-canary", json.dumps(result))
            reader.reset_mock()
            with self.assertRaisesRegex(HOST.ExecutionError, "native machine is x64"):
                HOST.check_host(FakeAPI(machine=AMD64, native=AMD64), "arm64")
            reader.assert_not_called()


if __name__ == "__main__":
    unittest.main()
