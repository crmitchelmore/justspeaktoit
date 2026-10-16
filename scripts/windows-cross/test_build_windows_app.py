#!/usr/bin/env python3
"""Lightweight lockfile regression tests; no SDK download or compiler execution."""
import hashlib
import importlib.util
import pathlib
import stat
import subprocess
import tempfile
import unittest
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("windows_app_build", HERE / "build-windows-app.py")
BUILD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILD)
PE_FIXTURE_SPEC = importlib.util.spec_from_file_location(
    "windows_bundle_fixtures", HERE.parent / "windows-bundle" / "test_windows_bundle.py")
PE_FIXTURES = importlib.util.module_from_spec(PE_FIXTURE_SPEC)
PE_FIXTURE_SPEC.loader.exec_module(PE_FIXTURES)


class PackageLockPreservationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.package = pathlib.Path(self.directory.name)
        self.lockfile = self.package / "Package.resolved"
        self.log = self.package / "build.log"

    def build(self, effect):
        with mock.patch.object(BUILD.subprocess, "run", side_effect=effect) as invoke:
            BUILD.run_package_build(["swift", "build"], {"SPEAK_WINDOWS_TARGET": "1"}, self.log, self.package)
            invoke.assert_called_once()
            self.assertEqual(invoke.call_args.kwargs["env"], {"SPEAK_WINDOWS_TARGET": "1"})

    def assert_restored(self, contents, mode):
        self.assertEqual(self.lockfile.read_bytes(), contents)
        self.assertEqual(stat.S_IMODE(self.lockfile.stat().st_mode), mode)
        self.assertEqual(list(self.package.glob(".Package.resolved-cross-*")), [])

    def test_success_restores_deleted_dirty_lock_bytes_and_permissions(self):
        dirty = b'{"pins":[{"uncommitted":"caf\xc3\xa9"}]}\r\n'
        self.lockfile.write_bytes(dirty)
        self.lockfile.chmod(0o640)
        self.build(lambda *args, **kwargs: self.lockfile.unlink())
        self.assert_restored(dirty, 0o640)

    def test_failed_build_restores_replaced_read_only_lock_and_propagates_error(self):
        dirty = b"local pins, not a Git revision\n"
        self.lockfile.write_bytes(dirty)
        self.lockfile.chmod(0o440)

        def fail(*args, **kwargs):
            self.lockfile.unlink()
            self.lockfile.write_bytes(b"Windows replacement")
            self.lockfile.chmod(0o600)
            raise subprocess.CalledProcessError(37, ["swift", "build"])

        with self.assertRaises(subprocess.CalledProcessError) as raised:
            self.build(fail)
        self.assertEqual(raised.exception.returncode, 37)
        self.assert_restored(dirty, 0o440)

    def test_success_without_initial_lock_removes_generated_lock(self):
        self.build(lambda *args, **kwargs: self.lockfile.write_bytes(b"generated"))
        self.assertFalse(self.lockfile.exists())

    def test_failure_without_initial_lock_removes_generated_lock(self):
        def fail(*args, **kwargs):
            self.lockfile.write_bytes(b"generated before failure")
            raise RuntimeError("simulated build failure")

        with self.assertRaisesRegex(RuntimeError, "simulated build failure"):
            self.build(fail)
        self.assertFalse(self.lockfile.exists())

    def test_build_that_does_not_create_a_lock_keeps_it_absent(self):
        self.build(lambda *args, **kwargs: None)
        self.assertFalse(self.lockfile.exists())

    def test_symlink_is_left_intact_and_build_does_not_start(self):
        target = self.package / "external-pins.json"
        target.write_bytes(b"external pins")
        self.lockfile.symlink_to(target)
        with mock.patch.object(BUILD.subprocess, "run") as invoke:
            with self.assertRaisesRegex(ValueError, "regular file"):
                BUILD.run_package_build(["swift", "build"], {}, self.log, self.package)
            invoke.assert_not_called()
        self.assertTrue(self.lockfile.is_symlink())
        self.assertEqual(target.read_bytes(), b"external pins")


class BuildInvocationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name).resolve()
        self.cache, self.output = self.root / "cache", self.root / "output"

    def arguments(self, *extra):
        return BUILD.parse_arguments(["--cache", str(self.cache), "--output", str(self.output), *extra])

    def assert_rejected(self, *extra):
        with mock.patch("sys.stderr"), self.assertRaises(SystemExit) as raised:
            self.arguments(*extra)
        self.assertEqual(raised.exception.code, 2)

    def test_defaults_keep_cache_scratch_and_four_jobs(self):
        args = self.arguments()
        self.assertEqual((args.configuration, args.scratch_path, args.jobs), ("release", None, 4))
        self.assertEqual(BUILD.build_locations(args), (self.cache, self.output, self.cache / "app-build"))

    def test_both_products_are_built_copied_and_hashed_before_any_test_build(self):
        built = self.root / "built"
        events = []
        def build(command, *args):
            events.append(("build", command[-1]))
        def retain(source, destination, *args):
            events.append(("copy", source.name, destination.name))
            return "sha-" + source.name
        with mock.patch.object(BUILD, "run_package_build", side_effect=build), \
                mock.patch.object(BUILD, "copy_executable", side_effect=retain):
            hashes = BUILD.build_production(["swift", "build", "--configuration", "release"], {},
                                            self.root / "log", self.root, built, self.output, self.root / "clang")
        self.assertEqual(events, [("build", "SpeakWindows"), ("copy", "SpeakWindows.exe", "SpeakWindows.exe"),
                                  ("build", "speak"), ("copy", "speak.exe", "speak.exe")])
        self.assertEqual(hashes, {"SpeakWindows.exe": "sha-SpeakWindows.exe", "speak.exe": "sha-speak.exe"})

    def test_cli_build_failure_prevents_a_successful_production_receipt(self):
        with mock.patch.object(BUILD, "run_package_build", side_effect=[None, RuntimeError("CLI build failed")]), \
                mock.patch.object(BUILD, "copy_executable", return_value="gui-sha") as retain:
            with self.assertRaisesRegex(RuntimeError, "CLI build failed"):
                BUILD.build_production(["swift", "build"], {}, self.root / "log", self.root,
                                       self.root / "built", self.output, self.root / "clang")
            self.assertEqual(retain.call_count, 1)

    def test_explicit_scratch_and_jobs_are_parsed(self):
        args = self.arguments("--scratch-path", str(self.root / "scratch dir é"), "--jobs", "2")
        self.assertEqual(args.jobs, 2)
        self.assertEqual(BUILD.build_locations(args)[2], self.root / "scratch dir é")

    def test_relative_scratch_is_resolved_before_use(self):
        scratch = BUILD.build_locations(self.arguments("--scratch-path", "relative-scratch"))[2]
        self.assertEqual(scratch, pathlib.Path("relative-scratch").resolve())
        self.assertTrue(scratch.is_absolute())

    def test_jobs_must_be_a_plain_positive_integer(self):
        for value in ["0", "-1", "+2", " 2", "1_0", "2.0", "x", "", "٣"]:
            with self.subTest(value=value):
                self.assert_rejected("--jobs", value)
        self.assertEqual(self.arguments("--jobs", "16").jobs, 16)

    def test_scratch_must_stay_out_of_publishable_output(self):
        for scratch in [self.output, self.output / "build", self.root]:
            with self.subTest(scratch=scratch):
                with self.assertRaisesRegex(SystemExit, "publishable app output"):
                    BUILD.build_locations(self.arguments("--scratch-path", str(scratch)))

    def test_scratch_must_not_contain_the_prerequisite_cache(self):
        self.output = pathlib.Path("/unrelated/output")
        for scratch in [self.cache, self.root]:
            with self.subTest(scratch=scratch):
                with self.assertRaisesRegex(SystemExit, "prerequisite cache"):
                    BUILD.build_locations(self.arguments("--scratch-path", str(scratch)))
        for scratch in [self.cache / "app-build-arm64", self.root / "sibling-scratch"]:
            self.assertEqual(BUILD.build_locations(self.arguments("--scratch-path", str(scratch)))[2], scratch)

    def test_build_invocation_uses_scratch_and_jobs(self):
        tool, sdk, microsoft = pathlib.Path("/t/usr"), pathlib.Path("/s/Developer/SDKs/Windows.sdk"), pathlib.Path("/m")
        command = [str(value) for value in BUILD.swift_build_command(
            tool, sdk, microsoft, self.root / "scratch", "debug", 2)]
        self.assertEqual(command[8:14], ["--scratch-path", str(self.root / "scratch"),
                                         "--configuration", "debug", "--jobs", "2"])
        self.assertEqual((command.count("--scratch-path"), command.count("--jobs")), (1, 1))

    def test_default_build_invocation_is_unchanged(self):
        # Literal pre-option command: defaults must not alter the x64 build.
        tool, sdk, microsoft = pathlib.Path("/t/usr"), pathlib.Path("/s/Developer/SDKs/Windows.sdk"), pathlib.Path("/m")
        args = self.arguments()
        scratch = BUILD.build_locations(args)[2]
        command = BUILD.swift_build_command(tool, sdk, microsoft, scratch, args.configuration, args.jobs)
        msvc = "/Contents/VC/Tools/MSVC/14.44.35207/"
        kits = "/m/microsoft.windows.sdk.cpp.10.0.26100.1/c/Include/10.0.26100.0/"
        expected = ["/t/usr/bin/swift", "build", "--package-path", str(HERE.parent.parent),
                    "--triple", "x86_64-unknown-windows-msvc", "--sdk", str(sdk),
                    "--scratch-path", str(self.cache / "app-build"), "--configuration", "release", "--jobs", "4",
                    "-Xswiftc", "-resource-dir", "-Xswiftc", str(sdk) + "/usr/lib/swift",
                    "-Xswiftc", "-tools-directory", "-Xswiftc", "/t/usr/bin", "-Xswiftc", "-use-ld=lld"]
        for directory in [str(sdk) + "/usr/include", "/m/Microsoft.VC.14.44.17.14.CRT.Headers.base" + msvc + "include",
                          kits + "ucrt", kits + "um", kits + "shared", kits + "winrt"]:
            expected += ["-Xswiftc", "-I", "-Xswiftc", directory, "-Xcc", "-isystem", "-Xcc", directory]
        expected += ["-Xcc", "-D_MT", "-Xcc", "-D_DLL", "-Xcc", "-fms-compatibility-version=19.44"]
        modules = "/s/Developer/Library/{}-6.2.3/usr/lib/swift/windows"
        for name in ["XCTest", "Testing"]:
            expected += ["-Xswiftc", "-I", "-Xswiftc", modules.format(name)]
        for directory in [str(sdk) + "/usr/lib/swift/windows/x86_64",
                          "/m/Microsoft.VC.14.44.17.14.CRT.x64.Store.base" + msvc + "lib/x64",
                          "/m/Microsoft.VC.14.44.17.14.CRT.x64.Desktop.base" + msvc + "lib/x64",
                          "/m/microsoft.windows.sdk.cpp.x64.10.0.26100.1/c/ucrt/x64",
                          "/m/microsoft.windows.sdk.cpp.x64.10.0.26100.1/c/um/x64",
                          modules.format("XCTest") + "/x86_64", modules.format("Testing") + "/x86_64"]:
            expected += ["-Xlinker", "/libpath:" + directory]
        self.assertEqual([str(value) for value in command], expected)


class ProductionImageTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        self.source = self.root / "build" / "speak.exe"
        self.source.parent.mkdir()
        self.destination = self.root / "speak.exe"

    def test_cli_is_copied_byte_exact_hashed_and_inspected_by_llvm(self):
        data = PE_FIXTURES.build_pe(imports=["swiftCore.dll"], delay_imports=["KERNEL32.dll"])
        self.source.write_bytes(data)
        with mock.patch.object(BUILD.BOOTSTRAP, "run") as inspect:
            digest = BUILD.copy_executable(self.source, self.destination, self.root / "clang", self.root / "log")
        self.assertEqual(self.destination.read_bytes(), data)
        self.assertEqual(digest, hashlib.sha256(data).hexdigest())
        self.assertEqual(inspect.call_args.args[0], [
            self.root / "clang" / "llvm-readobj", "--file-headers", "--coff-imports", self.destination])

    def test_cli_console_architecture_and_test_imports_are_checked_before_copy(self):
        cases = [
            (PE_FIXTURES.build_pe(subsystem=2), "console subsystem"),
            (PE_FIXTURES.build_pe(machine=BUILD.windows_pe.IMAGE_FILE_MACHINE_ARM64), "Windows x64 executable"),
            (PE_FIXTURES.build_pe(dll=True), "Windows x64 executable"),
            (PE_FIXTURES.build_pe(delay_imports=["Testing.dll"]), "test library"),
        ]
        for data, message in cases:
            self.source.write_bytes(data)
            with self.subTest(message=message), mock.patch.object(BUILD.BOOTSTRAP, "run") as inspect:
                with self.assertRaisesRegex(ValueError, message):
                    BUILD.copy_executable(self.source, self.destination, self.root / "clang", self.root / "log")
                self.assertFalse(self.destination.exists())
                inspect.assert_not_called()


if __name__ == "__main__":
    unittest.main()
