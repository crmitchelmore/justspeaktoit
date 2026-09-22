#!/usr/bin/env python3
"""Lightweight lockfile regression tests; no SDK download or compiler execution."""
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


if __name__ == "__main__":
    unittest.main()
