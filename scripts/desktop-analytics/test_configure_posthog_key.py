"""Checks the desktop PostHog project-key writer with synthetic keys."""
import contextlib
import importlib.util
import io
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("configure", HERE / "configure-posthog-key.py")
CONFIGURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONFIGURE)

KEY = "phc_Synthetic0123456789abcdefGHIJKLmnopqrst-_"


class ConfigurePostHogKeyTests(unittest.TestCase):
    def committed(self) -> str:
        return CONFIGURE.TARGET.read_text(encoding="utf-8")

    def run_main(self, environment):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "DesktopAnalyticsBuildConfiguration.swift"
            target.write_text(self.committed(), encoding="utf-8")
            output = io.StringIO()
            with mock.patch.dict(os.environ, environment, clear=True), contextlib.redirect_stdout(output), \
                    contextlib.redirect_stderr(output):
                status = CONFIGURE.main(target)
            return status, target.read_text(encoding="utf-8"), output.getvalue()

    def test_committed_source_has_no_key(self):
        self.assertEqual(self.committed().count(CONFIGURE.PLACEHOLDER), 1)
        self.assertNotIn("phc_", self.committed())

    def test_key_is_written_and_never_printed(self):
        status, source, output = self.run_main({"POSTHOG_PROJECT_KEY": " " + KEY + "\n"})
        self.assertEqual(status, 0)
        self.assertIn('public static let postHogProjectKey: String? = "%s"' % KEY, source)
        self.assertNotIn("= nil", source)
        self.assertNotIn(KEY, output)

    def test_missing_key_leaves_the_build_keyless(self):
        for environment in ({}, {"POSTHOG_PROJECT_KEY": ""}, {"POSTHOG_PROJECT_KEY": "  "}):
            status, source, _ = self.run_main(environment)
            self.assertEqual(status, 0)
            self.assertEqual(source, self.committed())

    def test_malformed_keys_are_refused_without_failing_the_release(self):
        for key in ['phc_abc"; exit(1); //', "phc_short", "phx_0123456789abcdef", "sk-0123456789abcdef",
                    "phc_0123456789 abcdef", "phc_0123456789\\abcdef", "phc_0123456789abcdé", "phc_" + "a" * 129]:
            with self.assertRaises(ValueError):
                CONFIGURE.configured_source(self.committed(), key)
            status, source, output = self.run_main({"POSTHOG_PROJECT_KEY": key})
            self.assertEqual(status, 0)
            self.assertEqual(source, self.committed())
            self.assertIn("::warning::", output)
            self.assertNotIn(key, output)

    def test_a_missing_placeholder_fails(self):
        with self.assertRaises(LookupError):
            CONFIGURE.configured_source("public enum DesktopAnalyticsBuildConfiguration {}\n", KEY)


if __name__ == "__main__":
    unittest.main()
