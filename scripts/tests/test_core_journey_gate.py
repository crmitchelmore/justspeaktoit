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
    def test_ordinary_apple_method_identity_refuses_multiline_and_quoted_examples(self):
        for method in ("testBad\nextra", "testBad\rextra", "testBad'example", 'testBad"example'):
            with self.subTest(method=method):
                output = f"Test Case '-[Module.Required {method}]' passed (0.001 seconds).\n"
                self.assertEqual(list(gate.case_results(output)), [])
                self.assertTrue(gate.coverage_errors(output, ["Required"])[0])
        for newline in ("\n", "\r\n"):
            output = "Test Case '-[Module.Required testValid_1]' passed (0.001 seconds)." + newline
            self.assertEqual(list(gate.case_results(output)), [{
                "module": "Module", "suite": "Required", "case": "testValid_1", "status": "passed",
            }])

    def test_method_splice_requires_exact_prior_start_and_preserves_status_and_order(self):
        console = '2026-10-29 11:46:01.775482+0000 App[100:200] [default] Error "(null)"'
        for newline in ("\n", "\r\n"):
            for status in ("passed", "failed", "skipped"):
                with self.subTest(newline=newline, status=status):
                    output = "Test Case '-[Module.Required testBefore]' passed (0.001 seconds)." + newline
                    output += "Test Case '-[Module.Required testSplitName]' started." + newline
                    output += f"Test Case '-[Module.Required testSplit{console}{newline}Name]' "
                    output += f"{status} (0.009 seconds).{newline}"
                    output += "Test Case 'Module.Required.testAfter' passed (0.001 seconds)." + newline
                    results = list(gate.case_results(output))
                    self.assertEqual([row["case"] for row in results], ["testBefore", "testSplitName", "testAfter"])
                    self.assertEqual(results[1], {"module": "Module", "suite": "Required",
                                                  "case": "testSplitName", "status": status})
                    self.assertEqual(bool(gate.coverage_errors(output, ["Required"])[0]), status != "passed")

    def test_method_splice_refuses_unstarted_foreign_examples_and_cross_record_abuse(self):
        console = '2026-10-29 11:46:01.775482+0000 App[100:200] [default] Error "(null)"'
        start = "Test Case '-[Module.Required testSplitName]' started.\n"
        terminal = f"Test Case '-[Module.Required testSplit{console}\nName]' passed (0.009 seconds).\n"
        invalid = (
            terminal, terminal + start,
            start.replace("Module.", "Other.") + terminal,
            start.replace("Required ", "Other ") + terminal,
            start.replace("testSplitName", "testOther") + terminal,
            start + terminal.replace(console, "arbitrary output"),
            start + terminal.replace("[100:200]", "[not:a-thread]"),
            start + terminal.replace('"(null)"', '"unbalanced'),
            start + 'example: ' + terminal,
            start + 'print("' + terminal.rstrip("\n") + '")\n',
            start + terminal.replace(console, console + " 'quoted example'"),
            start + terminal.replace("\nName", "\nextra\nName"),
            start + terminal.replace("\nName", "\n" + console + "\nName"),
            start + terminal.replace("\nName", "\rName"),
            start + terminal.replace('"(null)"', '"(null)\r"'),
            start + terminal.replace('"(null)"', '"(null)\n"'),
            start + terminal.replace("\nName", "\n"),
            start + terminal.replace("(0.009 seconds).", ""),
            start + terminal.replace("(0.009 seconds).", "(nan seconds)."),
            start + terminal.replace("(0.009 seconds).", "(-0.009 seconds)."),
            start + terminal.replace("(0.009 seconds).", "(0.009 seconds). trailing text"),
            start + terminal.replace("' passed", "' started"),
            start + terminal.replace(console, console + "x" * 4097),
        )
        for output in invalid:
            with self.subTest(output=output):
                self.assertEqual(list(gate.method_spliced_results(output)), [])
                self.assertTrue(gate.coverage_errors(output, ["Required"])[0])

    def test_quoted_console_terminal_requires_prior_start_and_preserves_order_and_status(self):
        prefix = ('2026-10-29 02:08:30.244431+0000 JustSpeakToIt[100:200] [default] '
                  'Error Domain=LSApplicationWorkspaceErrorDomain Code=115 "(null)" '
                  'UserInfo={_LSFile=LSDOpenService.mm, _LSLine=282, _LSFunc')
        for newline in ("\n", "\r\n"):
            for status in ("passed", "failed", "skipped"):
                with self.subTest(newline=newline, status=status):
                    output = "Test Case '-[Module.Required testBefore]' passed (0.001 seconds)." + newline
                    output += "Test Case '-[Module.Required testQuoted]' started." + newline
                    output += prefix + f"Test Case '-[Module.Required testQuoted]' {status} (0.003 seconds)." + newline
                    output += "tion=-[_LSDOpenClient openURL:fileHandle:options:completionHandler:]}" + newline
                    output += "Test Case 'Module.Required.testAfter' passed (0.001 seconds)." + newline
                    cases = list(gate.case_results(output))
                    self.assertEqual([case["case"] for case in cases], ["testBefore", "testQuoted", "testAfter"])
                    self.assertEqual(cases[1], {"module": "Module", "suite": "Required",
                                               "case": "testQuoted", "status": status})
                    errors, counts = gate.coverage_errors(output, ["Required"])
                    self.assertEqual(counts["Required"][status], 3 if status == "passed" else 1)
                    self.assertEqual(bool(errors), status != "passed")

    def test_quoted_console_terminal_needs_an_earlier_exact_full_apple_identity(self):
        prefix = '2026-10-29 02:08:30.244431+0000 App[100:200] [default] Error "(null)" '
        terminal = prefix + "Test Case '-[Module.Required testQuoted]' passed (0.003 seconds).\n"
        start = "Test Case '-[Module.Required testQuoted]' started.\n"
        for before, after in (("", ""), ("", start), (start.replace("Module.", "Other."), ""),
                              (start.replace("Required ", "Other "), ""),
                              (start.replace("testQuoted", "testOther"), ""),
                              (start.replace("Module.", ""), ""), (start.replace("started.", "started"), "")):
            with self.subTest(before=before, after=after):
                self.assertEqual(list(gate.case_results(before + terminal + after)), [])
        # A later duplicate start must not erase the earlier admission.
        self.assertEqual(len(list(gate.case_results(start + terminal + start))), 1)
        self.assertEqual(list(gate.case_results(start)), [])

    def test_quoted_console_recovery_rejects_examples_and_incomplete_physical_records(self):
        start = "Test Case '-[Module.Required testQuoted]' started.\n"
        prefix = '2026-10-29 02:08:30.244431+0000 App[100:200] [default] Error "(null)" '
        terminal = "Test Case '-[Module.Required testQuoted]' passed (0.003 seconds)."
        invalid = (prefix + '"example ' + terminal + '"', prefix + "'example " + terminal + "'",
                   "arbitrary prefix " + terminal, 'print("' + terminal + '")',
                   prefix.replace("[100:200]", "[not:a-thread]") + terminal,
                   prefix.replace('"(null)"', '"unterminated') + terminal,
                   prefix + terminal + " trailing text", prefix + terminal.removesuffix(" (0.003 seconds)."),
                   prefix + terminal.replace("testQuoted", "testQuoted\nextra"),
                   prefix + terminal.replace("Test Case", "Test Suite"),
                   prefix + terminal.replace("-[Module.Required testQuoted]", "Module.Required.testQuoted"))
        for record in invalid:
            with self.subTest(record=record):
                self.assertEqual(list(gate.case_results(start + record + "\n")), [])
                self.assertTrue(gate.coverage_errors(start + record + "\n", ["Required"])[0])

    def test_module_token_splice_preserves_status_identity_and_mixed_order(self):
        console = "2026-10-28 02:58:13.934192+0000 JustSpeakToIt[6608:33822] [api] Updating content"
        for newline in ("\n", "\r\n"):
            with self.subTest(newline=newline):
                output = "Test Case '-[Module.Required testBefore]' passed (0.001 seconds).\n"
                output += "".join(
                    f"Test Case '-[Mod{console}{newline}ule.Required test{status}]' "
                    f"{status} (0.001 seconds).{newline}" for status in ("passed", "failed", "skipped")
                )
                output += "Test Case 'Module.Required.testAfter' passed (0.001 seconds).\n"
                self.assertEqual(list(gate.case_results(output)), [
                    {"module": "Module", "suite": "Required", "case": method, "status": status}
                    for method, status in (("testBefore", "passed"), ("testpassed", "passed"),
                                           ("testfailed", "failed"), ("testskipped", "skipped"),
                                           ("testAfter", "passed"))
                ])
                errors, counts = gate.coverage_errors(output, ["Required"])
                self.assertTrue(errors)
                self.assertEqual(dict(counts["Required"]), {"passed": 3, "failed": 1, "skipped": 1})

    def test_module_token_splice_requires_typed_single_physical_console_record(self):
        console = "2026-10-28 02:58:13.934192+0000 JustSpeakToIt[6608:33822] [api] Updating content"
        valid = f"Test Case '-[Mod{console}\nule.Required testResult]' passed (0.001 seconds).\n"
        invalid = (
            valid.replace(console, "arbitrary-output"),
            valid.replace(console, "2026-10-28 not a typed console record"),
            valid.replace("[6608:33822]", "[not:a-thread]"),
            valid.replace(console, console + ' "quoted example"'),
            valid.replace("\nule.", "\nextra line\nule."),
            valid.replace("\nule.", "\rule."),
            valid.replace("-[Mod", "-["),
            valid.replace("\nule.", "\n."),
            valid.replace("Test Case", "example: Test Case"),
            valid.replace("testResult]", "testResult\nincomplete]"),
            valid.replace("testResult]", "testResult\rincomplete]"),
            valid.replace("(0.001 seconds).", ""),
            valid.replace("(0.001 seconds).", "(0.001 seconds). trailing text"),
            valid.replace("' passed", "' started"),
        )
        for output in invalid:
            with self.subTest(output=output):
                self.assertEqual(list(gate.case_results(output)), [])
                self.assertTrue(gate.coverage_errors(output, ["Required"])[0])
        # An arbitrary splice must never gain the reconstructed module/required
        # identity through either ordinary parsing or typed recovery.
        arbitrary = valid.replace(console, "arbitrary output")
        self.assertEqual(list(gate.MODULE_SPLICED_CASE_RESULT.finditer(arbitrary)), [])
        self.assertTrue(gate.coverage_errors(arbitrary, ["Required"])[0])

    def test_module_splice_does_not_recover_suite_heading_or_wrong_required_suite(self):
        console = "2026-10-28 02:58:13.934192+0000 JustSpeakToIt[6608:33822] [api] Updating content"
        for output in (f"Test Suite 'Mod{console}\nule.Required' passed (0.001 seconds).\n",
                       f"Executed 1 tests{console}\nule.Required testResult]' passed (0.001 seconds).\n",
                       f"Test Case '-[Mod{console}\nule.RequiredExtra testResult]' passed (0.001 seconds).\n"):
            with self.subTest(output=output):
                self.assertTrue(gate.coverage_errors(output, ["Required"])[0])

    def test_typed_console_splice_recovers_apple_identity_status_and_order(self):
        console = "2026-10-28 00:56:23.431664+0000 JustSpeakToIt[7390:29376] [api] Updating content"
        for newline in ("\n", "\r\n"):
            with self.subTest(newline=newline):
                output = "Test Case '-[Module.Required testBefore]' passed (0.001 seconds).\n"
                output += "".join(
                    f"Test Case '-[Module.Required test{status}]{console}{newline}"
                    f"' {status} (0.087 seconds).{newline}"
                    for status in ("passed", "failed", "skipped")
                )
                output += "Test Case 'Module.Required.testAfter' passed (0.001 seconds).\n"
                self.assertEqual(list(gate.case_results(output)), [
                    {"module": "Module", "suite": "Required", "case": method, "status": status}
                    for method, status in (("testBefore", "passed"), ("testpassed", "passed"),
                                           ("testfailed", "failed"), ("testskipped", "skipped"),
                                           ("testAfter", "passed"))
                ])
                errors, counts = gate.coverage_errors(output, ["Required"])
                self.assertTrue(errors)
                self.assertEqual(dict(counts["Required"]), {"passed": 3, "failed": 1, "skipped": 1})


    def test_splice_rejects_untyped_quoted_incomplete_and_extra_physical_records(self):
        console = "2026-10-28 00:56:23.431664+0000 JustSpeakToIt[7390:29376] [api] Updating content"
        valid = f"Test Case '-[Module.Required testResult]{console}\n' passed (0.087 seconds).\n"
        invalid = (
            valid.replace(console, "arbitrary output"),
            valid.replace(console, "2026-10-28 not a console record"),
            valid.replace(console, console + ' "quoted payload"'),
            valid.replace("\n' passed", "\nextra line\n' passed"),
            valid.replace("\n' passed", "\r' passed"),
            valid.replace("testResult]", "testResult\nnot a physical record]"),
            valid.replace("testResult]", "testResult\rnot a physical record]"),
            valid.replace("-[Module.Required testResult]", "Module.Required.testResult"),
            valid.replace("Test Case", "example: Test Case"),
            valid.replace("(0.087 seconds).", ""),
            valid.replace("(0.087 seconds).", "(0.087 seconds). trailing text"),
            valid.replace("' passed", "' started"),
        )
        for output in invalid:
            with self.subTest(output=output):
                self.assertEqual(list(gate.case_results(output)), [])
                self.assertTrue(gate.coverage_errors(output, ["Required"])[0])


    def test_spliced_suite_or_summary_cannot_replace_required_case(self):
        console = "2026-10-28 00:56:23.431664+0000 JustSpeakToIt[7390:29376] [api] Updating content"
        for output in (f"Test Suite 'Required{console}\n' passed (0.087 seconds).\n",
                       f"Executed 1 tests{console}\n' passed (0.087 seconds).\n",
                       f"Test Case '-[Module.RequiredExtra testResult]{console}\n' passed (0.087 seconds).\n"):
            with self.subTest(output=output):
                self.assertTrue(gate.coverage_errors(output, ["Required"])[0])


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



