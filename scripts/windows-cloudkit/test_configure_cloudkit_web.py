"""Checks the CloudKit Web Services build-setting writer with synthetic tokens."""
from pathlib import Path
import importlib.util
import unittest

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("configure", HERE / "configure-cloudkit-web.py")
CONFIGURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONFIGURE)


class ConfigureCloudKitWebTests(unittest.TestCase):
    def committed(self) -> str:
        return CONFIGURE.TARGET.read_text(encoding="utf-8")

    def test_committed_source_has_no_token(self):
        self.assertIn("static let apiToken: String? = nil", self.committed())
        self.assertIn('static let environment = "production"', self.committed())

    def test_token_and_environment_are_written(self):
        source = CONFIGURE.configured_source(self.committed(), "synthetic0token0value0abcdef", "development")
        self.assertIn('static let apiToken: String? = "synthetic0token0value0abcdef"', source)
        self.assertIn('static let environment = "development"', source)
        self.assertNotIn("= nil", source)

    def test_values_that_could_break_out_of_a_string_are_refused(self):
        for token in ['abc"; exit(1); //', "short", "has space in it 1234567", "back\\slash\\1234567890"]:
            with self.assertRaises(ValueError):
                CONFIGURE.configured_source(self.committed(), token, "production")
        with self.assertRaises(ValueError):
            CONFIGURE.configured_source(self.committed(), "synthetic0token0value0abcdef", "staging")


if __name__ == "__main__":
    unittest.main()
