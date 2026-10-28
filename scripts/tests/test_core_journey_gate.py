#!/usr/bin/env python3
"""Exercise the gate's failure semantics without needing an Apple toolchain."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import subprocess
import tempfile
import time
import unittest
from unittest import mock

MODULE_PATH = Path(__file__).resolve().parents[1] / "run-core-journey-e2e.py"
SPEC = importlib.util.spec_from_file_location("core_journey_gate", MODULE_PATH)
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


class CoverageTests(unittest.TestCase):
    def test_apple_and_portable_case_formats(self):
        for case in ("-[SpeakAppTests.Required testResult]", "SpeakAppTests.Required.testResult", "Required.testResult"):
            errors, counts = gate.coverage_errors(f"Test Case '{case}' passed (0.001 seconds).\n", ["Required"])
            self.assertEqual(errors, [])
            self.assertEqual(counts["Required"]["passed"], 1)

    def test_empty_selection_does_not_pass(self):
        errors, _ = gate.coverage_errors("Executed 0 tests, with 0 failures\n", ["Required"])
        self.assertTrue(errors)

    def test_interleaved_apple_completion_preserves_order_identity_and_failure(self):
        prefix = "2026-10-28 00:07:27.446622+0000 JustSpeakToIt[100:200] [api] Updating activity 0000-"
        output = "Test Case '-[Module.Required testFirst]' passed (0.001 seconds).\n"
        output += prefix + "Test Case '-[Module.Required testSecond]' failed (0.219 seconds).\n0000\n"
        output += "Test Case '-[Module.Required testThird]' passed (0.001 seconds).\n"
        cases = list(gate.case_results(output))
        self.assertEqual([case["case"] for case in cases], ["testFirst", "testSecond", "testThird"])
        self.assertEqual(cases[1], {"module": "Module", "suite": "Required",
                                    "case": "testSecond", "status": "failed"})
        errors, counts = gate.coverage_errors(output, ["Required"])
        self.assertEqual(counts["Required"]["failed"], 1)
        self.assertTrue(errors, "An interleaved failure must still fail the required gate")

    def test_embedded_examples_and_incomplete_console_records_do_not_prove_execution(self):
        result = "Test Case '-[Module.Required testExample]' passed (0.219 seconds)."
        prefix = "2026-10-28 00:07:27.446622+0000 JustSpeakToIt[100:200] [api] "
        for line in ("arbitrary prefix " + result, 'print("' + result + '")',
                     prefix + '"example ' + result + '"',
                     "2026-10-28 JustSpeakToIt [api] " + result,
                     prefix + result.removesuffix(" (0.219 seconds)."),
                     prefix + result + " trailing text",
                     prefix + "Test Case 'Module.Required.testExample' passed (0.219 seconds)."):
            with self.subTest(line=line):
                self.assertEqual(list(gate.case_results(line + "\n")), [])
                self.assertTrue(gate.coverage_errors(line + "\n", ["Required"])[0])

    def test_interleaved_completion_cannot_cross_physical_lines_but_accepts_terminal_crlf(self):
        prefix = "2026-10-28 00:07:27.446622+0000 JustSpeakToIt[100:200] [api] Updating activity 0000-"
        for separator in ("\n", "\r"):
            with self.subTest(separator=repr(separator)):
                output = (prefix + "Test Case '-[Module.Required testExample" + separator
                          + "not a complete physical record]' passed (0.219 seconds).\n")
                self.assertEqual(list(gate.case_results(output)), [])
                self.assertTrue(gate.coverage_errors(output, ["Required"])[0])
        output = prefix + "Test Case '-[Module.Required testComplete]' passed (0.219 seconds).\r\n"
        self.assertEqual(list(gate.case_results(output)), [{
            "module": "Module", "suite": "Required", "case": "testComplete", "status": "passed",
        }])

    def test_unrelated_or_similarly_named_suite_does_not_satisfy_requirement(self):
        output = "Test Case '-[Module.RequiredExtra testResult]' passed (0.001 seconds).\n"
        errors, _ = gate.coverage_errors(output, ["Required"])
        self.assertTrue(errors)

    def test_all_skipped_or_partial_skip_fails(self):
        skipped = "Test Case '-[Module.Required testSkip]' skipped (0.001 seconds).\n"
        passed = "Test Case '-[Module.Required testPass]' passed (0.001 seconds).\n"
        for output in (skipped, skipped + passed):
            errors, _ = gate.coverage_errors(output, ["Required"])
            self.assertTrue(errors)

    def test_failed_case_cannot_be_hidden_by_success_exit(self):
        output = "Test Case '-[Module.Required testPass]' passed (0.001 seconds).\n"
        output += "Test Case '-[Module.Required testFail]' failed (0.001 seconds).\n"
        errors, _ = gate.coverage_errors(output, ["Required"])
        self.assertTrue(errors)


class NativeUICoverageTests(unittest.TestCase):
    def test_native_gate_requires_each_suite_and_rejects_partial_skips(self):
        verifier = MODULE_PATH.with_name("verify-core-journey-ui.py")
        suites = ["LaunchUITests", "CoreJourneyFixtureUITests", "CoreJourneyHotKeyUITests", "CoreJourneyBatchUITests",
                  "SettingsCredentialUITests", "CoreJourneyPostProcessingUITests"]
        passing = "".join(f"Test Case '-[SpeakAppUITests.{suite} testJourney]' passed (0.001 seconds).\n"
                          for suite in suites[:-1])
        names = ["testBatchPolishing_DeliversProcessedTextAndRetainsRawHistory",
                 "testBatchPolishing_FailureThenFreshRecordingRecoversInSameProcess"]
        required = [f"Test Case '-[SpeakAppUITests.CoreJourneyPostProcessingUITests {name}]' "
                    "passed (0.001 seconds).\n" for name in names]
        passing += "".join(required)
        cases = [
            (passing, 0),
            (passing.replace("CoreJourneyBatchUITests", "RenamedBatchUITests"), 1),
            (passing.replace("SettingsCredentialUITests", "RenamedSettingsUITests"), 1),
            (passing.replace("SettingsCredentialUITests testJourney]\' passed",
                             "SettingsCredentialUITests testJourney]\' skipped"), 1),
            (passing + "Test Case '-[SpeakAppUITests.CoreJourneyBatchUITests testSkipped]' skipped (0 seconds).\n", 1),
            (passing.replace(required[0], ""), 1),
            (passing.replace(required[1], ""), 1),
            (passing.replace(required[0], required[0].replace("passed", "skipped")), 1),
            (passing.replace(required[1], required[1].replace("passed", "failed")), 1),
            (passing + required[0], 1),
        ]
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "xcodebuild.log"
            for output, expected in cases:
                with self.subTest(expected=expected, output=output):
                    log.write_text(output)
                    result = subprocess.run([sys.executable, str(verifier), str(log)], capture_output=True, text=True)
                    self.assertEqual(result.returncode, expected, result.stderr)
                    coverage = json.loads(log.with_name("coverage.json").read_text())
                    self.assertEqual(bool(coverage["errors"]), expected != 0)
                    self.assertEqual(coverage["required_suites"], suites)


class RunnerTests(unittest.TestCase):
    def run_command(self, source, budget=5):
        with tempfile.TemporaryDirectory() as directory:
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                code = gate.run_gate([sys.executable, "-c", source], directory, budget, ["Required"])
            artifacts = Path(directory)
            self.assertTrue((artifacts / "timing.txt").read_text().startswith("core_journey_elapsed_seconds="))
            result = json.loads((artifacts / "result.json").read_text())
            self.assertEqual(result["exit_code"], code)
            return code, result, (artifacts / "test.log").read_text()

    def test_success_requires_execution_evidence(self):
        code, result, _ = self.run_command('print("Test Case \'-[Module.Required testResult]\' passed (0.001 seconds).")')
        self.assertEqual(code, 0)
        self.assertEqual(result["executed_cases"]["Required"]["passed"], 1)

    def test_zero_exit_with_no_tests_is_failure(self):
        code, result, _ = self.run_command('print("No matching test cases were run")')
        self.assertEqual(code, 1)
        self.assertTrue(result["errors"])

    def test_failure_retains_status_and_log(self):
        code, result, output = self.run_command('print("compiler failed"); raise SystemExit(17)')
        self.assertEqual(code, 17)
        self.assertIn("compiler failed", output)
        self.assertTrue(any("status 17" in error for error in result["errors"]))

    def test_timeout_retains_partial_log_and_timing(self):
        code, result, output = self.run_command('import time; print("started", flush=True); time.sleep(60)', budget=0.1)
        self.assertEqual(code, 124)
        self.assertTrue(result["errors"])
        self.assertIn("started", output)
        self.assertLess(result["elapsed_seconds"], 3)

    def test_missing_executable_emits_failure_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                code = gate.run_gate([str(Path(directory) / "missing")], directory, 1, ["Required"])
            self.assertEqual(code, 1)
            result = json.loads((Path(directory) / "result.json").read_text())
            self.assertTrue(result["errors"])
            self.assertTrue((Path(directory) / "timing.txt").exists())

    def test_artifact_write_failure_preserves_command_failure_or_timeout(self):
        for filename in ["timing.txt", "result.json"]:
            for source, budget, expected in [
                ("raise SystemExit(17)", 5, 17),
                ("import time; time.sleep(60)", 0.1, 124),
            ]:
                with self.subTest(filename=filename, expected=expected), tempfile.TemporaryDirectory() as directory:
                    original_write = Path.write_text

                    def fail_selected_artifact(path, *args, **kwargs):
                        if path.name == filename:
                            raise OSError("fixture disk full")
                        return original_write(path, *args, **kwargs)

                    diagnostics = io.StringIO()
                    with mock.patch.object(Path, "write_text", fail_selected_artifact):
                        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(diagnostics):
                            code = gate.run_gate(
                                [sys.executable, "-c", source], directory, budget, ["Required"]
                            )
                    self.assertEqual(code, expected)
                    self.assertIn(f"Could not write {filename}: fixture disk full", diagnostics.getvalue())
                    self.assertTrue((Path(directory) / "test.log").exists())
                    if filename == "timing.txt":
                        result = json.loads((Path(directory) / "result.json").read_text())
                        self.assertEqual(result["exit_code"], expected)
                        self.assertTrue(any("timing.txt" in error for error in result["errors"]))
                    else:
                        self.assertTrue((Path(directory) / "timing.txt").exists())

    def test_artifact_write_failure_cannot_leave_successful_command_green(self):
        source = 'print("Test Case \'-[Module.Required testResult]\' passed (0.001 seconds).")'
        with tempfile.TemporaryDirectory() as directory:
            diagnostics = io.StringIO()
            with mock.patch.object(Path, "write_text", side_effect=OSError("fixture disk full")):
                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(diagnostics):
                    code = gate.run_gate([sys.executable, "-c", source], directory, 5, ["Required"])
            self.assertEqual(code, 1)
            self.assertIn("Could not write timing.txt", diagnostics.getvalue())
            self.assertIn("Could not write result.json", diagnostics.getvalue())

    def test_unusable_artifact_directory_reports_failure_without_raising(self):
        with tempfile.TemporaryDirectory() as directory:
            blocked_path = Path(directory) / "occupied"
            blocked_path.write_text("an existing file")
            diagnostics = io.StringIO()
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(diagnostics):
                code = gate.run_gate([sys.executable, "-c", "raise SystemExit(17)"], blocked_path, 5, ["Required"])
            self.assertEqual(code, 1)
            self.assertIn("Could not write result.json", diagnostics.getvalue())
            self.assertEqual(blocked_path.read_text(), "an existing file")

    def test_post_command_work_cannot_turn_on_time_success_into_timeout(self):
        source = 'print("Test Case \'-[Module.Required testResult]\' passed (0.001 seconds).")'
        # Runner start, command start/end, then delayed log replay/coverage work.
        # subprocess has its own captured clock, so this controls only our timing.
        with mock.patch.object(gate.time, "monotonic", side_effect=[0, 0, 0.1, 100]):
            code, result, _ = self.run_command(source, budget=5)
        self.assertEqual(code, 0)
        self.assertEqual(result["command_elapsed_seconds"], 0.1)
        self.assertEqual(result["elapsed_seconds"], 100)
        self.assertEqual(result["errors"], [])

    def test_timeout_stops_descendants_too(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "descendant-survived"
            child_source = f"import time; from pathlib import Path; time.sleep(1); Path({str(marker)!r}).touch()"
            source = (
                "import subprocess, sys, time; "
                f"subprocess.Popen([sys.executable, '-c', {child_source!r}]); "
                "print('child spawned', flush=True); time.sleep(60)"
            )
            code, _, output = self.run_command(source, budget=0.3)
            self.assertEqual(code, 124)
            self.assertIn("child spawned", output)
            time.sleep(1)
            self.assertFalse(marker.exists(), "The timed-out test command leaked a running descendant")


if __name__ == "__main__":
    unittest.main()
