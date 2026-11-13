import importlib.util
import os
import plistlib
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "validator", ROOT / "scripts/verify-keyboard-purpose-strings.py"
)
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)


class KeyboardPurposeStringsTests(unittest.TestCase):
    def test_shared_plist_passes_for_both_capture_modes(self):
        for mode in ("handoff", "direct"):
            with self.subTest(mode=mode):
                VALIDATOR.validate(ROOT / "JustSpeakKeyboard/Info.plist")

    def test_missing_or_empty_purpose_strings_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Info.plist"
            for key in ("NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"):
                for value in (None, "", "  ", 123):
                    with self.subTest(key=key, value=value):
                        info = plistlib.loads((ROOT / "JustSpeakKeyboard/Info.plist").read_bytes())
                        if value is None:
                            info.pop(key)
                        else:
                            info[key] = value
                        path.write_bytes(plistlib.dumps(info))
                        with self.assertRaises(ValueError):
                            VALIDATOR.validate(path)

    def test_release_workflow_uses_same_validator(self):
        workflow = (ROOT / ".github/workflows/release-ios.yml").read_text()
        self.assertIn('python3 scripts/verify-keyboard-purpose-strings.py "$KEYBOARD_PATH/Info.plist"', workflow)
        self.assertNotIn("Handoff-only keyboard unexpectedly declares", workflow)

    def test_release_workflow_ships_handoff_keyboard_on_every_train(self):
        workflow = (ROOT / ".github/workflows/release-ios.yml").read_text()
        policy = workflow.split("- name: Select keyboard capture policy", 1)[1].split("- name:", 1)[0]
        self.assertIn("TUIST_IOS_KEYBOARD_DIRECT_CAPTURE=0", policy)
        self.assertNotIn("TUIST_IOS_KEYBOARD_DIRECT_CAPTURE=1", policy)
        self.assertNotIn("RELEASE_TRAIN", policy)
        self.assertNotIn('TUIST_IOS_KEYBOARD_DIRECT_CAPTURE: "', workflow.split("jobs:", 1)[0])

    def run_preview_target_policy(self, train, source=ROOT):
        workflow = (ROOT / ".github/workflows/release-ios.yml").read_text()
        step = workflow.split("- name: Select Alpha preview targets", 1)[1].split("- name:", 1)[0]
        script = textwrap.dedent(step.split("run: |", 1)[1])
        with tempfile.TemporaryDirectory() as directory:
            env_file = Path(directory) / "env"
            subprocess.run(["bash", "-e", "-c", script], cwd=source, check=True,
                           env={**os.environ, "RELEASE_TRAIN": train, "GITHUB_ENV": str(env_file)})
            return dict(line.split("=", 1) for line in env_file.read_text().splitlines())

    def test_release_workflow_enables_watch_and_share_for_alpha_only(self):
        alpha = self.run_preview_target_policy("alpha")
        self.assertEqual(alpha["TUIST_WATCH_APP"], "1")
        self.assertEqual(alpha["TUIST_IOS_SHARE_EXTENSION"], "1")
        self.assertEqual(alpha["WATCH_APP_GROUP"], "group.com.justspeaktoit.watch.alpha")
        stable = self.run_preview_target_policy("stable")
        self.assertEqual(stable["TUIST_WATCH_APP"], "0")
        self.assertEqual(stable["TUIST_IOS_SHARE_EXTENSION"], "0")
        self.assertEqual(stable["WATCH_APP_REASON"], "Stable train")
        workflow = (ROOT / ".github/workflows/release-ios.yml").read_text()
        for flag in ("TUIST_WATCH_APP", "TUIST_IOS_SHARE_EXTENSION"):
            self.assertNotIn(f"{flag}: ", workflow.split("jobs:", 1)[0])

    def test_alpha_leaves_out_preview_targets_an_older_source_cannot_sign(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            (source / "scripts").mkdir()
            (source / "scripts/verify-release-train-archive.py").write_text("# older verifier\n")
            (source / "Project.swift").write_text('bundleId: "com.justspeaktoit.ios.share"\n')
            resources = source / "Sources/SpeakCore/Resources"
            resources.mkdir(parents=True)
            shutil.copy(ROOT / "Sources/SpeakCore/Resources/ReleaseTrains.json", resources)
            alpha = self.run_preview_target_policy("alpha", source)
        self.assertEqual(alpha["TUIST_WATCH_APP"], "0")
        self.assertIn("predates", alpha["WATCH_APP_REASON"])
        self.assertEqual(alpha["TUIST_IOS_SHARE_EXTENSION"], "0")
        self.assertIn("predates", alpha["SHARE_EXTENSION_REASON"])
