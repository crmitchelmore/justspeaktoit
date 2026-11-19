import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("ios_device_copy", ROOT / "scripts/ios/check-device-copy.py")
CHECK = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CHECK
SPEC.loader.exec_module(CHECK)

PATH = "Sources/SpeakiOS/Views/Example.swift"


def literals(source: str) -> list[str]:
    return [finding.literal for finding in CHECK.scan_source(PATH, source)]


class IOSDeviceCopyCheckTests(unittest.TestCase):
    def test_repository_has_no_findings(self):
        self.assertEqual([], [str(finding) for finding in CHECK.scan()])

    def test_hard_coded_device_copy_fails(self):
        self.assertEqual(["Keeps audio on this iPhone."], literals('Text("Keeps audio on this iPhone.")'))
        self.assertEqual(
            ["Shows on the Lock Screen and in the Dynamic Island."],
            literals('let s = "Shows on the Lock Screen and in the Dynamic Island."'),
        )

    def test_multiline_and_interpolated_literals_are_scanned(self):
        self.assertEqual(["\n  Unlock your iPhone.\n  "], literals('let s = """\n  Unlock your iPhone.\n  """'))
        self.assertEqual([" on iPhone"], literals('let s = "\\(name(for: "x")) on iPhone"'))
        self.assertEqual(["iPhone"], literals('let s = "a \\(f("iPhone")) b"'))

    def test_comments_symbols_and_helper_pass(self):
        self.assertEqual([], literals('// this iPhone\n/* the Dynamic Island */\nImage(systemName: "lock.iphone")'))
        self.assertEqual([], literals('Text("Keeps audio on \\(DeviceCopy.thisDevice).")'))
        self.assertEqual([], CHECK.scan_source("Sources/SpeakiOS/Views/DeviceCopy.swift", 'let s = "iPhone"'))

    def test_allowlist_is_scoped_to_its_file(self):
        detail = '"On an iPhone with an Action Button, open Settings."'
        allowed = "Sources/SpeakiOS/Views/Settings/HardwareTriggerSettingsView.swift"
        self.assertEqual([], CHECK.scan_source(allowed, detail))
        self.assertEqual(1, len(literals(detail)))


if __name__ == "__main__":
    unittest.main()
