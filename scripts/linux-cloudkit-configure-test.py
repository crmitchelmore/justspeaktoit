#!/usr/bin/env python3
"""Checks the Linux CloudKit build-setting writer with synthetic tokens.

Run: python3 -B scripts/linux-cloudkit-configure-test.py
"""
from pathlib import Path
import importlib.util
import os
import shutil
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("linux_configure", HERE / "linux-cloudkit-configure.py")
CONFIGURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONFIGURE)


class LinuxCloudKitConfigureTests(unittest.TestCase):
    def test_committed_linux_source_has_no_token(self):
        source = CONFIGURE.TARGET.read_text(encoding="utf-8")
        self.assertIn("static let apiToken: String? = nil", source)
        self.assertIn('static let environment = "production"', source)

    def test_the_windows_rules_apply_to_the_linux_file(self):
        configured = CONFIGURE.windows_configurator()
        source = configured(CONFIGURE.TARGET.read_text(encoding="utf-8"), "synthetic0token0value0abcdef", "development")
        self.assertIn('static let apiToken: String? = "synthetic0token0value0abcdef"', source)
        self.assertIn('static let environment = "development"', source)
        with self.assertRaises(ValueError):
            configured(source, 'abc"; exit(1); //', "production")

    def test_main_writes_only_the_linux_file_and_never_prints_the_token(self):
        with tempfile.TemporaryDirectory() as folder:
            copy = Path(folder) / "CloudKitWebBuildConfiguration.swift"
            shutil.copy(CONFIGURE.TARGET, copy)
            with mock.patch.object(CONFIGURE, "TARGET", copy), \
                    mock.patch.dict(os.environ, {"CLOUDKIT_WEB_API_TOKEN": "synthetic0token0value0abcdef"}), \
                    mock.patch("builtins.print") as printed:
                self.assertEqual(CONFIGURE.main(), 0)
            self.assertIn("synthetic0token0value0abcdef", copy.read_text(encoding="utf-8"))
            for call in printed.call_args_list:
                self.assertNotIn("synthetic0token0value0abcdef", " ".join(map(str, call.args)))

    def test_without_a_token_nothing_changes(self):
        with mock.patch.dict(os.environ, {"CLOUDKIT_WEB_API_TOKEN": ""}), mock.patch("builtins.print"):
            before = CONFIGURE.TARGET.read_text(encoding="utf-8")
            self.assertEqual(CONFIGURE.main(), 0)
            self.assertEqual(CONFIGURE.TARGET.read_text(encoding="utf-8"), before)


if __name__ == "__main__":
    unittest.main()
