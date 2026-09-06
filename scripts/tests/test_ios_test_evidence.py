#!/usr/bin/env python3
"""Exercise iOS evidence gates without an Apple toolchain."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "verify-ios-test-evidence.py"
SPEC = importlib.util.spec_from_file_location("ios_test_evidence", SCRIPT)
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


def completion(suite, method="testResult", status="passed", target="SpeakiOSTests"):
    return f"Test Case '-[{target}.{suite} {method}]' {status} (0.001 seconds).\n"


def passing_log():
    return (
        completion("OpenRouterAudioSettingsTests", "testSelection")
        + completion("OpenRouterAudioSettingsTests", "testDefaultVoice")
        + completion("OpenRouterVoiceCancellationTests", "testStop")
        + completion("ActionButtonSettingsUITests", target="SpeakiOSUITests")
    )


class IOSCoverageTests(unittest.TestCase):
    def test_observed_apple_ios_format_retains_target_identity(self):
        # Actual iOS runner completion from CI run 33679755480, retained in its
        # xcresult console attachment (the old -quiet host log omitted it).
        line = (
            "Test Case '-[SpeakiOSTests.AppGroupConfigurationTests "
            "testKeyboardUsesSameEntitledAppGroup]' passed (0.004 seconds).\n"
        )
        self.assertEqual(list(gate.PARSER(line)), [{
            "module": "SpeakiOSTests", "suite": "AppGroupConfigurationTests",
            "case": "testKeyboardUsesSameEntitledAppGroup", "status": "passed",
        }])

    def test_success_reports_both_targets_and_critical_suite_counts(self):
        result = gate.summarize(passing_log(), "success")
        self.assertEqual(result["errors"], [])
        self.assertEqual(result["unique_cases"], 4)
        self.assertEqual(result["counts"], {"passed": 4, "failed": 0, "skipped": 0})
        unit = result["targets"]["SpeakiOSTests"]
        self.assertEqual(unit["unique_cases"], 3)
        self.assertEqual(unit["suites"]["OpenRouterAudioSettingsTests"]["passed"], 2)
        self.assertEqual(unit["suites"]["OpenRouterVoiceCancellationTests"]["passed"], 1)
        self.assertEqual(result["targets"]["SpeakiOSUITests"]["counts"]["passed"], 1)

    def test_zero_cases_and_suite_headings_do_not_prove_execution(self):
        for output in ("", "Executed 0 tests, with 0 failures\n", "** TEST SUCCEEDED **\n",
                       "Test Suite 'SpeakiOSUITests.xctest' passed at 2026-09-02.\n"):
            with self.subTest(output=output):
                result = gate.summarize(output, "success")
                self.assertTrue(result["errors"])
                self.assertEqual(result["unique_cases"], 0)

    def test_missing_target_or_critical_suite_fails_even_with_other_passes(self):
        for name in ("SpeakiOSTests", "SpeakiOSUITests", "OpenRouterAudioSettingsTests",
                     "OpenRouterVoiceCancellationTests"):
            with self.subTest(name=name):
                result = gate.summarize(passing_log().replace(name, name + "Extra"), "success")
                self.assertTrue(any(name in error for error in result["errors"]))

    def test_critical_suite_in_wrong_module_or_without_module_does_not_count(self):
        for target in ("UnrelatedTests.", ""):
            with self.subTest(target=target):
                output = passing_log().replace("SpeakiOSTests.", target)
                self.assertTrue(gate.summarize(output, "success")["errors"])

    def test_all_skipped_and_partially_skipped_critical_suites_fail(self):
        for suite in gate.REQUIRED_SUITES["SpeakiOSTests"]:
            for partial in (False, True):
                with self.subTest(suite=suite, partial=partial):
                    output = passing_log()
                    if not partial:
                        output = "\n".join(line for line in output.splitlines() if suite not in line) + "\n"
                    output += completion(suite, "testSkipped", "skipped")
                    errors = gate.summarize(output, "success")["errors"]
                    self.assertTrue(any(suite in error and "skipped" in error for error in errors))

    def test_failure_in_any_selected_target_fails_even_when_command_reports_success(self):
        for target in gate.REQUIRED_TARGETS:
            with self.subTest(target=target):
                output = passing_log() + completion("AnotherSuite", status="failed", target=target)
                self.assertTrue(gate.summarize(output, "success")["errors"])

    def test_passing_retry_cannot_hide_prior_failure_or_skip(self):
        for status in ("failed", "skipped"):
            with self.subTest(status=status):
                output = completion("OpenRouterAudioSettingsTests", "testSelection", status) + passing_log()
                result = gate.summarize(output, "success")
                self.assertTrue(result["errors"])
                self.assertEqual(result["unique_cases"], 4)
                self.assertEqual(result["counts"][status], 1)

    def test_duplicate_console_results_do_not_inflate_test_counts(self):
        self.assertEqual(gate.summarize(passing_log() * 2, "success"), gate.summarize(passing_log(), "success"))

    def test_failed_cancelled_or_skipped_command_cannot_pass_with_complete_results(self):
        for outcome in ("failure", "cancelled", "skipped"):
            with self.subTest(outcome=outcome):
                result = gate.summarize(passing_log(), outcome)
                self.assertTrue(any("command outcome" in error for error in result["errors"]))

    def test_cli_always_writes_summary_even_for_missing_or_incomplete_log(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "ios-tests.log"
            summary = Path(directory) / "summary.json"
            for content, outcome, code in ((None, "skipped", 1), ("", "success", 1),
                                           (passing_log(), "success", 0)):
                with self.subTest(outcome=outcome, code=code, content=content):
                    if content is not None:
                        log.write_text(content)
                    result = subprocess.run([
                        sys.executable, str(SCRIPT), str(log), "--test-outcome", outcome,
                        "--output", str(summary),
                    ], capture_output=True, text=True)
                    self.assertEqual(result.returncode, code, result.stderr)
                    saved = json.loads(summary.read_text())
                    self.assertEqual(bool(saved["errors"]), code != 0)
                    self.assertNotIn("testSelection", summary.read_text(), "Summary must omit raw case/log content")

    def test_cli_accepts_exact_byte_limit_but_rejects_oversize_without_parsing_prefix(self):
        passing = passing_log().encode("utf-8")
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "ios-tests.log"
            summary = Path(directory) / "summary.json"
            argv = [str(SCRIPT), str(log), "--test-outcome", "success", "--output", str(summary)]
            for extra, expected in ((b"", 0), (b"x", 1)):
                with self.subTest(extra=extra):
                    log.write_bytes(passing + extra)
                    with mock.patch.object(gate, "MAX_LOG_BYTES", len(passing)), mock.patch.object(sys, "argv", argv):
                        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                            self.assertEqual(gate.main(), expected)
                    saved = json.loads(summary.read_text())
                    self.assertEqual(saved["unique_cases"], 4 if expected == 0 else 0)
                    self.assertEqual(bool(saved["errors"]), expected != 0)
                    if extra:
                        self.assertTrue(any("exceeds" in error for error in saved["errors"]))
                        self.assertLess(summary.stat().st_size, 4096)


class WorkflowEvidenceTests(unittest.TestCase):
    @staticmethod
    def step(name):
        workflow = SCRIPT.parents[1] / ".github/workflows/ci.yml"
        return workflow.read_text().split(f"      - name: {name}\n", 1)[1].split("\n      - name:", 1)[0]

    def test_full_test_records_and_verifier_are_required_on_success(self):
        test_step = self.step("Test iOS App and Action Button Settings")
        self.assertNotIn("-quiet", test_step)
        self.assertIn("set -o pipefail", test_step)
        self.assertIn('tee "$RUNNER_TEMP/ios-tests.log"', test_step)
        verifier = self.step("Verify iOS XCTest execution evidence")
        self.assertIn("if: ${{ always() }}", verifier)
        self.assertIn("steps.ios-tests.outcome", verifier)
        self.assertNotIn("continue-on-error", verifier)

    def test_success_retains_only_small_summary_with_short_retention(self):
        summary = self.step("Upload iOS test execution summary")
        self.assertIn("if: ${{ always() }}", summary)
        self.assertIn("retention-days: 7", summary)
        self.assertIn("if-no-files-found: error", summary)
        self.assertNotIn("xcresult", summary)
        self.assertNotIn("ios-tests.log", summary)
        diagnostics = self.step("Upload iOS test results")
        self.assertIn("if: ${{ failure() || cancelled() }}", diagnostics)


if __name__ == "__main__":
    unittest.main()