class BuildObservationTests(unittest.TestCase):
    def test_projection_exports_only_complete_bounded_progress_and_closed_phases(self):
        project = gate.BuildProgressObserver.project_progress
        for action, phase in ((b"Compiling ", "compiling"), (b"Emitting module ", "emittingModule"),
                              (b"Linking ", "linking"), (b"Copying ", "copying"),
                              (b"Wrapping AST ", "wrappingAST"), (b"PRIVATE-action ", "other")):
            with self.subTest(phase=phase):
                projected = project(b"[12/34] " + action + b"PRIVATE-path-secret-\xff\r\n", 0)
                self.assertEqual(projected, {"completed": 12, "total": 34, "phase": phase})
                self.assertNotIn("PRIVATE", json.dumps(projected))
        for raw in (b"[1/2] Compiling PRIVATE", b"'[1/2] Compiling PRIVATE'\n",
                    b"example: [1/2] Compiling PRIVATE\n", b"[3/2] Compiling PRIVATE\n",
                    b"[1/0] Compiling PRIVATE\n", b"[1/1000001] Compiling PRIVATE\n",
                    b"[10000000/10000000] Compiling PRIVATE\n", b"[x/2] Compiling PRIVATE\n"):
            with self.subTest(raw=raw):
                self.assertIsNone(project(raw, 0))
        self.assertIsNone(project(b"[1/2] Compiling PRIVATE\n", 10), "The cut first edge is not a record")
        self.assertEqual(project(b"cut\n[1/2] Compiling PRIVATE\n[2/2] Linking incomplete", 10),
                         {"completed": 1, "total": 2, "phase": "compiling"})

    def test_observations_use_monotonic_sample_time_and_byte_growth_not_line_timestamps(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "test.log"
            log.write_bytes(b"[1/2] Compiling PRIVATE\n")
            with mock.patch.object(gate.time, "monotonic", side_effect=[10, 15, 14, 20]):
                observer = gate.BuildProgressObserver(log)
                with log.open("rb") as stream:
                    self.assertTrue(observer.sample(stream.fileno()))
                    with log.open("ab") as writer:
                        writer.write(b"[2/2] Linking PRIVATE\n")
                    self.assertTrue(observer.sample(stream.fileno()))
                    self.assertTrue(observer.sample(stream.fileno()))
            observer.finish(Path(directory))
            payload = json.loads((Path(directory) / "progress.json").read_text())
            self.assertEqual([x["elapsedMilliseconds"] for x in payload["samples"]], [5000, 5000, 10000])
            self.assertEqual([x["logGrowth"] for x in payload["samples"]], [False, True, False])
            self.assertFalse(payload["compilerActivityObserved"])
            self.assertEqual(payload["timeOrigin"], "observerBootstrap")
            self.assertNotIn("PRIVATE", json.dumps(payload))

    def test_read_attempt_and_json_caps_are_independent_of_log_size(self):
        observer = gate.BuildProgressObserver(Path("unused"))
        pause = mock.Mock()
        with mock.patch.object(gate.os, "open", return_value=9), \
                mock.patch.object(gate.os, "fstat", return_value=mock.Mock(st_size=2 ** 40, st_mode=0o100600)), \
                mock.patch.object(gate.os, "pread", side_effect=lambda fd, count, offset: b"x" * count) as read, \
                mock.patch.object(gate.os, "close") as close, \
                mock.patch.object(gate.threading, "Event", return_value=pause):
            observer.run()
        self.assertEqual(read.call_count, 192)
        self.assertEqual(sum(call.args[1] for call in read.call_args_list), 3 * 1024 * 1024)
        self.assertTrue(all(call.args[1] <= 16 * 1024 for call in read.call_args_list))
        self.assertTrue(all(x["tailTruncated"] for x in observer.samples))
        self.assertTrue(all(call.args == (5,) for call in pause.wait.call_args_list))
        close.assert_called_once_with(9)
        with tempfile.TemporaryDirectory() as directory:
            observer.finish(Path(directory))
            output = (Path(directory) / "progress.json").read_bytes()
            self.assertLessEqual(len(output), 64 * 1024)
            payload = json.loads(output)
            self.assertTrue(payload["sampleCapReached"])
            self.assertEqual(payload["reservedReadBytes"], 3 * 1024 * 1024)
            self.assertTrue(payload["workerExitObserved"])

    def test_partial_read_error_keeps_reservation_and_never_exports_error_text(self):
        observer = gate.BuildProgressObserver(Path("unused"))
        observer.maximum_total_read = observer.remaining = 16
        with mock.patch.object(gate.os, "fstat", return_value=mock.Mock(st_size=9, st_mode=0o100600)), \
                mock.patch.object(gate.os, "pread", side_effect=OSError("PRIVATE-path-token")) as read:
            with self.assertRaises(OSError):
                observer.sample(9)
        self.assertEqual(observer.remaining, 7)
        self.assertEqual(read.call_args.args[1], 9)
        with mock.patch.object(gate.os, "fstat", return_value=mock.Mock(st_size=9, st_mode=0o100600)), \
                mock.patch.object(gate.os, "pread", side_effect=lambda fd, count, offset: b"x" * count) as read:
            self.assertTrue(observer.sample(9))
            self.assertFalse(observer.sample(9))
        self.assertEqual(read.call_count, 1)
        self.assertEqual(read.call_args.args[1], 7)
        self.assertEqual(observer.remaining, 0)
        failed = gate.BuildProgressObserver(Path("unused"))
        with mock.patch.object(gate.os, "open", side_effect=OSError("PRIVATE-path-token")):
            failed.run()
        with tempfile.TemporaryDirectory() as directory:
            failed.finish(Path(directory))
            output = (Path(directory) / "progress.json").read_text()
            self.assertNotIn("PRIVATE", output)
            self.assertEqual(json.loads(output)["readStatus"], "unavailable")

    def test_worker_does_not_hold_snapshot_lock_during_file_io_and_owns_close(self):
        observer = gate.BuildProgressObserver(Path("unused"))

        def read(fd, count, offset):
            self.assertTrue(observer.lock.acquire(blocking=False))
            observer.lock.release()
            observer.stopped = True
            return b"[1/2] Compiling PRIVATE\n"

        with mock.patch.object(gate.os, "open", return_value=9), \
                mock.patch.object(gate.os, "fstat", return_value=mock.Mock(st_size=26, st_mode=0o100600)), \
                mock.patch.object(gate.os, "pread", side_effect=read), \
                mock.patch.object(gate.os, "close") as close, \
                mock.patch.object(gate.threading, "Event"):
            observer.run()
        close.assert_called_once_with(9)
        self.assertTrue(observer.exited)

    def test_nonregular_or_replaced_log_is_refused_before_reading(self):
        for mode, device, inode in ((0o010600, 1, 2), (0o100600, 3, 2), (0o100600, 1, 3)):
            with self.subTest(mode=mode, device=device, inode=inode):
                observer = gate.BuildProgressObserver(Path("unused"), (1, 2))
                metadata = mock.Mock(st_mode=mode, st_dev=device, st_ino=inode, st_size=9)
                with mock.patch.object(gate.os, "fstat", return_value=metadata), \
                        mock.patch.object(gate.os, "pread") as read:
                    with self.assertRaises(ValueError):
                        observer.sample(9)
                read.assert_not_called()

    def test_busy_snapshot_never_waits_or_requires_worker_exit(self):
        observer = gate.BuildProgressObserver(Path("unused"))
        with tempfile.TemporaryDirectory() as directory:
            with observer.lock:
                observer.finish(Path(directory))
            payload = json.loads((Path(directory) / "progress.json").read_text())
        self.assertEqual(payload["snapshotStatus"], "lockBusy")
        self.assertEqual(payload["readStatus"], "unknown")
        self.assertIsNone(payload["samples"])
        self.assertFalse(payload["workerExitObserved"])
        self.assertTrue(observer.stopped)

    def test_blocked_read_cannot_block_snapshot_and_is_released_by_owned_cleanup(self):
        import threading
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "test.log"
            log.write_bytes(b"[1/2] Compiling PRIVATE\n")
            observer = gate.BuildProgressObserver(log)
            entered, release = threading.Event(), threading.Event()
            original = gate.os.pread

            def held_read(*args):
                entered.set()
                if not release.wait(2):
                    raise OSError("owned fixture release absent")
                return original(*args)

            worker = threading.Thread(target=observer.run, daemon=True)
            with mock.patch.object(gate.os, "pread", side_effect=held_read):
                try:
                    worker.start()
                    self.assertTrue(entered.wait(2))
                    observer.finish(Path(directory))
                    payload = json.loads((Path(directory) / "progress.json").read_text())
                    self.assertFalse(payload["workerExitObserved"])
                    self.assertEqual(payload["samples"], [])
                finally:
                    release.set()
                    worker.join(2)  # Only this fixture joins; the production owner never does.
            self.assertFalse(worker.is_alive())
            self.assertTrue(observer.exited)

    def test_observer_thread_is_daemon_and_diagnostic_write_failure_is_optional(self):
        observer = gate.BuildProgressObserver(Path("unused"))
        with mock.patch.object(gate.threading, "Thread") as thread:
            observer.start()
        self.assertTrue(thread.call_args.kwargs["daemon"])
        thread.return_value.start.assert_called_once_with()
        thread.return_value.join.assert_not_called()
        with mock.patch.object(Path, "write_text", side_effect=OSError("PRIVATE-path-token")):
            observer.finish(Path("unused"))
        self.assertTrue(observer.stopped)

    def run_fake_command(self, outcome=0, stage="build", command=None, observer_start_error=None):
        events = []
        process = mock.Mock(pid=123)
        process.poll.return_value = None if isinstance(outcome, BaseException) else outcome
        process.wait.side_effect = outcome if isinstance(outcome, BaseException) else None
        process.wait.return_value = outcome
        observer = mock.Mock()
        observer.start.side_effect = observer_start_error
        observer.finish.side_effect = lambda directory: events.append("observer-finish")

        def launch(*args, **kwargs):
            events.append("popen")
            self.assertEqual(kwargs["start_new_session"], True)
            self.assertEqual(kwargs["stderr"], subprocess.STDOUT)
            return process

        def stop(owned):
            self.assertIs(owned, process)
            events.append("kill-reap")
            process.poll.return_value = 0

        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(gate.subprocess, "Popen", side_effect=launch), \
                mock.patch.object(gate, "stop_process_group", side_effect=stop), \
                mock.patch.object(gate.BuildProgressObserver, "start", side_effect=observer.start), \
                mock.patch.object(gate.BuildProgressObserver, "finish", side_effect=observer.finish), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = gate.run_gate(command or list(gate.BuildProgressObserver.command), directory, 7, [], stage)
            result = json.loads((Path(directory) / "result.json").read_text())
        process.wait.assert_called_once_with(timeout=7)
        return code, result, events, observer

    def test_timeout_and_interruption_kill_reap_before_optional_snapshot(self):
        for error, expected in ((subprocess.TimeoutExpired("fixture", 7), 124), (InterruptedError("fixture"), 1)):
            with self.subTest(expected=expected):
                code, result, events, observer = self.run_fake_command(error)
                self.assertEqual(code, expected)
                self.assertEqual(result["exit_code"], expected)
                self.assertEqual(events, ["popen", "kill-reap", "observer-finish"])
                observer.start.assert_called_once_with()

    def test_exact_build_admission_preserves_success_failure_and_startup_failure(self):
        for outcome in (0, 17):
            for startup_error in (None, RuntimeError("PRIVATE-path-token")):
                with self.subTest(outcome=outcome, startup_error=startup_error):
                    code, result, events, _ = self.run_fake_command(outcome, observer_start_error=startup_error)
                    self.assertEqual(code, outcome)
                    self.assertEqual(result["exit_code"], outcome)
                    self.assertEqual(events[-1], "observer-finish")
                    self.assertNotIn("PRIVATE", json.dumps(result))
        for stage, command in (("test", None), ("build", ["swift", "build"]),
                               ("build", ["/private/swift", "build", "--build-tests", "--enable-code-coverage"])):
            with self.subTest(stage=stage, command=command):
                _, _, _, observer = self.run_fake_command(stage=stage, command=command)
                observer.start.assert_not_called()
                observer.finish.assert_not_called()

    def test_snapshot_setup_failure_does_not_replace_original_gate_outcome(self):
        with mock.patch.object(gate.BuildProgressObserver, "finish", side_effect=RuntimeError("PRIVATE-snapshot")):
            for expected in (0, 17):
                with tempfile.TemporaryDirectory() as directory, \
                        mock.patch.object(gate.BuildProgressObserver, "start"), \
                        mock.patch.object(gate.subprocess, "Popen") as launch, \
                        contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    launch.return_value.wait.return_value = expected
                    launch.return_value.poll.return_value = expected
                    code = gate.run_gate(list(gate.BuildProgressObserver.command), directory, 7, [], "build")
                    result = json.loads((Path(directory) / "result.json").read_text())
                self.assertEqual(code, expected)
                self.assertEqual(result["exit_code"], expected)
                self.assertNotIn("PRIVATE", json.dumps(result))

    def test_launch_failure_stops_observer_after_original_command_timing(self):
        events = []
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(gate.BuildProgressObserver, "start"), \
                mock.patch.object(gate.BuildProgressObserver, "finish", side_effect=lambda path: events.append("finish")), \
                mock.patch.object(gate.subprocess, "Popen", side_effect=OSError("fixture launch")), \
                mock.patch.object(gate, "stop_process_group") as stop, \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = gate.run_gate(list(gate.BuildProgressObserver.command), directory, 7, [], "build")
            result = json.loads((Path(directory) / "result.json").read_text())
        self.assertEqual(code, 1)
        self.assertIsNotNone(result["command_elapsed_seconds"])
        self.assertEqual(events, ["finish"])
        stop.assert_not_called()

    def test_build_timing_excludes_bootstrap_and_finish_follows_both_timing_captures(self):
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(gate.time, "monotonic", side_effect=[0, 1, 10, 10.1, 20]) as clock, \
                mock.patch.object(gate.BuildProgressObserver, "start"), \
                mock.patch.object(gate.BuildProgressObserver, "finish") as finish, \
                mock.patch.object(gate.subprocess, "Popen") as launch, \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            launch.return_value.wait.return_value = 0
            launch.return_value.poll.return_value = 0
            finish.side_effect = lambda path: self.assertEqual(clock.call_count, 5)
            command = list(gate.BuildProgressObserver.command)
            code = gate.run_gate(command, directory, 7, [], "build")
            result = json.loads((Path(directory) / "result.json").read_text())
        self.assertEqual(code, 0)
        self.assertAlmostEqual(result["command_elapsed_seconds"], 0.1)
        self.assertEqual(result["elapsed_seconds"], 20)
        self.assertEqual(launch.call_args.args[0], command)
        launch.return_value.wait.assert_called_once_with(timeout=7)


if __name__ == "__main__":
    unittest.main()
