#!/usr/bin/env python3
"""Cabinet, MSI and Burn redistributable readers, deterministic archives and readobj parsing."""
import hashlib
import pathlib
import struct
import sys
import tempfile
import unittest
import zipfile

HERE = pathlib.Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
from bundle_test_fixtures import (  # noqa: E402
    BUILD,
    REDIST,
    build_burn_bundle,
    build_cabinet,
    build_compound_file,
    build_pe,
    encode_msi_name,
    msi_streams,
)


class CabinetTests(unittest.TestCase):
    def test_multi_block_mszip_extraction_uses_previous_block_history(self):
        first = bytes(range(256)) * 200
        second = first[::-1] + b"tail"
        cabinet = REDIST.Cabinet(build_cabinet([("a.bin", first), ("b.bin", second)], block_size=20000, trailing=b"SIGNATURE"))
        self.assertEqual(cabinet.names(), ["a.bin", "b.bin"])
        self.assertEqual(cabinet.trailing_bytes, 9)
        extracted = cabinet.extract()
        self.assertEqual(extracted, {"a.bin": first, "b.bin": second})
        self.assertEqual(cabinet.extract(["b.bin"]), {"b.bin": second})
        with self.assertRaisesRegex(REDIST.ExtractionError, "missing"):
            cabinet.extract(["c.bin"])

    def test_corruption_and_unsupported_layouts_are_refused(self):
        with self.assertRaisesRegex(REDIST.ExtractionError, "checksum"):
            REDIST.Cabinet(build_cabinet([("a.bin", b"x" * 100)], corrupt=True)).extract()
        with self.assertRaisesRegex(REDIST.ExtractionError, "MSZIP"):
            REDIST.Cabinet(build_cabinet([("a.bin", b"x" * 100)], compression=0x1503)).extract()
        with self.assertRaisesRegex(REDIST.ExtractionError, "spanning"):
            REDIST.Cabinet(build_cabinet([("a.bin", b"x")], flags=0x2))
        with self.assertRaisesRegex(REDIST.ExtractionError, "not a supported cabinet header"):
            REDIST.Cabinet(build_cabinet([("a.bin", b"x" * 100)])[:-10])


class CompoundFileTests(unittest.TestCase):
    def test_msi_streams_and_tables_decode_from_mini_and_regular_sectors(self):
        streams = msi_streams()
        compound = REDIST.CompoundFile(build_compound_file(streams))
        decoded = compound.streams()
        self.assertEqual(decoded, streams)
        database = REDIST.MsiDatabase(decoded)
        self.assertEqual(database.table("Media"), [{"DiskId": 1, "LastSequence": 12, "Cabinet": "cab1.cab"}])
        rows = database.table("File")
        self.assertEqual(rows, [{"File": "vcruntime140.dll_amd64", "Component_": "VC_Runtime",
                                 "FileName": "vcrunt~1.dll|vcruntime140.dll", "FileSize": 178616,
                                 "Version": "14.51.36247.0", "Sequence": 10}])
        self.assertEqual(REDIST.long_name(rows[0]["FileName"]), "vcruntime140.dll")
        with self.assertRaisesRegex(REDIST.ExtractionError, "table missing"):
            database.table("Directory")

    def test_name_encoding_round_trips_and_corruption_is_detected(self):
        for name in ["!_StringPool", "!File", "Binary.WixDepCA", "SummaryInformation"]:
            self.assertEqual(REDIST.decode_msi_name(encode_msi_name(name)), name)
        data = bytearray(build_compound_file(msi_streams()))
        struct.pack_into("<I", data, 0x30, 0x7FFFFFF0)
        with self.assertRaises(REDIST.ExtractionError):
            REDIST.CompoundFile(bytes(data))
        with self.assertRaises(REDIST.ExtractionError):
            REDIST.CompoundFile(b"\0" * 1024)


