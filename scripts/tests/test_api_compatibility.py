#!/usr/bin/env python3
"""Exercise the actual API gate with real Git trees and a bounded Swift double."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "check-api-compatibility.sh"
EXISTING_PRODUCTS = ["SpeakCore", "SpeakSync", "SpeakiOSLib", "SpeakHotKeys", "SpeakAutomationKit"]
MANIFEST = "// swift-tools-version: 5.9\n// SpeakWatchCore is mentioned, but this is not a product declaration.\n"


class APICompatibilityTests(unittest.TestCase):
    def run_gate(self, products=None, raw_json=None, dump_status=0, diagnose_status=0,
                 diagnostic="Compatible", title="fix: preserve API", missing_baseline=False):
        with tempfile.TemporaryDirectory(prefix="api gate ") as directory:
            root = Path(directory)
            repository = root / "repository"
            repository.mkdir()
            subprocess.run(["git", "init", "-q", str(repository)], check=True, capture_output=True)
            blob = subprocess.check_output(
                ["git", "hash-object", "-w", "--stdin"], cwd=repository, input=MANIFEST, text=True
            ).strip()
            resources = subprocess.check_output(
                ["git", "mktree"], cwd=repository, input=f"100644 blob {blob}\tSound.caf\n", text=True
            ).strip()
            # A real baseline tree, with no commits, hooks or repository build.
            baseline = subprocess.check_output(
                ["git", "mktree"], cwd=repository,
                input=f"100644 blob {blob}\tPackage.swift\n040000 tree {resources}\tResources\n", text=True
            ).strip()
            if missing_baseline:
                baseline = "missing-baseline"
            # The working tree deliberately differs, so reading its manifest
            # instead of the baseline is detected by the Swift double.
            (repository / "Package.swift").write_text("wrong current manifest")
            binaries = root / "bin"
            binaries.mkdir()
            swift = binaries / "swift"
            swift.write_text(f"#!{sys.executable}\n" + textwrap.dedent("""\
                import json
                import os
                from pathlib import Path
                import sys

                args = sys.argv[1:]
                call = {"arguments": args}
                if args[:3] == ["package", "diagnose-api-breaking-changes", os.environ["EXPECTED_BASELINE"]]:
                    result = Path(os.environ["DIAGNOSTIC_PATH"]).read_text()
                    status = int(os.environ["DIAGNOSE_STATUS"])
                elif len(args) == 4 and args[:2] == ["package", "--package-path"] and args[3] == "dump-package":
                    package = Path(args[2])
                    call["manifest"] = (package / "Package.swift").read_text()
                    call["directory"] = str(package)
                    call["entries"] = sorted(
                        str(path.relative_to(package)) for path in package.rglob("*")
                        if path.name not in ("Package.swift", "package.json")
                    )
                    result = os.environ["DUMP_JSON"]
                    status = int(os.environ["DUMP_STATUS"])
                else:
                    raise SystemExit("Unexpected Swift command: " + repr(args))
                with open(os.environ["CALLS"], "a", encoding="utf-8") as stream:
                    stream.write(json.dumps(call) + "\\n")
                print(result)
                raise SystemExit(status)
            """))
            swift.chmod(0o755)
            calls_file = root / "calls.jsonl"
            diagnostic_file = root / "diagnostic.txt"
            diagnostic_file.write_text(diagnostic)
            if raw_json is None:
                raw_json = json.dumps({"products": [{"name": name} for name in (products or EXISTING_PRODUCTS)]})
            environment = {
                **os.environ,
                "PATH": str(binaries) + os.pathsep + os.environ["PATH"],
                "TMPDIR": str(root),
                "EXPECTED_BASELINE": baseline,
                "CALLS": str(calls_file),
                "DUMP_JSON": raw_json,
                "DUMP_STATUS": str(dump_status),
                "DIAGNOSE_STATUS": str(diagnose_status),
                "DIAGNOSTIC_PATH": str(diagnostic_file),
                "PR_TITLE": title,
            }
            result = subprocess.run(
                ["bash", str(SCRIPT), baseline], cwd=repository, env=environment,
                capture_output=True, text=True, timeout=10
            )
            calls = [json.loads(line) for line in calls_file.read_text().splitlines()] if calls_file.exists() else []
            for call in calls:
                if "directory" in call:
                    self.assertEqual(call["manifest"], MANIFEST, "must evaluate the actual baseline manifest")
                    self.assertFalse(Path(call["directory"]).exists(), "disposable manifest must be removed")
            return result, calls

    def assert_products(self, calls, expected):
        arguments = calls[-1]["arguments"]
        self.assertEqual(arguments[:2], ["package", "diagnose-api-breaking-changes"])
        self.assertEqual(arguments[3:], [item for name in expected for item in ("--products", name)])

    def test_absent_product_is_skipped_without_weakening_existing_coverage(self):
        result, calls = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Baseline has no SpeakWatchCore product", result.stdout)
        self.assert_products(calls, EXISTING_PRODUCTS)

    def test_baseline_directories_are_recreated_empty_for_manifest_evaluation(self):
        result, calls = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call["entries"] for call in calls if "entries" in call], [["Resources"]])

    def test_present_product_is_compared(self):
        result, calls = self.run_gate(products=EXISTING_PRODUCTS + ["SpeakWatchCore"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_products(calls, EXISTING_PRODUCTS + ["SpeakWatchCore"])

    def test_similarly_named_product_does_not_count(self):
        result, calls = self.run_gate(products=EXISTING_PRODUCTS + ["SpeakWatchCoreTests", "SpeakWatchCoreExtra"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_products(calls, EXISTING_PRODUCTS)

    def test_watch_break_requires_existing_conventional_marker(self):
        for title, expected in [("fix: remove API", 1), ("chore!: relocate API", 0),
                                ("refactor(watch)!: relocate API", 0)]:
            with self.subTest(title=title):
                result, calls = self.run_gate(
                    products=EXISTING_PRODUCTS + ["SpeakWatchCore"], diagnose_status=1,
                    diagnostic="API breakage: removed WatchCaptureEnvelope", title=title
                )
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assertIn("API breakage: removed WatchCaptureEnvelope", result.stdout)
                self.assert_products(calls, EXISTING_PRODUCTS + ["SpeakWatchCore"])

    def test_other_removals_still_fail_when_watch_product_is_new(self):
        result, calls = self.run_gate(diagnose_status=1, diagnostic="API breakage: removed unrelated SpeakSync API")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assert_products(calls, EXISTING_PRODUCTS)

    def test_missing_baseline_manifest_refuses_to_diagnose_even_with_marker(self):
        result, calls = self.run_gate(missing_baseline=True, title="chore!: declared migration")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])
        self.assertIn("Unable to read baseline Package.swift", result.stderr)

    def test_dump_failure_refuses_to_diagnose_even_with_valid_json_and_marker(self):
        result, calls = self.run_gate(dump_status=2, title="chore!: declared migration")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 1)
        self.assertIn("Unable to evaluate baseline package products", result.stderr)

    def test_invalid_json_or_product_list_refuses_to_diagnose(self):
        for raw_json in ["not JSON", "null", "[]", "{}", '{"products":null}', '{"products":{}}',
                         '{"products":["SpeakWatchCore"]}', '{"products":[{}]}',
                         '{"products":[{"name":42}]}', '{"products":[{"name":""}]}',
                         '{"products":[{"name":"SpeakCore"},{"name":"SpeakCore"}]}',
                         '{"products":[{"name":"SpeakWatchCore"}],"products":[]}',
                         '{"products":[{"name":"SpeakWatchCore","name":"Other"}]}',
                         '{"products":[],"unexpected":NaN}']:
            with self.subTest(raw_json=raw_json):
                result, calls = self.run_gate(raw_json=raw_json, title="chore!: declared migration")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(calls), 1)
                self.assertIn("Unable to establish baseline API coverage", result.stderr)

    def test_diagnose_tool_failure_is_not_excused_by_breaking_marker(self):
        result, calls = self.run_gate(
            products=EXISTING_PRODUCTS + ["SpeakWatchCore"], diagnose_status=17,
            diagnostic="error: compiler could not load the module", title="chore!: declared migration"
        )
        self.assertEqual(result.returncode, 17)
        self.assert_products(calls, EXISTING_PRODUCTS + ["SpeakWatchCore"])
        self.assertIn("failed to run", result.stderr)


    def test_mixed_findings_and_tool_failure_are_never_waived(self):
        failures = [
            "error: compiler could not load the module",
            "/tmp/Module.swift:3:7: error: cannot find type Missing in scope",
            "error: failed to read API digester output for SpeakWatchCore",
            "swift-api-digester: fatal error: failed to load module",
            "\x1b[31merror:\x1b[0m no such product SpeakWatchCore",
        ]
        for status in [1, 17]:
            for failure in failures:
                with self.subTest(status=status, failure=failure):
                    result, calls = self.run_gate(
                        products=EXISTING_PRODUCTS + ["SpeakWatchCore"], diagnose_status=status,
                        diagnostic="  💔 API breakage: removed WatchCaptureEnvelope\n" + failure,
                        title="chore!: declared migration"
                    )
                    self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                    self.assert_products(calls, EXISTING_PRODUCTS + ["SpeakWatchCore"])
                    self.assertNotIn("allowing the declared migration", result.stdout)

    def test_abnormal_status_with_findings_alone_is_not_a_completed_comparison(self):
        result, _ = self.run_gate(diagnose_status=17,
                                  diagnostic="API breakage: removed WatchCaptureEnvelope",
                                  title="chore!: declared migration")
        self.assertEqual(result.returncode, 17, result.stdout + result.stderr)

    def test_mixed_tool_failure_is_not_hidden_by_additive_allowlist(self):
        allowed = "API breakage: enumelement StreamingClientError.transportStalled has been added as a new enum case"
        result, _ = self.run_gate(diagnose_status=1,
                                  diagnostic=allowed + "\nerror: failed to read API digester output for SpeakWatchCore")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertNotIn("No unreviewed public API breakage", result.stdout)

    def test_reviewed_speech_enum_additions_pass_without_a_breaking_marker(self):
        symbols = [
            "LiveTranscriptionProviderID.alibaba", "LiveTranscriptionProviderID.reson8",
            "AnalyticsProviderType.alibaba", "AnalyticsProviderType.smallest",
            "AnalyticsProviderType.reson8", "AnalyticsProviderType.stepfun",
            "OpenRouterInlineAudioTranscriptionClient.InputError.inklingAudioLimit",
            "ConfigTransferError.compressionFailed", "ConfigTransferError.payloadTooLarge",
            "DictationProfileMatcher.Kind.linuxExecutablePath", "GroqTTSAPIError.excessiveFanOut",
            "ApplicationPreferenceKey.mistralTTSModel", "MistralTTSModel.voxtralMiniTTS3",
        ]
        diagnostic = "\n".join(
            f"  💔 API breakage: enumelement {symbol} has been added as a new enum case"
            for symbol in symbols
        )
        result, _ = self.run_gate(diagnose_status=1, diagnostic=diagnostic)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("No unreviewed public API breakage", result.stdout)
        self.assertNotIn("allowing the declared migration", result.stdout)

    def test_speech_addition_allowlist_does_not_allow_removals_or_unknown_cases(self):
        allowed = "API breakage: enumelement ConfigTransferError.payloadTooLarge has been added as a new enum case"
        for finding in [
            "API breakage: enumelement ConfigTransferError.payloadTooLarge has been removed",
            "API breakage: enumelement ConfigTransferError.unreviewed has been added as a new enum case",
            "API breakage: func seal() has been removed",
        ]:
            with self.subTest(finding=finding):
                result, _ = self.run_gate(diagnose_status=1, diagnostic=allowed + "\n" + finding)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(finding, result.stderr)

    def test_linux_and_groq_allowlist_entries_do_not_allow_removals_or_unknown_cases(self):
        allowed = "API breakage: enumelement GroqTTSAPIError.excessiveFanOut has been added as a new enum case"
        for finding in [
            "API breakage: enumelement DictationProfileMatcher.Kind.linuxExecutablePath has been removed",
            "API breakage: enumelement GroqTTSAPIError.unknownCase has been added as a new enum case",
        ]:
            with self.subTest(finding=finding):
                result, _ = self.run_gate(diagnose_status=1, diagnostic=allowed + "\n" + finding)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(finding, result.stderr)

        # A tool-error diagnostic line (not an "API breakage:" finding) takes
        # the early tool-error path: the raw diagnose output, including this
        # line, is echoed to stdout, while only the "tool error; comparison is
        # incomplete" summary goes to stderr. It must still fail non-zero and
        # never be waived as a successful comparison.
        tool_error = "error: failed to read API digester output for SpeakCore"
        result, _ = self.run_gate(diagnose_status=1, diagnostic=allowed + "\n" + tool_error)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(tool_error, result.stdout)
        self.assertIn("tool error; comparison is incomplete", result.stderr)
        self.assertNotIn("No unreviewed public API breakage", result.stdout)

    def test_voxtral_additions_do_not_allow_removals_or_unknown_cases(self):
        allowed = "\n".join(
            f"API breakage: enumelement {symbol} has been added as a new enum case"
            for symbol in ["ApplicationPreferenceKey.mistralTTSModel", "MistralTTSModel.voxtralMiniTTS3"]
        )
        for finding in [
            "API breakage: enumelement ApplicationPreferenceKey.mistralTTSModel has been removed",
            "API breakage: enumelement MistralTTSModel.voxtralMiniTTS3 has been removed",
            "API breakage: enumelement MistralTTSModel.unreviewed has been added as a new enum case",
        ]:
            with self.subTest(finding=finding):
                result, _ = self.run_gate(diagnose_status=1, diagnostic=allowed + "\n" + finding)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(finding, result.stderr)

    def test_diagnostic_words_in_findings_and_warnings_preserve_declared_migration(self):
        diagnostic = "\n".join([
            "/tmp/Module.swift:3:7: warning: this is an error in the Swift 6 language mode",
            "warning: previous diagnostic text was error: example only",
            "  💔 API breakage: func report(error:) has been removed",
            "  💔 API breakage: enum case describes error: failure has been removed",
        ])
        result, _ = self.run_gate(diagnose_status=1, diagnostic=diagnostic,
                                  title="refactor(watch)!: declared migration")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("allowing the declared migration", result.stdout)


if __name__ == "__main__":
    unittest.main()
