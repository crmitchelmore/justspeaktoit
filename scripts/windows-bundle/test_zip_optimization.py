"""Offline fixtures; real-tool coverage is opt-in through JSTI_ADVZIP."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock
import zipfile

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
import zip_optimization as ZIP

spec = importlib.util.spec_from_file_location("prepare_zip_optimizer", HERE / "prepare-zip-optimizer.py")
PREPARE = importlib.util.module_from_spec(spec)
spec.loader.exec_module(PREPARE)


def write_fixture(path):
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name in ("README.txt", "resources/m\u00e9tadonn\u00e9es.txt"):
            info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, (name.encode("utf-8") + b"\n") * 4000, compresslevel=9)


def rewrite(path, mutate):
    with zipfile.ZipFile(path) as archive:
        entries = [(copy.copy(info), archive.read(info)) for info in archive.infolist()]
        comment = archive.comment
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        archive.comment = comment
        for index, (info, data) in enumerate(entries):
            info, data = mutate(index, info, data)
            archive.writestr(info, data, compresslevel=9)


class ZipOptimizationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.archive = self.root / "original.zip"
        self.tool = self.root / "advzip"
        self.tool.write_bytes(b"fixture tool")
        write_fixture(self.archive)
        self.original = self.archive.read_bytes()

    def invoke(self, action=None):
        def run(command, **kwargs):
            if command[-1] == "--version":
                return subprocess.CompletedProcess(command, 0, "advancecomp v2.6 by fixture", "")
            self.assertEqual(command[1:5], ["--recompress", "--shrink-normal", "--keep-file-time", "--quiet"])
            self.assertEqual(kwargs["timeout"], 300)
            candidate = Path(command[-1])
            self.assertNotEqual(candidate, self.archive)
            if action:
                action(candidate)
            return subprocess.CompletedProcess(command, 0, "", "")
        with mock.patch.object(ZIP.subprocess, "run", side_effect=run):
            return ZIP.optimize_archive(self.archive, self.tool)

    def assert_preserved(self):
        self.assertEqual(self.archive.read_bytes(), self.original)
        self.assertEqual(list(self.root.glob(".zip-optimization-*")), [])

    def test_identity_recompression_records_evidence(self):
        receipt = self.invoke()
        self.assertEqual(receipt["verifiedEntries"], 2)
        self.assertEqual(receipt["savedBytes"], 0)
        self.assertEqual(receipt["toolSHA256"], ZIP.digest(self.tool))
        self.assert_preserved()

    def test_compression_hint_bits_are_not_semantic_changes(self):
        def hints(path):
            data = bytearray(path.read_bytes())
            for signature, offset in ((b"PK\x03\x04", 6), (b"PK\x01\x02", 8)):
                start = 0
                while (start := data.find(signature, start)) >= 0:
                    flags = struct.unpack_from("<H", data, start + offset)[0]
                    struct.pack_into("<H", data, start + offset, flags | 2)
                    start += 4
            path.write_bytes(data)
        before = ZIP.inventory(self.archive)
        self.invoke(hints)
        self.assertEqual(ZIP.inventory(self.archive), before)

    def test_payload_and_metadata_changes_are_refused(self):
        def payload(index, info, data):
            return info, data + b"changed" if index == 0 else data
        mutations = [
            payload,
            lambda index, info, data: (copy_with(info, filename="other-" + info.filename), data),
            lambda index, info, data: (copy_with(info, date_time=(2020, 1, 1, 0, 0, 0)), data),
            lambda index, info, data: (copy_with(info, external_attr=0o100755 << 16), data),
            lambda index, info, data: (copy_with(info, comment=b"changed"), data),
            lambda index, info, data: (copy_with(info, extra=b"\xfe\xca\x00\x00"), data),
        ]
        for mutate in mutations:
            with self.subTest(mutation=mutate), self.assertRaises(ValueError):
                self.invoke(lambda path: rewrite(path, mutate))
            self.assert_preserved()

    def test_order_and_archive_comment_changes_are_refused(self):
        def reorder(path):
            with zipfile.ZipFile(path) as archive:
                entries = [(copy.copy(info), archive.read(info)) for info in reversed(archive.infolist())]
            with zipfile.ZipFile(path, "w") as archive:
                for info, data in entries:
                    archive.writestr(info, data)
        def comment(path):
            with zipfile.ZipFile(path, "a") as archive:
                archive.comment = b"changed"
        for action in (reorder, comment):
            with self.subTest(action=action), self.assertRaises(ValueError):
                self.invoke(action)
            self.assert_preserved()

    def test_growth_invalid_output_failure_and_timeout_preserve_original(self):
        def growth(path):
            path.write_bytes(path.read_bytes() + b"trailing junk")
        def invalid(path):
            path.write_bytes(b"not a zip")
        def failed(path):
            raise subprocess.CalledProcessError(1, ["advzip"], stderr="fixture failure")
        def timeout(path):
            raise subprocess.TimeoutExpired(["advzip"], 300)
        for action in (growth, invalid, failed, timeout):
            with self.subTest(action=action), self.assertRaises(ValueError):
                self.invoke(action)
            self.assert_preserved()

    def test_tool_mutation_is_refused(self):
        def mutate(path):
            self.tool.write_bytes(b"changed tool")
        with self.assertRaisesRegex(ValueError, "optimizer changed"):
            self.invoke(mutate)
        self.assert_preserved()

    def test_external_archive_write_is_not_overwritten(self):
        replacement = b"another writer owns this output"
        def mutate(path):
            self.archive.write_bytes(replacement)
        with self.assertRaisesRegex(ValueError, "Original ZIP changed"):
            self.invoke(mutate)
        self.assertEqual(self.archive.read_bytes(), replacement)

    def test_version_is_checked_before_recompression(self):
        with mock.patch.object(ZIP.subprocess, "run", return_value=subprocess.CompletedProcess(
                ["advzip"], 0, "advancecomp v1.0", "")) as run:
            with self.assertRaisesRegex(ValueError, "Expected AdvanceCOMP"):
                ZIP.optimize_archive(self.archive, self.tool)
            self.assertEqual(run.call_count, 1)
        self.assert_preserved()

    def test_relative_missing_and_directory_tools_are_refused(self):
        for tool in (Path("relative-tool"), self.root / "missing", self.root):
            with self.subTest(tool=tool), self.assertRaises(ValueError):
                ZIP.optimize_archive(self.archive, tool)
        self.assert_preserved()

    def test_zip64_and_unsupported_methods_are_refused(self):
        with zipfile.ZipFile(self.archive, "w", compression=zipfile.ZIP_BZIP2) as archive:
            archive.writestr("payload", b"test")
        with self.assertRaisesRegex(ValueError, "Unsupported ZIP compression"):
            ZIP.inventory(self.archive)
        write_fixture(self.archive)
        def zip64(index, info, data):
            return copy_with(info, extract_version=45), data
        rewrite(self.archive, zip64)
        with self.assertRaisesRegex(ValueError, "extraction requirements"):
            ZIP.inventory(self.archive)

    @unittest.skipUnless(os.environ.get("JSTI_ADVZIP"), "set JSTI_ADVZIP to the pinned prepared tool")
    def test_real_optimizer_is_deterministic_and_preserves_unicode(self):
        duplicate = self.root / "duplicate.zip"
        duplicate.write_bytes(self.original)
        expected = ZIP.inventory(self.archive)
        tool = Path(os.environ["JSTI_ADVZIP"])
        first = ZIP.optimize_archive(self.archive, tool)
        ZIP.optimize_archive(duplicate, tool)
        self.assertEqual(self.archive.read_bytes(), duplicate.read_bytes())
        self.assertEqual(ZIP.inventory(self.archive), expected)
        self.assertGreaterEqual(first["savedBytes"], 0)


def copy_with(info, **values):
    info = copy.copy(info)
    for key, value in values.items():
        setattr(info, key, value)
    return info


class OptimizerPreparationTests(unittest.TestCase):
    def test_pins_match_supported_version(self):
        lock = json.loads((HERE / "archive-optimizer.json").read_text(encoding="utf-8"))
        self.assertEqual(lock["version"], ZIP.VERSION)
        for key in ("source", "windows-x64"):
            self.assertTrue(lock[key]["url"].startswith(
                "https://github.com/amadvance/advancecomp/releases/download/v" + ZIP.VERSION + "/"))
            self.assertGreater(lock[key]["bytes"], 0)
            self.assertEqual(len(bytes.fromhex(lock[key]["sha256"])), 32)

    def test_windows_preparation_only_extracts_the_pinned_tool(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source, output = root / "tool.zip", root / "output"
            with zipfile.ZipFile(source, "w") as archive:
                archive.writestr("advzip.exe", b"fixture executable")
                archive.writestr("../not-extracted", b"unrelated")
            with mock.patch.object(PREPARE.platform, "system", return_value="Windows"), \
                    mock.patch.object(PREPARE.platform, "machine", return_value="AMD64"), \
                    mock.patch.object(PREPARE.PIN, "download", return_value=source), \
                    mock.patch.object(PREPARE.subprocess, "run", return_value=subprocess.CompletedProcess(
                        [], 0, "advancecomp v2.6 by fixture", "")):
                tool = PREPARE.prepare(root / "downloads", output)
            self.assertEqual(tool.read_bytes(), b"fixture executable")
            receipt = json.loads((output / "archive-optimizer.json").read_text(encoding="utf-8"))
            self.assertEqual(receipt["toolSHA256"], ZIP.digest(tool))
            self.assertFalse((root / "not-extracted").exists())

    def test_mac_preparation_builds_only_advzip_from_private_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source = root / "tool.tar.gz"
            upstream = root / "advancecomp-2.6"
            upstream.mkdir()
            (upstream / "advzip").write_bytes(b"compiled fixture")
            with tarfile.open(source, "w:gz") as archive:
                archive.add(upstream, arcname=upstream.name)
            with mock.patch.object(PREPARE.platform, "system", return_value="Darwin"), \
                    mock.patch.object(PREPARE.PIN, "download", return_value=source), \
                    mock.patch.object(PREPARE.subprocess, "run", return_value=subprocess.CompletedProcess(
                        [], 0, "advancecomp v2.6 by fixture", "")) as run:
                tool = PREPARE.prepare(root / "downloads", root / "output")
            self.assertEqual(tool.read_bytes(), b"compiled fixture")
            self.assertEqual([call.args[0][:4] for call in run.call_args_list[:2]],
                             [["./configure"], ["make", "-j4", "advzip"]])
            self.assertTrue(all(call.kwargs["cwd"].parent.name.startswith(".prepare-advzip-")
                                for call in run.call_args_list[:2]))
            self.assertEqual(list((root / "output").glob(".prepare-advzip-*")), [])


if __name__ == "__main__":
    unittest.main()
