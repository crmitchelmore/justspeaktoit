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
                         ["SpeakApp_SpeakCore.resources", "SpeakWindows.exe", "app-build-metadata.json"])
        self.assertEqual(metadata["target"], "aarch64-unknown-windows-msvc")
        self.assertEqual(metadata["imageArchitecture"], "arm64")
        self.assertEqual(metadata["executables"]["SpeakWindows.exe"], hashlib.sha256(self.executable).hexdigest())
        self.assertIs(metadata["appBuiltForTesting"], False)
        written = json.loads((self.output / "app-build-metadata.json").read_text(encoding="utf-8"))
        self.assertEqual(written, metadata)

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


if __name__ == "__main__":
    unittest.main()
