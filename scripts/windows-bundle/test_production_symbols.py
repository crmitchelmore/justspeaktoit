"""Data-only production debug transform regressions; no compiler/tool downloads."""
import hashlib
import importlib.util
import json
import pathlib
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import production_symbols as SYMBOLS

SPEC = importlib.util.spec_from_file_location("symbols_bundle_fixtures", HERE / "test_windows_bundle.py")
FIXTURES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FIXTURES)


def image(machine=0x8664, codeview=False):
    """Real PE import tables plus code, raw padding, and one long-name debug section."""
    data = bytearray(FIXTURES.build_pe(["swiftCore.dll"], delay_imports=["KERNEL32.dll"], machine=machine))
    pe = struct.unpack_from("<I", data, 60)[0]
    optional = pe + 24
    table = optional + struct.unpack_from("<H", data, pe + 20)[0]
    text = len(data)
    data.extend(bytes(range(16)) + bytes(496))
    debug = len(data)
    data.extend(b"private debug fixture" + bytes(512 - 21))
    strings = struct.pack("<I", 16) + b".debug_info\0"
    struct.pack_into("<H", data, pe + 6, 3)
    struct.pack_into("<II", data, pe + 12, len(data), 0)
    data.extend(strings)
    for at, name, size, rva, pointer, flags in [
        (table + 40, b".text", 16, 0x3000, text, 0x60000020),
        (table + 80, b"/4", 21, 0x5000, debug, 0x42000040),
    ]:
        struct.pack_into("<8sIIIIIIHHI", data, at, name, size, rva, 512, pointer, 0, 0, 0, 0, flags)
    if codeview:
        rdata = 0x400
        struct.pack_into("<I", data, table + 8, 400)
        struct.pack_into("<II", data, optional + 112 + 6 * 8, 0x1100, 28)
        struct.pack_into("<IIHHIIII", data, rdata + 256, 0, 7, 0, 0, 2, 25, 0x1120, rdata + 288)
        data[rdata + 288:rdata + 313] = b"RSDS" + bytes(21)
    struct.pack_into("<I", data, optional + 4, 512)
    struct.pack_into("<I", data, optional + 8, 1024)
    struct.pack_into("<II", data, optional + 56, 0x6000, 512)
    return bytes(data)


def without_debug(data, arm_padding=False):
    out = bytearray(data)
    pe = struct.unpack_from("<I", out, 60)[0]
    _, rows = SYMBOLS.sections(data)
    struct.pack_into("<H", out, pe + 6, 2)
    struct.pack_into("<II", out, pe + 12, 0, 0)
    out = out[:rows[".debug_info"]["pointer"]]
    struct.pack_into("<I", out, pe + 24 + 8, 512)
    struct.pack_into("<I", out, pe + 24 + 56, 0x4000)
    if arm_padding:
        row = rows[".text"]
        out[row["pointer"] + row["virtualSize"]:row["pointer"] + row["rawSize"]] = b"\xcc" * 496
    return bytes(out)


