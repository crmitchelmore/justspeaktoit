import importlib.util
import plistlib
import tempfile
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
