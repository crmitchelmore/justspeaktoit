#!/usr/bin/env python3
"""Exercise the gate's failure semantics without needing an Apple toolchain."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest

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
        code, _, output = self.run_command('print("compiler failed"); raise SystemExit(17)')
        self.assertEqual(code, 17)
        self.assertIn("compiler failed", output)

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