class TransformValidationTests(unittest.TestCase):
    def test_debug_removed_but_all_live_code_imports_and_metadata_preserved(self):
        original = image()
        result = SYMBOLS.validate_transform(original, without_debug(original), "x64")
        self.assertTrue(result["declaredSectionContentUnchanged"])
        self.assertEqual(result["knownRawAlignmentPaddingChanges"], [])

    def test_live_byte_rva_import_and_unwind_directory_mutations_are_rejected(self):
        original = image()
        transformed = without_debug(original)
        _, rows = SYMBOLS.sections(transformed)
        changes = [rows[".text"]["pointer"] + 3, rows[".rdata"]["pointer"] + 88]
        pe = struct.unpack_from("<I", original, 60)[0]
        changes += [pe + 24 + 16, pe + 24 + 112 + 3 * 8]
        for offset in changes:
            changed = bytearray(transformed)
            changed[offset] ^= 1
            with self.subTest(offset=offset), self.assertRaises(SYMBOLS.SymbolsError):
                SYMBOLS.validate_transform(original, bytes(changed), "x64")

    def test_unknown_coff_optional_fields_and_derived_sizes_are_rejected(self):
        original = image()
        transformed = without_debug(original)
        pe = struct.unpack_from("<I", original, 60)[0]
        # Timestamp, subsystem versions, reserved/loader flags, image/header/init/code sizes.
        offsets = [pe + 8] + [pe + 24 + value for value in [4, 8, 40, 48, 52, 56, 60, 64, 104]]
        for offset in offsets:
            changed = bytearray(transformed)
            changed[offset] ^= 1
            with self.subTest(offset=offset), self.assertRaises(SYMBOLS.SymbolsError):
                SYMBOLS.validate_transform(original, bytes(changed), "x64")

    def test_only_exact_arm_code_alignment_tail_pattern_is_accepted(self):
        original = image(machine=0xAA64)
        transformed = without_debug(original, arm_padding=True)
        result = SYMBOLS.validate_transform(original, transformed, "arm64")
        self.assertEqual(result["knownRawAlignmentPaddingChanges"], [
            {"section": ".text", "offset": 16, "bytes": 496, "originalByte": "00", "transformedByte": "cc"}])
        changed = bytearray(transformed)
        _, rows = SYMBOLS.sections(transformed)
        changed[rows[".text"]["pointer"] + 20] = 0x90
        with self.assertRaisesRegex(SYMBOLS.SymbolsError, "unknown raw"):
            SYMBOLS.validate_transform(original, bytes(changed), "arm64")
        with self.assertRaises(SYMBOLS.SymbolsError):
            SYMBOLS.validate_transform(image(), without_debug(image(), arm_padding=True), "x64")

    def test_changed_noncode_padding_is_never_ignored(self):
        original = image()
        changed = bytearray(without_debug(original))
        _, rows = SYMBOLS.sections(original)
        changed[rows[".rdata"]["pointer"] + 500] = 0xCC
        with self.assertRaisesRegex(SYMBOLS.SymbolsError, "padding"):
            SYMBOLS.validate_transform(original, bytes(changed), "x64")

    def test_codeview_file_pointer_may_move_only_with_the_same_resolved_payload(self):
        original = image(codeview=True)
        transformed = bytearray(without_debug(original))
        pe = struct.unpack_from("<I", original, 60)[0]
        table = pe + 24 + struct.unpack_from("<H", original, pe + 20)[0]
        # A smaller header moves raw file positions, never their virtual addresses.
        del transformed[512:1024]
        for at in [table, table + 40]:
            pointer = struct.unpack_from("<I", transformed, at + 20)[0]
            struct.pack_into("<I", transformed, at + 20, pointer - 512)
        struct.pack_into("<I", transformed, 512 + 256 + 24, 512 + 288)
        result = SYMBOLS.validate_transform(original, bytes(transformed), "x64")
        self.assertEqual(len(result["codeViewFilePointerChanges"]), 1)
        transformed[512 + 288] ^= 1
        with self.assertRaisesRegex(SYMBOLS.SymbolsError, "payload changed"):
            SYMBOLS.validate_transform(original, bytes(transformed), "x64")

    def test_unchanged_but_stale_codeview_file_pointer_is_refused(self):
        original = image(codeview=True)
        transformed = bytearray(without_debug(original))
        pe = struct.unpack_from("<I", original, 60)[0]
        table = pe + 24 + struct.unpack_from("<H", original, pe + 20)[0]
        del transformed[512:1024]
        for at in [table, table + 40]:
            pointer = struct.unpack_from("<I", transformed, at + 20)[0]
            struct.pack_into("<I", transformed, at + 20, pointer - 512)
        # The unchanged tuple now points512bytes beyond the payload's actual file position.
        with self.assertRaisesRegex(SYMBOLS.SymbolsError, "file pointer"):
            SYMBOLS.validate_transform(original, bytes(transformed), "x64")

    def test_remaining_debug_section_and_foreign_architecture_are_refused(self):
        original = image()
        with self.assertRaisesRegex(SYMBOLS.SymbolsError, "debug sections"):
            SYMBOLS.validate_transform(original, original, "x64")
        with self.assertRaisesRegex(SYMBOLS.SymbolsError, "architecture"):
            SYMBOLS.validate_transform(original, without_debug(original), "arm64")


class OwnedTransformTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name).resolve()
        self.source = self.root / "build.exe"
        self.source.write_bytes(image())
        self.output = self.root / "SpeakWindows.exe"
        self.tool = self.root / "llvm-objcopy"
        self.tool.write_bytes(b"authenticated fixture tool")

    def fake_tool(self, command, **kwargs):
        self.assertEqual(pathlib.Path(command[0]), self.tool)
        self.assertLessEqual(kwargs["timeout"], 30)
        if command[1] == "--version":
            return subprocess.CompletedProcess(command, 0, stdout=b"LLVM fixture 20.1.8\n")
        self.assertEqual(command[1], "--strip-debug")
        self.assertEqual(pathlib.Path(command[2]), self.root / ("diagnostic-symbols/SpeakWindows.exe." + SYMBOLS.sha256(self.source.read_bytes()) + ".unstripped"))
        pathlib.Path(command[3]).write_bytes(without_debug(self.source.read_bytes()))
        return subprocess.CompletedProcess(command, 0)

    def transform(self):
        return SYMBOLS.transform(self.source, self.output, self.tool, "x64", "a" * 40)

    def test_original_retained_transformed_identity_and_exact_fixed_argv(self):
        with mock.patch.object(SYMBOLS.subprocess, "run", side_effect=self.fake_tool) as run:
            result = self.transform()
        self.assertEqual(run.call_count, 2)
        self.assertEqual(result["sourceCommit"], "a" * 40)
        self.assertEqual(result["retainedSHA256"], result["originalSHA256"])
        self.assertEqual(result["transformedSHA256"], hashlib.sha256(self.output.read_bytes()).hexdigest())
        self.assertEqual(self.source.read_bytes(), image())
        self.assertEqual((self.root / result["retainedPath"]).read_bytes(), image())
        self.assertEqual(list(self.root.glob(".production-symbols-*")), [])

    def test_failed_timeout_or_mutated_live_bytes_never_publish_output(self):
        for failure in [subprocess.TimeoutExpired(["tool"], 30), subprocess.CalledProcessError(9, ["tool"]), None]:
            with self.subTest(failure=type(failure).__name__):
                def fail(command, **kwargs):
                    if command[1] == "--version":
                        return self.fake_tool(command, **kwargs)
                    if failure is not None:
                        raise failure
                    result = self.fake_tool(command, **kwargs)
                    path = pathlib.Path(command[3]);data = bytearray(path.read_bytes());data[-512] ^= 1
                    path.write_bytes(data)
                    return result
                with mock.patch.object(SYMBOLS.subprocess, "run", side_effect=fail), self.assertRaises(SYMBOLS.SymbolsError):
                    self.transform()
                self.assertFalse(self.output.exists())
                self.assertEqual(list(self.root.glob(".production-symbols-*")), [])

    def test_owned_cross_output_replacement_reuses_and_preserves_hash_keyed_originals(self):
        with mock.patch.object(SYMBOLS.subprocess, "run", side_effect=self.fake_tool):
            first = SYMBOLS.transform(self.source, self.output, self.tool, "x64", "a" * 40, replace_existing=True)
            second = SYMBOLS.transform(self.source, self.output, self.tool, "x64", "a" * 40, replace_existing=True)
            self.assertEqual(first, second)
            modified = bytearray(self.source.read_bytes())
            _, rows = SYMBOLS.sections(modified)
            modified[rows[".text"]["pointer"]] ^= 1
            self.source.write_bytes(modified)
            third = SYMBOLS.transform(self.source, self.output, self.tool, "x64", "b" * 40, replace_existing=True)
        self.assertNotEqual(first["retainedPath"], third["retainedPath"])
        self.assertEqual((self.root / first["retainedPath"]).read_bytes(), image())
        self.assertEqual((self.root / third["retainedPath"]).read_bytes(), modified)
        self.assertEqual(SYMBOLS.sha256(self.output.read_bytes()), third["transformedSHA256"])

    def test_failed_replacement_preserves_previous_output_and_allows_retry(self):
        self.output.write_bytes(b"prior owned output")
        with mock.patch.object(SYMBOLS.subprocess, "run", side_effect=subprocess.TimeoutExpired(["tool"], 10)):
            with self.assertRaises(SYMBOLS.SymbolsError):
                SYMBOLS.transform(self.source, self.output, self.tool, "x64", "a" * 40, replace_existing=True)
        self.assertEqual(self.output.read_bytes(), b"prior owned output")
        with mock.patch.object(SYMBOLS.subprocess, "run", side_effect=self.fake_tool):
            result = SYMBOLS.transform(self.source, self.output, self.tool, "x64", "a" * 40, replace_existing=True)
        self.assertEqual(SYMBOLS.sha256(self.output.read_bytes()), result["transformedSHA256"])
        self.assertEqual(len(list((self.root / "diagnostic-symbols").iterdir())), 1)

    def test_replacement_refuses_symlink_and_tampered_retained_original(self):
        self.output.symlink_to(self.source)
        with self.assertRaises(SYMBOLS.SymbolsError):
            SYMBOLS.transform(self.source, self.output, self.tool, "x64", "a" * 40, replace_existing=True)
        self.output.unlink()
        retained = self.root / ("diagnostic-symbols/SpeakWindows.exe." + SYMBOLS.sha256(self.source.read_bytes()) + ".unstripped")
        retained.parent.mkdir()
        retained.write_bytes(b"wrong original")
        with self.assertRaisesRegex(SYMBOLS.SymbolsError, "content hash"):
            self.transform()

    def test_invalid_utf8_tool_version_preserves_previous_output_before_transform(self):
        self.output.write_bytes(b"prior owned output")
        invalid = subprocess.CompletedProcess([str(self.tool), "--version"], 0, stdout=b"\xff")
        with mock.patch.object(SYMBOLS.subprocess, "run", return_value=invalid) as invoke:
            with self.assertRaises(SYMBOLS.SymbolsError):
                SYMBOLS.transform(self.source, self.output, self.tool, "x64", "a" * 40, replace_existing=True)
        self.assertEqual(invoke.call_count, 1)
        self.assertEqual(invoke.call_args.args[0], [str(self.tool), "--version"])
        self.assertEqual(self.output.read_bytes(), b"prior owned output")
        self.assertEqual(list(self.root.glob(".production-symbols-*")), [])
        self.assertEqual(self.source.read_bytes(), image())

    def test_tool_identity_change_is_refused_even_after_valid_output(self):
        def changed(command, **kwargs):
            result = self.fake_tool(command, **kwargs)
            if command[1] == "--strip-debug":
                self.tool.write_bytes(b"replacement tool")
            return result
        with mock.patch.object(SYMBOLS.subprocess, "run", side_effect=changed), self.assertRaisesRegex(
                SYMBOLS.SymbolsError, "changed"):
            self.transform()
        self.assertFalse(self.output.exists())

    def test_test_exe_vendor_dll_relative_tool_and_symlink_are_refused(self):
        for destination in ["Tests.exe", "vendor.dll"]:
            with self.assertRaises(SYMBOLS.SymbolsError):
                SYMBOLS.transform(self.source, self.root / destination, self.tool, "x64", "a" * 40)
        with self.assertRaises(SYMBOLS.SymbolsError):
            SYMBOLS.transform(self.source, self.output, pathlib.Path("llvm-objcopy"), "x64", "a" * 40)
        self.tool.unlink();self.tool.symlink_to(self.source)
        with self.assertRaises(SYMBOLS.SymbolsError):
            self.transform()

    def test_diagnostic_originals_are_excluded_from_the_actual_bundle_loader(self):
        with mock.patch.object(SYMBOLS.subprocess, "run", side_effect=self.fake_tool):
            result = self.transform()
        cli = self.root / "speak.exe";cli.write_bytes(FIXTURES.build_pe())
        metadata = {"host": "Darwin", "target": "x86_64-unknown-windows-msvc", "configuration": "release",
                    "appBuiltForTesting": False, "executables": {
                        "SpeakWindows.exe": result["transformedSHA256"], "speak.exe": SYMBOLS.sha256(cli.read_bytes())}}
        (self.root / "app-build-metadata.json").write_text(json.dumps(metadata))
        loaded = FIXTURES.BUILD.load_application(self.root, FIXTURES.BUILD.Policy.load())
        self.assertEqual(set(loaded["executables"]), {"SpeakWindows.exe", "speak.exe"})
        self.assertEqual(loaded["resources"], {})
        self.assertEqual((self.root / result["retainedPath"]).read_bytes(), image())


if __name__ == "__main__":
    unittest.main()