class BurnBundleTests(unittest.TestCase):
    def test_declared_containers_are_located_after_signatures_and_decoys(self):
        ux = build_cabinet([("0", b"<BurnManifest/>")])
        attached = build_cabinet([("a0", b"payload" * 100)])
        decoy = b"MSCF" + b"\0" * 32
        bundle = build_burn_bundle([ux, attached], stub_padding=decoy)
        bundle = bundle.replace(ux + attached, ux + b"AUTHENTICODE" + decoy + attached)
        offsets = REDIST.burn_containers(bundle)
        self.assertEqual([bundle[offset:offset + size] for offset, size in offsets], [ux, attached])

    def test_size_mismatch_and_missing_section_are_refused(self):
        ux = build_cabinet([("0", b"<BurnManifest/>")])
        bundle = build_burn_bundle([ux, build_cabinet([("a0", b"x")])])
        with self.assertRaisesRegex(REDIST.ExtractionError, "not found"):
            REDIST.burn_containers(bundle[:-4])
        with self.assertRaisesRegex(REDIST.ExtractionError, "wixburn"):
            REDIST.burn_containers(build_pe(["KERNEL32.dll"]))

    def test_payload_digests_by_length(self):
        blob = b"payload"
        self.assertTrue(REDIST.payload_digest(blob, hashlib.sha1(blob).hexdigest().upper()))
        self.assertTrue(REDIST.payload_digest(blob, hashlib.sha512(blob).hexdigest()))
        self.assertFalse(REDIST.payload_digest(blob, hashlib.sha256(b"other").hexdigest()))
        with self.assertRaises(REDIST.ExtractionError):
            REDIST.payload_digest(blob, "abc")


class DeterministicArchiveTests(unittest.TestCase):
    def test_identical_inputs_produce_identical_bytes_regardless_of_order(self):
        entries = {"b/second.txt": b"two", "a.txt": b"one" * 1000, "SpeakWindows.exe": build_pe(["KERNEL32.dll"])}
        with tempfile.TemporaryDirectory() as scratch:
            first, second = pathlib.Path(scratch, "1.zip"), pathlib.Path(scratch, "2.zip")
            names = BUILD.write_deterministic_zip(first, entries)
            BUILD.write_deterministic_zip(second, dict(reversed(list(entries.items()))))
            self.assertEqual(first.read_bytes(), second.read_bytes())
            self.assertEqual(names, ["SpeakWindows.exe", "a.txt", "b/second.txt"])
            with zipfile.ZipFile(first) as archive:
                for info in archive.infolist():
                    self.assertEqual(info.date_time, BUILD.ZIP_TIMESTAMP)
                    self.assertEqual(info.external_attr, 0o100644 << 16)
                    self.assertEqual(info.extra, b"")
                    self.assertEqual(info.compress_type, zipfile.ZIP_DEFLATED)
                self.assertEqual(archive.read("a.txt"), b"one" * 1000)
            changed = dict(entries, **{"a.txt": b"one" * 999 + b"ONE"})
            BUILD.write_deterministic_zip(second, changed)
            self.assertNotEqual(first.read_bytes(), second.read_bytes())


class ReadobjParsingTests(unittest.TestCase):
    def test_static_and_delay_sections_are_separated(self):
        text = "\n".join(["File: x.exe", "Format: COFF-x86-64", "Import {", "  Name: KERNEL32.dll",
                          "  ImportLookupTableRVA: 0x1", "  Symbol:  (1)", "}", "DelayImport {", "  Name: Foundation.dll",
                          "  Attributes: 0x1", "}", "Import {", "  Name: USER32.dll", "}"])
        self.assertEqual(BUILD.parse_llvm_readobj_imports(text), (["KERNEL32.dll", "USER32.dll"], ["Foundation.dll"]))

    def test_only_the_native_view_of_an_arm64x_image_is_read(self):
        # Shape of llvm-readobj 20 output for Microsoft's ARM64X msvcp140.dll:
        # the ARM64EC view follows under HybridObject and is not what a native
        # ARM64 process loads.
        text = "\n".join(["File: msvcp140.dll", "Format: COFF-ARM64X", "Arch: aarch64", "Import {",
                          "  Name: VCRUNTIME140.dll", "}", "Import {", "  Name: KERNEL32.dll", "}",
                          "HybridObject {", "  Format: COFF-ARM64EC", "  Import {", "    Name: VCRUNTIME140.dll", "  }",
                          "  Import {", "    Name: VCRUNTIME140_1.dll", "  }", "  DelayImport {",
                          "    Name: ADVAPI32.dll", "  }", "}"])
        self.assertEqual(BUILD.parse_llvm_readobj_imports(text), (["VCRUNTIME140.dll", "KERNEL32.dll"], []))


if __name__ == "__main__":
    unittest.main()
