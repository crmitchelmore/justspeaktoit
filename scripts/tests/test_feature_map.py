import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("check_feature_map", ROOT / "scripts/check-feature-map.py")
CHECK = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CHECK
SPEC.loader.exec_module(CHECK)

TABLE = "| F01 | Thing | Yes | N/A | Yes | No | Yes | #1 | |\n"
ENTRY = """### F01 Thing
- **Platforms:** macOS Yes · iOS N/A · Windows Yes · Linux No · Android Yes
- **Excluded:** iOS (OS: no background keys).
- **Gaps:** Linux #1.
- **How:** Does the thing.
- **Refs:** `Docs/feature-map.md`
- **Sunset:** none
- **Nuances:** none
"""


class FeatureMapTests(unittest.TestCase):
    def test_repository_map_is_consistent(self):
        self.assertEqual([], CHECK.check(CHECK.MAP.read_text(encoding="utf-8")))

    def test_valid_entry_passes(self):
        self.assertEqual([], CHECK.check(TABLE + ENTRY))

    def test_duplicate_ids_fail(self):
        errors = CHECK.check(TABLE + TABLE + ENTRY + ENTRY)
        self.assertIn("duplicate table row F01", errors)
        self.assertIn("duplicate entry F01", errors)

    def test_status_mismatch_fails(self):
        errors = CHECK.check(TABLE + ENTRY.replace("Android Yes", "Android No"))
        self.assertIn("F01: Platforms line does not match the summary table", errors)

    def test_gap_without_issue_fails(self):
        errors = CHECK.check(TABLE.replace("#1", "") + ENTRY.replace("Linux #1", "Linux"))
        self.assertIn("F01: Linux gap needs an issue in Gaps", errors)

    def test_exclusion_without_reason_kind_fails(self):
        errors = CHECK.check(TABLE + ENTRY.replace("(OS:", "("))
        self.assertIn("F01: Excluded must say '(OS' or '(owner decision'", errors)

    def test_missing_path_fails(self):
        errors = CHECK.check(TABLE + ENTRY.replace("Docs/feature-map.md", "Sources/Missing.swift"))
        self.assertIn("cited path does not exist: Sources/Missing.swift", errors)

    def test_missing_link_fails(self):
        errors = CHECK.check(TABLE + ENTRY.replace("none\n- **Nuances:**", "none\n- **Nuances:** [gone](gone.md)"))
        self.assertIn("linked file does not exist: gone.md", errors)


if __name__ == "__main__":
    unittest.main()
