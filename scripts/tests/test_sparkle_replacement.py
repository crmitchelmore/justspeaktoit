import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "replacement", Path(__file__).resolve().parents[1] / "verify-sparkle-replacement.py"
)
replacement = importlib.util.module_from_spec(spec)
spec.loader.exec_module(replacement)


class ReplacementTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.bundle = Path(self.directory.name) / "App.app"
        self.bundle.mkdir()
        self.executable = self.bundle / "binary"
        self.executable.write_bytes(b"same signed executable")
        self.before = replacement.identity(self.bundle, self.executable)

    def test_original_signed_copy_does_not_prove_installation(self):
        self.assertFalse(replacement.wait_for_replacement(self.before, self.bundle, self.executable, 0))

    def test_identical_bytes_in_replacement_bundle_prove_swap(self):
        self.bundle.rename(self.bundle.with_name("old.app"))
        self.bundle.mkdir()
        self.executable.write_bytes(b"same signed executable")
        self.assertTrue(replacement.wait_for_replacement(self.before, self.bundle, self.executable, 0))

    def test_in_place_mutation_does_not_count_as_replacement(self):
        self.executable.write_bytes(b"modified executable")
        self.assertFalse(replacement.was_replaced(self.before, self.bundle, self.executable))

    def test_executable_only_replacement_is_insufficient(self):
        self.executable.rename(self.bundle / "old-binary")
        self.executable.write_bytes(b"same signed executable")
        self.assertFalse(replacement.was_replaced(self.before, self.bundle, self.executable))

    def test_missing_bundle_during_or_after_swap_is_not_success(self):
        self.bundle.rename(self.bundle.with_name("old.app"))
        self.assertFalse(replacement.was_replaced(self.before, self.bundle, self.executable))


if __name__ == "__main__":
    unittest.main()
