import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "ios/check-app-shortcuts.py"


class CheckAppShortcutsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / "Shortcuts.swift"
        self.source.write_text("AppShortcut(intent: A())\nAppShortcut (intent: B())\n")

    def write_app(self, shortcuts, name="JustSpeakToIt.app", parent=None):
        app = (parent or self.root / "Products") / name
        (app / "Metadata.appintents").mkdir(parents=True)
        metadata = {"actions": {}, "autoShortcuts": [{"phraseTemplates": []}] * shortcuts}
        (app / "Metadata.appintents/extract.actionsdata").write_text(json.dumps(metadata))
        return app

    def run_check(self, path):
        return subprocess.run([sys.executable, str(SCRIPT), str(path), "--source", str(self.source)],
                              capture_output=True, text=True, check=False)

    def test_appWithEveryDeclaredShortcut_passes(self):
        app = self.write_app(2)
        self.write_app(0, name="Watch.app", parent=app / "Watch")
        result = self.run_check(self.root / "Products")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("2 App Shortcuts registered", result.stdout)

    def test_appWithNoShortcuts_fails(self):
        result = self.run_check(self.write_app(0))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("registers no App Shortcuts", result.stderr)

    def test_appMissingSomeDeclaredShortcuts_fails(self):
        result = self.run_check(self.write_app(1))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("declares 2", result.stderr)


if __name__ == "__main__":
    unittest.main()
