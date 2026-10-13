import json
from pathlib import Path
import shutil
import tempfile
import unittest

from migration_dependency import license_entry


ROOT = Path(__file__).resolve().parents[2]


class NativeMigrationDependencyTests(unittest.TestCase):
    def test_committed_pin_and_license_are_complete(self):
        entry = license_entry(ROOT)
        self.assertEqual(entry["license"], "MIT")
        self.assertIn(b"RAD Game Tools and Valve Software", entry["data"])
        self.assertIn(b"Permission is hereby granted", entry["data"])

    def test_source_drift_or_unexpected_pin_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / "Sources" / "CMigrationArchive" / "miniz"
            shutil.copytree(ROOT / "Sources" / "CMigrationArchive" / "miniz", directory)
            with (directory / "miniz_zip.c").open("ab") as stream:
                stream.write(b"\n/* changed */\n")
            with self.assertRaisesRegex(ValueError, "differs from its pin"):
                license_entry(root)
            shutil.copyfile(ROOT / "Sources" / "CMigrationArchive" / "miniz" / "miniz_zip.c",
                            directory / "miniz_zip.c")
            pin_path = directory / "dependency.json"
            pin = json.loads(pin_path.read_text())
            pin["files"]["../unexpected"] = "0" * 64
            pin_path.write_text(json.dumps(pin))
            with self.assertRaisesRegex(ValueError, "Invalid native migration dependency"):
                license_entry(root)

    def test_platform_checkout_line_endings_do_not_change_source_authority(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / "Sources" / "CMigrationArchive" / "miniz"
            shutil.copytree(ROOT / "Sources" / "CMigrationArchive" / "miniz", directory)
            pin = json.loads((directory / "dependency.json").read_text())
            for name in pin["files"]:
                source = directory / name
                source.write_bytes(source.read_bytes().replace(b"\r\n", b"\n").replace(b"\n", b"\r\n"))
            self.assertEqual(license_entry(root)["data"], license_entry(ROOT)["data"])


if __name__ == "__main__":
    unittest.main()
