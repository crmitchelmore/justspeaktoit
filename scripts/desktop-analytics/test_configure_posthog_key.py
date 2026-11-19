"""Checks the desktop PostHog project-key writer with synthetic keys."""
import contextlib
import importlib.util
import io
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("configure", HERE / "configure-posthog-key.py")
CONFIGURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONFIGURE)

KEY = "phc_Synthetic0123456789abcdefGHIJKLmnopqrst-_"
STAMP_CONDITION = (
    "${{ (github.event_name == 'push' && github.ref == 'refs/heads/main') || "
    "startsWith(github.ref, 'refs/tags/alpha-build-') || "
    "startsWith(github.ref, 'refs/tags/stable-candidate-') }}"
)


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


    def load_workflow(self, name):
        """Parses a workflow with Ruby's YAML, the parser the other tooling tests already rely on."""
        script = "require 'yaml'; require 'json'; puts JSON.generate(YAML.safe_load(File.read(ARGV[0])))"
        path = CONFIGURE.ROOT / ".github" / "workflows" / name
        result = subprocess.run(["ruby", "-e", script, str(path)], capture_output=True, text=True, check=True)
        return json.loads(result.stdout)

    @staticmethod
    def evaluate(condition, event_name, ref):
        """Evaluates the stamp step's `if` for one trigger, in the expression subset the workflows use."""
        expression = condition.strip()
        if expression.startswith("${{") and expression.endswith("}}"):
            expression = expression[3:-2]
        expression = (expression.replace("&&", " and ").replace("||", " or ")
                      .replace("github.event_name", "event_name").replace("github.ref", "ref"))
        names = {"event_name": event_name, "ref": ref, "startsWith": str.startswith}
        return eval(expression, {"__builtins__": {}}, names)  # noqa: S307 # the expression is this repository's own

    def test_release_workflows_stamp_only_main_pushes_and_manifest_tags_before_building(self):
        builds = {"windows-cross-proof.yml": "Cross-build the Windows app and test suite",
                  "windows-arm64.yml": "Build native Windows ARM64 executable",
                  "linux-flatpak.yml": "Build offline"}
        triggers = [("push", "refs/heads/main", True),
                    ("workflow_dispatch", "refs/heads/main", False),
                    ("workflow_dispatch", "refs/tags/alpha-build-42", True),
                    ("workflow_dispatch", "refs/tags/stable-candidate-3", True),
                    ("push", "refs/tags/alpha-build-42", True),
                    ("pull_request", "refs/pull/1828/merge", False),
                    ("pull_request_target", "refs/heads/main", False),
                    ("workflow_dispatch", "refs/heads/feature", False),
                    ("push", "refs/heads/feature", False),
                    ("push", "refs/tags/v1.0.0", False),
                    ("workflow_dispatch", "refs/tags/not-alpha-build-1", False)]
        for name, build in builds.items():
            with self.subTest(workflow=name):
                workflow = self.load_workflow(name)
                steps = [step for job in workflow["jobs"].values() for step in job.get("steps", [])]
                keyed = [step for step in steps if "secrets.POSTHOG_PROJECT_KEY" in json.dumps(step.get("env", {}))]
                self.assertEqual(len(keyed), 1)
                stamp = keyed[0]
                self.assertEqual(stamp["name"], "Stamp the PostHog project key into release builds")
                self.assertEqual(stamp["env"], {"POSTHOG_PROJECT_KEY": "${{ secrets.POSTHOG_PROJECT_KEY }}"})
                self.assertIn("scripts/desktop-analytics/configure-posthog-key.py", stamp["run"])
                self.assertEqual(stamp["if"], STAMP_CONDITION)
                for event_name, ref, stamped in triggers:
                    self.assertIs(self.evaluate(stamp["if"], event_name, ref), stamped, (event_name, ref))
                job = next(job for job in workflow["jobs"].values() if stamp in job.get("steps", []))
                names = [step.get("name") for step in job["steps"]]
                self.assertLess(names.index(stamp["name"]), names.index(build))
                trigger_paths = [path for trigger in workflow[next(k for k in ("on", "true") if k in workflow)].values()
                                 if isinstance(trigger, dict) for path in trigger.get("paths", [])]
                self.assertIn("scripts/desktop-analytics/**", trigger_paths)

if __name__ == "__main__":
    unittest.main()
