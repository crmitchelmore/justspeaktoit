"""Cold preparation, exact-product admission and runtime-budget contracts."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "run-core-journey-stages.py"
SPEC = importlib.util.spec_from_file_location("journey_stages", SCRIPT)
stages = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(stages)


def passing_ui_output():
    return "".join(
        f"Test Case '-[SpeakAppUITests.{suite} {case}]' passed (0.001 seconds).\n"
        for suite in stages.UI["REQUIRED_SUITES"]
        for case in stages.UI["REQUIRED_CASES"].get(suite, ("testJourney",))
    )


def cancellation_fixture_ready(log, owned):
    if not owned.is_file() or not log.is_file():
        return False
    return {"compiler started", "descendant started"} <= set(log.read_text().splitlines())


class CommandTests(unittest.TestCase):
    def test_swift_build_once_and_runtime_cannot_build_or_resolve_dependencies(self):
        self.assertEqual(
            stages.build_command("swift", Path("artifacts")),
            ["swift", "build", "--build-tests", "--enable-code-coverage"],
        )
        command = stages.test_command("swift", Path("artifacts"))
        self.assertEqual(command[:4], ["swift", "test", "--skip-build", "--disable-automatic-resolution"])
        self.assertEqual(command[4:], [
            "--enable-code-coverage", "--filter", "|".join(f"{s}/" for s in stages.GATE["REQUIRED_SUITES"]),
        ])
        self.assertEqual(len(stages.GATE["REQUIRED_SUITES"]), 16)

    def test_ui_uses_same_built_manifest_destination_and_all_five_suites(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            manifest = directory / "DerivedData/Build/Products/SpeakApp_macosx.xctestrun"
            manifest.parent.mkdir(parents=True)
            manifest.write_text("synthetic manifest")
            build = stages.build_command("ui", directory)
            runtime = stages.test_command("ui", directory)
            self.assertEqual(build[:2], ["xcodebuild", "build-for-testing"])
            for option, value in [
                ("-workspace", "Just Speak to It.xcworkspace"), ("-scheme", "SpeakApp"),
                ("-configuration", "Debug"), ("-destination", "platform=macOS"),
                ("-derivedDataPath", str(directory / "DerivedData")),
            ]:
                self.assertEqual(build[build.index(option) + 1], value)
            self.assertEqual(runtime[:4], ["xcodebuild", "test-without-building", "-xctestrun", str(manifest)])
            self.assertEqual(runtime[runtime.index("-destination") + 1], "platform=macOS")
            self.assertEqual(runtime[runtime.index("-derivedDataPath") + 1], str(directory / "DerivedData"))
            self.assertNotIn("-workspace", runtime)
            self.assertNotIn("-scheme", runtime)
            self.assertIn("-disableAutomaticPackageResolution", runtime)
            self.assertIn("-skipPackageUpdates", runtime)
            self.assertEqual(len(stages.ui_selection()), 5)
            for argument in stages.ui_selection() + [
                "-skipPackagePluginValidation", "CODE_SIGN_IDENTITY=-",
                "DEVELOPMENT_TEAM=", "CODE_SIGN_STYLE=Manual",
            ]:
                self.assertIn(argument, build)
                self.assertIn(argument, runtime)
            self.assertEqual(runtime[runtime.index("-resultBundlePath") + 1],
                             str(directory / "CoreJourneyFixture.xcresult"))

    def test_missing_or_ambiguous_ui_manifest_is_not_an_implicit_build(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            with self.assertRaisesRegex(ValueError, "missing or ambiguous"):
                stages.test_command("ui", directory)
            products = directory / "DerivedData/Build/Products"
            products.mkdir(parents=True)
            for name in ["first", "second"]:
                (products / f"{name}.xctestrun").touch()
            with self.assertRaises(ValueError):
                stages.test_command("ui", directory)

    def test_command_budgets_are_finite_and_old_environment_cannot_extend_runtime(self):
        with mock.patch.dict(os.environ, {"CORE_JOURNEY_BUDGET_SECONDS": "999999"}):
            self.assertEqual(stages.RUNTIME_BUDGET, {"swift": 480, "ui": 600})
        self.assertEqual(stages.BUILD_BUDGET, 900)
        self.assertEqual(stages.SETUP_BUDGET, 300)
        self.assertEqual(stages.RECEIPT_BUDGET, 60)

    def test_tuist_setup_is_bounded_and_keeps_original_generation_options(self):
        with mock.patch.dict(stages.GATE, {"run_gate": mock.Mock(return_value=17)}):
            self.assertEqual(stages.setup(Path("artifacts")), 17)
            stages.GATE["run_gate"].assert_called_once_with(
                ["bash", "-c", "set -euo pipefail; brew install tuist; tuist generate --no-open"],
                Path("artifacts/setup"), 300, (), stage="setup",
            )


class IdentityTests(unittest.TestCase):
    def test_pr_uses_checked_out_merge_not_a_different_source_head(self):
        merge = "a" * 40
        with tempfile.TemporaryDirectory() as temp:
            original = Path.cwd()
            os.chdir(temp)
            self.addCleanup(os.chdir, original)
            Path("Package.resolved").write_text("pins")
            outputs = [merge, "", "Apple Swift version test", "Xcode test", "macOS test"]
            with mock.patch.dict(os.environ, {"GITHUB_SHA": merge}):
                with mock.patch.object(stages, "checked_output", side_effect=outputs):
                    receipt = stages.identity("swift", time.monotonic() + 60)
                self.assertEqual(receipt["revision"], merge)
            with mock.patch.dict(os.environ, {"GITHUB_SHA": "b" * 40}):
                with mock.patch.object(stages, "checked_output", return_value=merge):
                    with self.assertRaisesRegex(ValueError, "GITHUB_SHA"):
                        stages.identity("swift", time.monotonic() + 60)

    def test_dirty_source_or_non_apple_toolchain_is_rejected(self):
        for outputs, error in [
            (["a" * 40, " M Package.swift"], "Tracked source"),
            (["a" * 40, "", "Swift version 6"], "Apple Swift"),
        ]:
            with mock.patch.dict(os.environ, {"GITHUB_SHA": "a" * 40}):
                with mock.patch.object(stages, "checked_output", side_effect=outputs):
                    with self.assertRaisesRegex(ValueError, error):
                        stages.identity("swift", time.monotonic() + 60)

    def test_receipt_subprocess_has_remaining_deadline_and_does_not_run_after_it(self):
        with mock.patch.object(stages.subprocess, "check_output", return_value="ok") as command:
            with mock.patch.object(stages.time, "monotonic", return_value=10):
                self.assertEqual(stages.checked_output(["tool"], 15), "ok")
            self.assertEqual(command.call_args.kwargs["timeout"], 5)
            with mock.patch.object(stages.time, "monotonic", return_value=16):
                with self.assertRaises(TimeoutError):
                    stages.checked_output(["tool"], 15)
            self.assertEqual(command.call_count, 1)


class StageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.artifacts = self.directory / "artifacts"
        self.artifacts.mkdir()
        self.product = self.artifacts / "DerivedData/Build/Products/SpeakApp_macosx.xctestrun"
        self.product.parent.mkdir(parents=True)
        self.product.write_text("synthetic products")
        self.identity = {"revision": "a" * 40, "swift": "Apple Swift", "workspace": str(self.directory)}

    def muted(self):
        stack = contextlib.ExitStack()
        stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
        stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
        return stack

    def prepare(self):
        command = [sys.executable, "-c", "print('synthetic build completed')"]
        with mock.patch.object(stages, "identity", return_value=self.identity):
            with mock.patch.object(stages, "build_command", return_value=command):
                with self.muted():
                    self.assertEqual(stages.prepare("ui", self.artifacts), 0)
        return command

    def test_successful_build_receipt_admits_only_unchanged_products_and_options(self):
        command = self.prepare()
        suites = stages.UI["REQUIRED_SUITES"]
        passing = passing_ui_output()
        runtime = [sys.executable, "-c", f"print({passing!r})"]
        with mock.patch.object(stages, "identity", return_value=self.identity):
            with mock.patch.object(stages, "build_command", return_value=command):
                with mock.patch.object(stages, "test_command", return_value=runtime):
                    with self.muted():
                        self.assertEqual(stages.execute("ui", self.artifacts), 0)
        result = json.loads((self.artifacts / "runtime/result.json").read_text())
        self.assertEqual(result["command"], runtime)
        self.assertEqual(result["budget_seconds"], 600)
        self.assertEqual(json.loads((self.artifacts / "source.json").read_text()), self.identity)
        coverage = json.loads((self.artifacts / "coverage.json").read_text())
        self.assertEqual(coverage["errors"], [])
        self.product.write_text("modified after successful build")
        with mock.patch.object(stages, "identity", return_value=self.identity):
            with mock.patch.object(stages, "build_command", return_value=command):
                with mock.patch.object(stages, "test_command") as run:
                    with self.assertRaisesRegex(ValueError, "Prepared products"):
                        stages.execute("ui", self.artifacts)
                    run.assert_not_called()

    def test_staged_ui_runtime_rejects_missing_or_duplicate_required_cases(self):
        command = self.prepare()
        passing = passing_ui_output()
        first = next(iter(stages.UI["REQUIRED_CASES"].values()))[0]
        required = next(line for line in passing.splitlines(keepends=True) if first in line)
        for output in (passing.replace(required, ""), passing + required):
            runtime = [sys.executable, "-c", f"print({output!r})"]
            with mock.patch.object(stages, "identity", return_value=self.identity), \
                    mock.patch.object(stages, "build_command", return_value=command), \
                    mock.patch.object(stages, "test_command", return_value=runtime), self.muted():
                self.assertEqual(stages.execute("ui", self.artifacts), 1)
            coverage = json.loads((self.artifacts / "coverage.json").read_text())
            self.assertTrue(coverage["errors"])
            receipt = json.loads((self.artifacts / "runtime/result.json").read_text())
            self.assertEqual(receipt["exit_code"], 1)
            self.assertTrue(receipt["errors"])
            self.assertEqual(coverage["required_cases"],
                             {suite: list(cases) for suite, cases in stages.UI["REQUIRED_CASES"].items()})

    def test_setup_failure_cannot_enter_ui_build_or_runtime(self):
        with mock.patch.object(stages, "artifact_directory", return_value=self.artifacts):
            with mock.patch.object(stages, "setup", return_value=17):
                with mock.patch.object(stages, "prepare") as build:
                    with mock.patch.object(stages, "execute") as runtime:
                        self.assertEqual(stages.main(["ui"]), 17)
        build.assert_not_called()
        runtime.assert_not_called()

    def test_cold_build_does_not_spend_runtime_budget(self):
        suites = stages.UI["REQUIRED_SUITES"]
        passing = passing_ui_output()
        clock = [0.0]
        durations = {"build": 458.35, "test": 30, "combined": 488.35}

        class Process:
            def __init__(self, command, stdout, **_):
                self.duration = durations[command[0]]
                self.returncode = None
                stdout.write(passing if command[0] != "build" else "cold build\n")

            def wait(self, timeout):
                clock[0] += min(timeout, self.duration)
                if self.duration > timeout:
                    raise subprocess.TimeoutExpired("synthetic command", timeout)
                self.returncode = 0
                return 0

            def poll(self):
                return self.returncode

        with self.muted(), contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(stages.time, "monotonic", side_effect=lambda: clock[0]))
            stack.enter_context(mock.patch.object(stages.GATE["subprocess"], "Popen", Process))
            stack.enter_context(mock.patch.dict(stages.GATE["run_gate"].__globals__, {
                "stop_process_group": lambda process: setattr(process, "returncode", -9),
            }))
            self.assertEqual(stages.GATE["run_gate"](
                ["combined"], self.artifacts / "old-combined", 480, suites
            ), 124)
            with mock.patch.object(stages, "identity", return_value=self.identity):
                with mock.patch.object(stages, "build_command", return_value=["build"]):
                    with mock.patch.object(stages, "test_command", return_value=["test"]):
                        self.assertEqual(stages.prepare("ui", self.artifacts), 0)
                        with mock.patch.dict(stages.RUNTIME_BUDGET, {"ui": 480}):
                            self.assertEqual(stages.execute("ui", self.artifacts), 0)
        build_result = json.loads((self.artifacts / "build/result.json").read_text())
        runtime_result = json.loads((self.artifacts / "runtime/result.json").read_text())
        self.assertEqual(build_result["budget_seconds"], 900)
        self.assertEqual(runtime_result["budget_seconds"], 480)
        self.assertGreater(build_result["command_elapsed_seconds"] + runtime_result["command_elapsed_seconds"], 480)
        self.assertEqual(runtime_result["errors"], [])

    def test_failed_skipped_or_timed_out_ui_runtime_cannot_publish_green_coverage(self):
        command = self.prepare()
        suites = stages.UI["REQUIRED_SUITES"]
        passing = passing_ui_output()
        for source, budget, expected in [
            (f"print({passing!r}); raise SystemExit(17)", 2, 17),
            (f"print({passing.replace('passed', 'skipped')!r})", 2, 1),
            ("import time; print('partial', flush=True); time.sleep(60)", 0.1, 124),
        ]:
            runtime = [sys.executable, "-c", source]
            with mock.patch.object(stages, "identity", return_value=self.identity):
                with mock.patch.object(stages, "build_command", return_value=command):
                    with mock.patch.object(stages, "test_command", return_value=runtime):
                        with mock.patch.dict(stages.RUNTIME_BUDGET, {"ui": budget}), self.muted():
                            self.assertEqual(stages.execute("ui", self.artifacts), expected)
            coverage = json.loads((self.artifacts / "coverage.json").read_text())
            self.assertEqual(coverage["exit_code"], expected)
            self.assertTrue(coverage["errors"])

    def test_swift_product_receipt_includes_bundle_resources_and_libraries(self):
        original = Path.cwd()
        os.chdir(self.directory)
        self.addCleanup(os.chdir, original)
        root = Path(".build/debug")
        for name in ["Test.xctest/Contents/MacOS/Test", "TestResources.bundle/fixture", "libExample.dylib"]:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("product")
        receipt = stages.products("swift", self.artifacts, time.monotonic() + 60)
        self.assertEqual(len(receipt), 3)
        (root / "TestResources.bundle/fixture").write_text("changed")
        self.assertNotEqual(receipt, stages.products("swift", self.artifacts, time.monotonic() + 60))
        receipt = stages.products("swift", self.artifacts, time.monotonic() + 60)
        (root / "libExample.dylib").chmod(0o755)
        self.assertNotEqual(receipt, stages.products("swift", self.artifacts, time.monotonic() + 60))

    def test_mismatched_source_toolchain_or_options_cannot_start_tests(self):
        command = self.prepare()
        for identity, build in [
            ({**self.identity, "revision": "b" * 40}, command),
            ({**self.identity, "swift": "different Apple Swift"}, command),
            (self.identity, [*command, "changed-option"]),
        ]:
            with mock.patch.object(stages, "identity", return_value=identity):
                with mock.patch.object(stages, "build_command", return_value=build):
                    with mock.patch.object(stages, "test_command") as run:
                        with self.assertRaisesRegex(ValueError, "Prepared products"):
                            stages.execute("ui", self.artifacts)
                        run.assert_not_called()

    def test_failed_cold_build_removes_stale_receipt_and_never_starts_runtime(self):
        self.prepare()
        command = [sys.executable, "-c", "print('cold compile failed'); raise SystemExit(17)"]
        with mock.patch.object(stages, "artifact_directory", return_value=self.artifacts):
            with mock.patch.object(stages, "identity", return_value=self.identity):
                with mock.patch.object(stages, "build_command", return_value=command):
                    with mock.patch.object(stages, "execute") as runtime, self.muted():
                        self.assertEqual(stages.main(["swift"]), 17)
                        runtime.assert_not_called()
        self.assertFalse((self.artifacts / "prepared.json").exists())
        result = json.loads((self.artifacts / "build/result.json").read_text())
        self.assertEqual(result["exit_code"], 17)
        self.assertEqual(result["stage"], "build")
        self.assertEqual(result["budget_seconds"], 900)

    def test_build_timeout_is_truthful_and_cannot_produce_prepared_receipt(self):
        command = [sys.executable, "-c", "import time; print('building', flush=True); time.sleep(60)"]
        with mock.patch.object(stages, "identity", return_value=self.identity):
            with mock.patch.object(stages, "build_command", return_value=command):
                with mock.patch.object(stages, "BUILD_BUDGET", 0.1), self.muted():
                    self.assertEqual(stages.prepare("ui", self.artifacts), 124)
        result = json.loads((self.artifacts / "build/result.json").read_text())
        self.assertEqual(result["stage"], "build")
        self.assertIn("0.1s build budget", result["errors"][0])
        self.assertFalse((self.artifacts / "prepared.json").exists())

    def test_cancellation_readiness_rejects_command_header_and_unowned_process(self):
        log = self.directory / "cancellation.log"
        owned = self.directory / "gate-owns-process"
        owned.touch()
        header = "command: print('compiler started'); print('descendant started')\n"
        log.write_text(header)
        self.assertFalse(cancellation_fixture_ready(log, owned))
        log.write_text(header + "compiler started\n")
        self.assertFalse(cancellation_fixture_ready(log, owned))
        log.write_text(header + "compiler started\ndescendant started\n")
        self.assertTrue(cancellation_fixture_ready(log, owned))
        owned.unlink()
        self.assertFalse(cancellation_fixture_ready(log, owned))

    def test_build_cancellation_kills_descendants_and_retains_failure_receipt(self):
        marker = self.directory / "leaked-compiler"
        owned = self.directory / "gate-owns-process"
        # The descendant waits well beyond cancellation latency on a loaded runner,
        # so the marker only appears if cancellation failed to kill the group.
        child = ("import time; from pathlib import Path; print('descendant started', flush=True); "
                 f"time.sleep(3); Path({str(marker)!r}).touch()")
        compiler = ("import subprocess, sys, time; "
                    f"subprocess.Popen([sys.executable, '-c', {child!r}]); "
                    "print('compiler started', flush=True); time.sleep(60)")
        command = [sys.executable, "-c", compiler]
        gate_path = self.directory / "run-core-journey-e2e.py"
        gate_path.write_bytes(SCRIPT.with_name("run-core-journey-e2e.py").read_bytes())
        gate_path = str(gate_path)
        source = (
            "import runpy, signal, subprocess, sys\n"
            "from pathlib import Path\n"
            f"gate = runpy.run_path({gate_path!r})\n"
            # wait() is called only after run_gate assigns the process handle;
            # output from the child alone cannot establish parent ownership.
            "class OwnedProcess(subprocess.Popen):\n"
            "    def wait(self, *args, **kwargs):\n"
            f"        Path({str(owned)!r}).touch()\n"
            "        return super().wait(*args, **kwargs)\n"
            "gate['subprocess'].Popen = OwnedProcess\n"
            "def interrupted(*_):\n"
            "    raise InterruptedError('fixture build cancellation')\n"
            "signal.signal(signal.SIGTERM, interrupted)\n"
            f"sys.exit(gate['run_gate']({command!r}, {str(self.artifacts / 'build')!r}, 10, (), stage='build'))\n"
        )
        process = subprocess.Popen([sys.executable, "-c", source], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 30
            log = self.artifacts / "build/test.log"
            while not cancellation_fixture_ready(log, owned):
                if time.monotonic() >= deadline or process.poll() is not None:
                    self.fail("Synthetic compiler did not start")
                time.sleep(0.01)
            process.terminate()
            process.communicate(timeout=5)
            self.assertEqual(process.returncode, 1)
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=5)
        result = json.loads((self.artifacts / "build/result.json").read_text())
        self.assertEqual(result["stage"], "build")
        self.assertTrue(any("cancellation" in error for error in result["errors"]))
        time.sleep(3.2)
        self.assertFalse(marker.exists(), "Cancellation leaked a compiler descendant")

    def test_missing_products_or_expired_hashing_is_fail_closed(self):
        self.product.unlink()
        with self.assertRaisesRegex(ValueError, "exactly one"):
            stages.products("ui", self.artifacts, time.monotonic() + 60)
        self.product.write_text("product")
        with self.assertRaises(TimeoutError):
            stages.products("ui", self.artifacts, time.monotonic() - 1)

    def test_source_change_during_build_cannot_publish_receipt(self):
        command = [sys.executable, "-c", "print('build')"]
        with mock.patch.object(stages, "identity", side_effect=[self.identity, {"revision": "b" * 40}]):
            with mock.patch.object(stages, "build_command", return_value=command), self.muted():
                with self.assertRaisesRegex(ValueError, "changed during preparation"):
                    stages.prepare("ui", self.artifacts)
        self.assertFalse((self.artifacts / "prepared.json").exists())

    def test_missing_receipt_records_preflight_error_instead_of_building(self):
        with mock.patch.object(stages, "artifact_directory", return_value=self.artifacts):
            with mock.patch.object(stages.GATE["subprocess"], "Popen") as run, self.muted():
                self.assertEqual(stages.main(["swift", "--phase", "test"]), 1)
                run.assert_not_called()
        self.assertIn("failed closed", (self.artifacts / "test-error.json").read_text())


if __name__ == "__main__":
    unittest.main()
