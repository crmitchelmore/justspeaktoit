import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import call, patch


SPEC = importlib.util.spec_from_file_location(
    "ios_test_products", Path(__file__).resolve().parents[1] / "ios-test-products.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class IOSTestProductsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.products = self.root / MODULE.PRODUCT
        self.products.mkdir()
        binary = self.products / "Runner"
        binary.write_text("test executable")
        binary.chmod(0o755)
        (self.products / "RunnerLink").symlink_to("Runner")
        self.archive = self.root / "products.tar.gz"
        self.expected = {"revision": "a" * 40, "xcode": "Xcode 26.3", "sdk": "26.3"}

    def test_round_trip_preserves_executable_permissions_and_relative_links(self):
        MODULE.pack(self.products, self.archive, self.expected)
        destination = self.root / "restored"
        MODULE.unpack(self.archive, destination, self.expected)
        restored = destination / MODULE.PRODUCT
        self.assertEqual((restored / "Runner").stat().st_mode & 0o777, 0o755)
        self.assertTrue((restored / "RunnerLink").is_symlink())
        self.assertEqual((restored / "RunnerLink").read_text(), "test executable")

    def test_revision_xcode_and_sdk_mismatches_fail_before_extraction(self):
        MODULE.pack(self.products, self.archive, self.expected)
        for key in self.expected:
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "do not match"):
                MODULE.unpack(
                    self.archive, self.root / "restored", {**self.expected, key: "different"}
                )
            self.assertFalse((self.root / "restored").exists())

    def test_missing_build_products_fail_pack(self):
        with self.assertRaises(FileNotFoundError):
            MODULE.pack(self.root / "missing", self.archive, self.expected)
        self.assertFalse(self.archive.exists())

    def test_provenance_reads_the_actual_revision_and_toolchain(self):
        with patch.dict(MODULE.os.environ, {"GITHUB_SHA": "a" * 40}), patch.object(
            MODULE.subprocess, "check_output", side_effect=["Xcode 26.3\n", "26.3\n"]
        ) as tool:
            self.assertEqual(MODULE.provenance(), self.expected)
        self.assertEqual(tool.call_args_list, [
            call(["xcodebuild", "-version"], text=True),
            call(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"], text=True),
        ])

    def test_invalid_revision_fails_before_toolchain_lookup(self):
        with patch.dict(MODULE.os.environ, {"GITHUB_SHA": "main"}), patch.object(
            MODULE.subprocess, "check_output"
        ) as tool, self.assertRaises(ValueError):
            MODULE.provenance()
        tool.assert_not_called()

    def test_archive_without_products_cannot_pass(self):
        with tarfile.open(self.archive, "w:gz") as output:
            data = json.dumps(self.expected).encode()
            metadata = tarfile.TarInfo(MODULE.METADATA)
            metadata.size = len(data)
            output.addfile(metadata, io.BytesIO(data))
        with self.assertRaises(FileNotFoundError):
            MODULE.unpack(self.archive, self.root / "restored", self.expected)

    def test_archive_cannot_write_outside_the_destination(self):
        with tarfile.open(self.archive, "w:gz") as output:
            data = json.dumps(self.expected).encode()
            metadata = tarfile.TarInfo(MODULE.METADATA)
            metadata.size = len(data)
            output.addfile(metadata, io.BytesIO(data))
            escape = tarfile.TarInfo("../escaped")
            escape.size = 1
            output.addfile(escape, io.BytesIO(b"x"))
        with self.assertRaises(tarfile.FilterError):
            MODULE.unpack(self.archive, self.root / "restored", self.expected)
        self.assertFalse((self.root / "escaped").exists())
