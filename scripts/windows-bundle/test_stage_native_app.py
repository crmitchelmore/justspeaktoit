#!/usr/bin/env python3
"""Unit tests for stage-native-app.py."""
import hashlib
import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.dont_write_bytecode = True


def load(name, file_name):
    spec = importlib.util.spec_from_file_location(name, HERE / file_name)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


STAGE = load("stage_native_app", "stage-native-app.py")
BUNDLE_TESTS = load("test_windows_bundle", "test_windows_bundle.py")
ARM64 = STAGE.windows_pe.IMAGE_FILE_MACHINE_ARM64
VERSIONS = {"swiftCompiler": "Swift version 6.2.3 (swift-6.2.3-RELEASE)", "nativeCompiler": "clang version 17.0.0"}


class StageTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = pathlib.Path(self.directory.name)
        self.bin = root / ".build" / "aarch64-unknown-windows-msvc" / "release"
        self.bin.mkdir(parents=True)
        self.executable = BUNDLE_TESTS.build_pe(["KERNEL32.dll", "swiftCore.dll"], machine=ARM64)
        (self.bin / "SpeakWindows.exe").write_bytes(self.executable)
        self.cli = BUNDLE_TESTS.build_pe(["KERNEL32.dll", "swiftCore.dll"], machine=ARM64)
        (self.bin / "speak.exe").write_bytes(self.cli)
        (self.bin / "SpeakApp_SpeakCore.resources").mkdir()
        (self.bin / "SpeakApp_SpeakCore.resources" / "ReleaseNotes.json").write_bytes(b"[]")
        (self.bin / "SpeakApp_SpeakWindowsPlatformTests.resources").mkdir()
        (self.bin / "SpeakApp_SpeakWindowsPlatformTests.resources" / "tone.m4a").write_bytes(b"audio")
        self.output = root / "staged"

    def stage(self, architecture="arm64", bin_path=None):
        return STAGE.stage(bin_path or self.bin, self.output, architecture, "0123456789abcdef", VERSIONS)

    def test_native_production_app_is_staged_with_bundle_builder_metadata(self):
        metadata = self.stage()
        self.assertEqual(sorted(path.name for path in self.output.iterdir()),
                         ["SpeakApp_SpeakCore.resources", "SpeakWindows.exe", "app-build-metadata.json", "speak.exe"])
        self.assertEqual(metadata["target"], "aarch64-unknown-windows-msvc")
        self.assertEqual(metadata["imageArchitecture"], "arm64")
        self.assertEqual(metadata["executables"]["SpeakWindows.exe"], hashlib.sha256(self.executable).hexdigest())
        self.assertEqual(metadata["executables"]["speak.exe"], hashlib.sha256(self.cli).hexdigest())
        self.assertEqual(metadata["imageArchitectures"], {"SpeakWindows.exe": "arm64", "speak.exe": "arm64"})
        # A later test build cannot change the retained production CLI.
        (self.bin / "speak.exe").write_bytes(BUNDLE_TESTS.build_pe(["Testing.dll"], machine=ARM64))
        self.assertEqual((self.output / "speak.exe").read_bytes(), self.cli)
        self.assertIs(metadata["appBuiltForTesting"], False)
        written = json.loads((self.output / "app-build-metadata.json").read_text(encoding="utf-8"))
        self.assertEqual(written, metadata)

    def test_cli_missing_foreign_and_test_enabled_are_refused_before_any_staging(self):
        path = self.bin / "speak.exe"
        path.unlink()
        with self.assertRaisesRegex(STAGE.StageError, "missing production executable speak.exe"):
            self.stage()
        self.assertFalse(self.output.exists())
        for data, message in (
            (BUNDLE_TESTS.build_pe(), "speak.exe is a x64 image"),
            (BUNDLE_TESTS.build_pe(delay_imports=["Testing.dll"], machine=ARM64), "speak.exe imports Testing.dll"),
            (BUNDLE_TESTS.build_pe(machine=ARM64, dll=True), "not a native arm64 executable"),
            (BUNDLE_TESTS.build_pe(machine=ARM64, subsystem=2), "console subsystem"),
        ):
            path.write_bytes(data)
            with self.assertRaisesRegex(STAGE.StageError, message):
                self.stage()
            self.assertFalse(self.output.exists())

    def test_x64_native_staging_keeps_both_hashes_and_images(self):
        root = pathlib.Path(self.directory.name) / "x64" / "x86_64-unknown-windows-msvc" / "release"
        root.mkdir(parents=True)
        for name, subsystem in (("SpeakWindows.exe", 2), ("speak.exe", 3)):
            (root / name).write_bytes(BUNDLE_TESTS.build_pe(["swiftCore.dll"], subsystem=subsystem))
        metadata = self.stage("x64", root)
        for name in STAGE.EXECUTABLES:
            self.assertEqual((root / name).read_bytes(), (self.output / name).read_bytes())
            self.assertEqual(metadata["executables"][name], hashlib.sha256((root / name).read_bytes()).hexdigest())
            self.assertEqual(metadata["imageArchitectures"][name], "x64")

    def test_future_resource_directories_are_retained(self):
        directory = self.bin / "SpeakApp_Future.resources" / "nested"
        directory.mkdir(parents=True)
        (directory / "payload.json").write_bytes(b"{}")
        metadata = self.stage()
        self.assertIn("SpeakApp_Future.resources", metadata["resources"])
        self.assertEqual((self.output / "SpeakApp_Future.resources/nested/payload.json").read_bytes(), b"{}")

    def test_foreign_test_enabled_or_misplaced_builds_are_refused(self):
        (self.bin / "SpeakWindows.exe").write_bytes(BUNDLE_TESTS.build_pe(["KERNEL32.dll"]))
        with self.assertRaisesRegex(STAGE.StageError, "x64 image, not a native arm64 executable"):
            self.stage()
        (self.bin / "SpeakWindows.exe").write_bytes(BUNDLE_TESTS.build_pe(["KERNEL32.dll"], ["XCTest.dll"], machine=ARM64))
        with self.assertRaisesRegex(STAGE.StageError, "imports XCTest.dll"):
            self.stage()
        with self.assertRaisesRegex(STAGE.StageError, "not a x86_64-unknown-windows-msvc release build"):
            self.stage("x64")
        debug = self.bin.parent / "debug"
        debug.mkdir()
        with self.assertRaisesRegex(STAGE.StageError, "release build directory"):
            self.stage(bin_path=debug)
        self.output.mkdir()
        (self.output / "stale.txt").write_bytes(b"x")
        (self.bin / "SpeakWindows.exe").write_bytes(self.executable)
        with self.assertRaisesRegex(STAGE.StageError, "new or empty"):
            self.stage()


    def test_optional_symbols_transform_records_final_hashes_and_retains_originals(self):
        symbols_tests = load("native_symbols_fixtures", "test_production_symbols.py")
        from unittest import mock
        original = symbols_tests.image(machine=ARM64)
        for name in STAGE.EXECUTABLES:
            (self.bin / name).write_bytes(original)
        tool = pathlib.Path(self.directory.name).resolve() / "llvm-objcopy"
        tool.write_bytes(b"fixture tool")
        def execute(command, **kwargs):
            if command[1] == "--version":
                return symbols_tests.subprocess.CompletedProcess(command, 0, stdout=b"LLVM fixture")
            pathlib.Path(command[3]).write_bytes(symbols_tests.without_debug(
                pathlib.Path(command[2]).read_bytes(), arm_padding=True))
            return symbols_tests.subprocess.CompletedProcess(command, 0)
        with mock.patch.object(STAGE.production_symbols.subprocess, "run", side_effect=execute):
            metadata = STAGE.stage(self.bin, self.output, "arm64", "a" * 40, VERSIONS, strip_tool=tool)
        for name in STAGE.EXECUTABLES:
            result = metadata["productionSymbols"][name]
            self.assertEqual(result["status"], "optimized")
            self.assertNotEqual(metadata["executables"][name], hashlib.sha256(original).hexdigest())
            self.assertEqual(metadata["executables"][name], hashlib.sha256((self.output / name).read_bytes()).hexdigest())
            self.assertEqual((self.output / result["retainedPath"]).read_bytes(), original)
            self.assertEqual((self.bin / name).read_bytes(), original)

    def test_no_tool_explicitly_records_unoptimized_original_baseline(self):
        metadata = self.stage()
        self.assertEqual(metadata["productionSymbols"], {
            name: {"status": "not-optimized", "reason": "tool-not-provided"} for name in STAGE.EXECUTABLES})
        self.assertFalse((self.output / "diagnostic-symbols").exists())


if __name__ == "__main__":
    unittest.main()
