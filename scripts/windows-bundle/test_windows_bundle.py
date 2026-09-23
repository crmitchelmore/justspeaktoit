#!/usr/bin/env python3
"""Unit tests for the Windows runtime bundle tooling; no downloads or caches."""
import hashlib
import importlib.util
import io
import json
import math
import pathlib
import struct
import tempfile
import unittest
import zipfile
import zlib

HERE = pathlib.Path(__file__).resolve().parent


def load(name, file_name):
    spec = importlib.util.spec_from_file_location(name, HERE / file_name)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PE = load("windows_pe", "windows_pe.py")
REDIST = load("redistributables", "redistributables.py")
BUILD = load("build_windows_bundle", "build-windows-bundle.py")


# --- synthetic PE images ----------------------------------------------------------
def version_block(file_version, strings):
    def block(key, value, kind, children=(), value_length=None):
        out = bytearray(struct.pack("<HHH", 0, len(value) if value_length is None else value_length, kind))
        out += key.encode("utf-16-le") + b"\0\0"
        out += b"\0" * (-len(out) % 4)
        out += value
        for child in children:
            out += b"\0" * (-len(out) % 4)
            out += child
        struct.pack_into("<H", out, 0, len(out))
        return bytes(out)

    major, minor, build, revision = file_version
    fixed = struct.pack("<13I", 0xFEEF04BD, 0x10000, (major << 16) | minor, (build << 16) | revision,
                        (major << 16) | minor, (build << 16) | revision, 0x3F, 0, 4, 1, 0, 0, 0)
    entries = [block(key, value.encode("utf-16-le") + b"\0\0", 1, value_length=len(value) + 1)
               for key, value in strings.items()]
    table = block("040904B0", b"", 1, entries)
    info = block("StringFileInfo", b"", 1, [table])
    return block("VS_VERSION_INFO", fixed, 0, [info])


def build_pe(imports=(), delay_imports=(), machine=PE.IMAGE_FILE_MACHINE_AMD64, dll=False, version=None,
             legacy_delay=False, wixburn=None, image_base=0x140000000):
    """Build a minimal PE32+ image with import, delay-load, resource and optional .wixburn sections."""
    rdata = bytearray()
    import_table = (len(imports) + 1) * 20
    delay_table_offset = (import_table + 7) & ~7
    delay_table = (len(delay_imports) + 1) * 32
    rdata += b"\0" * (delay_table_offset + delay_table)

    def add(blob):
        while len(rdata) % 8:
            rdata.append(0)
        offset = len(rdata)
        rdata.extend(blob)
        return offset

    rdata_rva = 0x1000
    descriptors = []
    for name in imports:
        name_offset = add(name.encode("ascii") + b"\0")
        lookup = add(struct.pack("<QQ", 1 << 63 | 1, 0))
        address = add(struct.pack("<QQ", 1 << 63 | 1, 0))
        descriptors.append(struct.pack("<IIIII", rdata_rva + lookup, 0, 0, rdata_rva + name_offset, rdata_rva + address))
    descriptors.append(b"\0" * 20)
    rdata[0:import_table] = b"".join(descriptors)
    delayed = []
    for name in delay_imports:
        name_offset = add(name.encode("ascii") + b"\0")
        handle = add(b"\0" * 8)
        address = add(struct.pack("<QQ", 1 << 63 | 1, 0))
        lookup = add(struct.pack("<QQ", 1 << 63 | 1, 0))
        # Legacy descriptors (Attributes bit 0 clear) store 32-bit virtual
        # addresses, so callers pass a low image base when exercising them.
        base = image_base if legacy_delay else 0
        fields = [base + rdata_rva + field for field in (name_offset, handle, address, lookup)]
        delayed.append(struct.pack("<IIIIIIII", 0 if legacy_delay else 1, *fields, 0, 0, 0))
    delayed.append(b"\0" * 32)
    rdata[delay_table_offset:delay_table_offset + delay_table] = b"".join(delayed)
    sections = [(b".rdata", rdata_rva, bytes(rdata))]
    directories = [(0, 0)] * 16
    directories[PE.DIRECTORY_IMPORT] = (rdata_rva, import_table)
    if delay_imports:
        directories[PE.DIRECTORY_DELAY_IMPORT] = (rdata_rva + delay_table_offset, delay_table)
    if version is not None:
        rsrc_rva = 0x2000
        block = version_block(*version)
        resource = bytearray()
        resource += struct.pack("<IIHHHH", 0, 0, 0, 0, 0, 1) + struct.pack("<II", PE.RT_VERSION, 0x80000000 | 24)
        resource += struct.pack("<IIHHHH", 0, 0, 0, 0, 0, 1) + struct.pack("<II", 1, 0x80000000 | 48)
        resource += struct.pack("<IIHHHH", 0, 0, 0, 0, 0, 1) + struct.pack("<II", 1033, 72)
        resource += struct.pack("<IIII", rsrc_rva + 88, len(block), 0, 0)
        resource += block
        sections.append((b".rsrc", rsrc_rva, bytes(resource)))
        directories[PE.DIRECTORY_RESOURCE] = (rsrc_rva, len(resource))
    if wixburn is not None:
        sections.append((b".wixburn", 0x3000, wixburn))
    file_alignment, headers_size = 0x200, 0x400
    optional = struct.pack("<HBBIIIIIQIIHHHHHHIIIIHHQQQQII", 0x20B, 14, 0, 0x1000, 0, 0, 0x1000, 0x1000, image_base,
                           0x1000, file_alignment, 6, 0, 0, 0, 6, 0, 0,
                           0x1000 * (len(sections) + 4), headers_size, 0, 3, 0x8160, 0x100000, 0x1000, 0x100000, 0x1000, 0, 16)
    optional += b"".join(struct.pack("<II", rva, size) for rva, size in directories)
    characteristics = 0x22 | (0x2000 if dll else 0)
    coff = struct.pack("<HHIIIHH", machine, len(sections), 0, 0, 0, len(optional), characteristics)
    header = bytearray(b"MZ" + b"\0" * 0x3A + struct.pack("<I", 0x40) + b"PE\0\0" + coff + optional)
    raw_pointer = headers_size
    table, bodies = b"", b""
    for name, rva, data in sections:
        padded = data + b"\0" * (-len(data) % file_alignment)
        table += struct.pack("<8sIIIIIIHHI", name, len(data), rva, len(padded), raw_pointer, 0, 0, 0, 0, 0x40000040)
        bodies += padded
        raw_pointer += len(padded)
    header += table
    header += b"\0" * (headers_size - len(header))
    return bytes(header) + bodies


# --- synthetic cabinets, compound files and Burn bundles ------------------------
def build_cabinet(files, block_size=32768, compression=REDIST.MSZIP, checksums=True, corrupt=False,
                  trailing=b"", flags=0):
    payload = b"".join(data for _, data in files)
    blocks = [payload[index:index + block_size] for index in range(0, len(payload), block_size)] or [b""]
    entries, offset = b"", 0
    for name, data in files:
        entries += struct.pack("<IIHHHH", len(data), offset, 0, 0x21, 0, 0x20) + name.encode() + b"\0"
        offset += len(data)
    files_offset = 36 + 8
    cab_start = files_offset + len(entries)
    encoded, history = b"", b""
    for chunk in blocks:
        compressor = zlib.compressobj(9, zlib.DEFLATED, -15, zdict=history) if history else zlib.compressobj(9, zlib.DEFLATED, -15)
        compressed = b"CK" + compressor.compress(chunk) + compressor.flush()
        history = (history + chunk)[-32768:]
        head = struct.pack("<HH", len(compressed), len(chunk))
        checksum = REDIST.cabinet_checksum(head, REDIST.cabinet_checksum(compressed)) if checksums else 0
        encoded += struct.pack("<I", checksum) + head + compressed
    total = cab_start + len(encoded)
    header = b"MSCF" + struct.pack("<IIIIIBBHHHHH", 0, total, 0, files_offset, 0, 3, 1, 1, len(files), flags, 0, 0)
    folder = struct.pack("<IHH", cab_start, len(blocks), compression)
    data = bytearray(header + folder + entries + encoded)
    if corrupt:
        data[-1] ^= 0xFF
    return bytes(data) + trailing


def encode_msi_name(name):
    output, index = [], 0
    while index < len(name):
        character = name[index]
        if character == "!":
            output.append(chr(0x4840))
            index += 1
            continue
        first = REDIST.MSI_ALPHABET.index(character)
        if index + 1 < len(name) and name[index + 1] in REDIST.MSI_ALPHABET:
            second = REDIST.MSI_ALPHABET.index(name[index + 1])
            output.append(chr(0x3800 + first + (second << 6)))
            index += 2
        else:
            output.append(chr(0x4800 + first))
            index += 1
    return "".join(output)


def build_compound_file(streams):
    sector, mini, cutoff = 512, 64, 4096
    names = list(streams)
    entries = [("Root Entry", 5)] + [(encode_msi_name(name), 2) for name in names]
    directory_sectors = math.ceil(len(entries) * 128 / sector)
    mini_stream, mini_fat, small_starts = bytearray(), [], {}
    for name in names:
        data = streams[name]
        if len(data) < cutoff and data:
            count = math.ceil(len(data) / mini)
            start = len(mini_stream) // mini
            mini_stream += data + b"\0" * (-len(data) % mini)
            mini_fat += [start + step + 1 for step in range(count - 1)] + [REDIST.CFB_END_OF_CHAIN]
            small_starts[name] = start
    mini_fat_sectors = math.ceil(len(mini_fat) * 4 / sector) if mini_fat else 0
    first_directory = 1
    first_mini_fat = first_directory + directory_sectors
    first_mini_stream = first_mini_fat + mini_fat_sectors
    mini_stream_sectors = math.ceil(len(mini_stream) / sector)
    cursor = first_mini_stream + mini_stream_sectors
    large_starts = {}
    for name in names:
        if len(streams[name]) >= cutoff:
            large_starts[name] = cursor
            cursor += math.ceil(len(streams[name]) / sector)
    total = cursor
    assert total <= sector // 4, "test compound file needs more than one FAT sector"
    fat = [REDIST.CFB_FREE] * (sector // 4)
    fat[0] = 0xFFFFFFFD

    def chain(start, count):
        for step in range(count):
            fat[start + step] = start + step + 1 if step < count - 1 else REDIST.CFB_END_OF_CHAIN

    chain(first_directory, directory_sectors)
    if mini_fat_sectors:
        chain(first_mini_fat, mini_fat_sectors)
    if mini_stream_sectors:
        chain(first_mini_stream, mini_stream_sectors)
    for name, start in large_starts.items():
        chain(start, math.ceil(len(streams[name]) / sector))
    body = bytearray(sector * total)
    struct.pack_into("<%dI" % (sector // 4), body, 0, *fat)
    for index, (title, kind) in enumerate(entries):
        raw = bytearray(128)
        encoded = title.encode("utf-16-le")
        raw[:len(encoded)] = encoded
        struct.pack_into("<HBB", raw, 64, len(encoded) + 2, kind, 1)
        struct.pack_into("<III", raw, 68, REDIST.CFB_FREE, REDIST.CFB_FREE, REDIST.CFB_FREE)
        if kind == 5:
            start, size = (first_mini_stream if mini_stream else 0), len(mini_stream)
        else:
            name = names[index - 1]
            data = streams[name]
            start = large_starts.get(name, small_starts.get(name, 0))
            size = len(data)
        struct.pack_into("<IQ", raw, 116, start, size)
        position = first_directory * sector + index * 128
        body[position:position + 128] = raw
    if mini_fat:
        struct.pack_into("<%dI" % len(mini_fat), body, first_mini_fat * sector, *mini_fat)
    body[first_mini_stream * sector:first_mini_stream * sector + len(mini_stream)] = mini_stream
    for name, start in large_starts.items():
        body[start * sector:start * sector + len(streams[name])] = streams[name]
    header = bytearray(sector)
    header[:8] = REDIST.CFB_SIGNATURE
    struct.pack_into("<HHHHH", header, 0x18, 0x3E, 3, 0xFFFE, 9, 6)
    struct.pack_into("<IIIIIIII", header, 0x2C, 1, first_directory, 0, cutoff, first_mini_fat if mini_fat else REDIST.CFB_END_OF_CHAIN,
                     mini_fat_sectors, REDIST.CFB_END_OF_CHAIN, 0)
    struct.pack_into("<109I", header, 0x4C, 0, *([REDIST.CFB_FREE] * 108))
    return bytes(header) + bytes(body)


def msi_streams(codepage=1252):
    strings = ["File", "Component_", "FileName", "FileSize", "Version", "Sequence", "Media", "DiskId", "LastSequence",
               "Cabinet", "vcruntime140.dll_amd64", "VC_Runtime", "vcrunt~1.dll|vcruntime140.dll", "14.51.36247.0",
               "cab1.cab"]
    reference = {value: index + 1 for index, value in enumerate(strings)}
    pool = struct.pack("<HH", codepage, 0) + b"".join(struct.pack("<HH", len(value), 1) for value in strings)
    data = "".join(strings).encode("cp1252")
    schema = [("File", 1, "File", 0x8000 | 0x2D48), ("File", 2, "Component_", 0x8000 | 0x0D48),
              ("File", 3, "FileName", 0x8000 | 0x0DFF), ("File", 4, "FileSize", 0x8000 | 0x0104),
              ("File", 5, "Version", 0x8000 | 0x1D48), ("File", 6, "Sequence", 0x8000 | 0x0102),
              ("Media", 1, "DiskId", 0x8000 | 0x2102), ("Media", 2, "LastSequence", 0x8000 | 0x0102),
              ("Media", 3, "Cabinet", 0x8000 | 0x1DFF)]
    columns = b""
    for column in range(4):
        for table, number, name, kind in schema:
            value = [reference[table], number + 0x8000, reference[name], kind][column]
            columns += struct.pack("<H", value)
    file_rows = struct.pack("<H", reference["vcruntime140.dll_amd64"]) + struct.pack("<H", reference["VC_Runtime"])
    file_rows += struct.pack("<H", reference["vcrunt~1.dll|vcruntime140.dll"]) + struct.pack("<I", 178616 + (1 << 31))
    file_rows += struct.pack("<H", reference["14.51.36247.0"]) + struct.pack("<H", 10 + 0x8000)
    media_rows = struct.pack("<HHH", 1 + 0x8000, 12 + 0x8000, reference["cab1.cab"])
    return {"!_StringPool": pool, "!_StringData": data, "!_Columns": columns, "!File": file_rows, "!Media": media_rows,
            "Binary.Large": bytes(range(256)) * 20}


def build_burn_bundle(containers, stub_padding=b""):
    stub_size = len(build_pe(imports=["KERNEL32.dll"], wixburn=b"\0" * 64)) + len(stub_padding)
    sizes = [len(container) for container in containers]
    section = struct.pack("<II", REDIST.BURN_MAGIC, 2) + b"\x11" * 16
    section += struct.pack("<IIIIII", stub_size, 0, 0, 0, REDIST.BURN_FORMAT_CAB, len(sizes))
    section += b"".join(struct.pack("<I", size) for size in sizes)
    section += b"\0" * (64 - len(section))
    stub = build_pe(imports=["KERNEL32.dll"], wixburn=section) + stub_padding
    return stub + b"".join(containers)


# --- tests ------------------------------------------------------------------------
class PEReaderTests(unittest.TestCase):
    def test_static_and_delay_imports_are_read_in_table_order(self):
        image = PE.PEImage(build_pe(["KERNEL32.dll", "swiftCore.dll"], ["Foundation.dll", "WINHTTP.dll"]))
        self.assertTrue(image.is_x64)
        self.assertFalse(image.is_dll)
        self.assertEqual(image.imports(), ["KERNEL32.dll", "swiftCore.dll"])
        self.assertEqual(image.delay_imports(), ["Foundation.dll", "WINHTTP.dll"])

    def test_legacy_delay_descriptors_use_virtual_addresses(self):
        image = PE.PEImage(build_pe(["KERNEL32.dll"], ["dbghelp.dll"], legacy_delay=True, image_base=0x400000))
        self.assertEqual(image.delay_imports(), ["dbghelp.dll"])
        # A legacy descriptor whose stored address is below the image base cannot be translated.
        data = bytearray(build_pe(["KERNEL32.dll"], ["dbghelp.dll"], legacy_delay=True, image_base=0x400000))
        struct.pack_into("<I", data, 0x400 + 40 + 4, 0x1000)
        with self.assertRaisesRegex(PE.PEFormatError, "below the image base"):
            PE.PEImage(bytes(data)).delay_imports()

    def test_import_directories_must_contain_complete_descriptors_and_terminator(self):
        for directory, method, width in [(1, "imports", 20), (13, "delay_imports", 32)]:
            for invalid_size in [1, width]:
                data = bytearray(build_pe(["KERNEL32.dll"], ["Foundation.dll"]))
                struct.pack_into("<I", data, 0x40 + 24 + 112 + directory * 8 + 4, invalid_size)
                with self.assertRaises(PE.PEFormatError):
                    getattr(PE.PEImage(data), method)()

    def test_descriptor_may_not_cross_mapped_section_boundary(self):
        data = bytearray(build_pe(["KERNEL32.dll"]))
        # Raw section ends 19 bytes into the descriptor, although file bytes remain.
        struct.pack_into("<I", data, 0x40 + 24 + 240 + 16, 19)
        with self.assertRaises(PE.PEFormatError):
            PE.PEImage(data).imports()

    def test_optional_and_version_lengths_are_checked(self):
        with self.assertRaises(PE.PEFormatError):
            PE.PEImage(build_pe()[:0x40 + 24 + 120])
        block = bytearray(version_block((1, 2, 3, 4), {}))
        struct.pack_into("<H", block, 0, len(block) + 1)
        with self.assertRaises(PE.PEFormatError):
            PE.parse_version_block(block)

    def test_dll_flag_and_foreign_machine_are_reported(self):
        image = PE.PEImage(build_pe(dll=True, machine=0x14C))
        self.assertTrue(image.is_dll)
        self.assertFalse(image.is_x64)

    def test_version_resource_is_decoded(self):
        image = PE.PEImage(build_pe(version=((14, 51, 36247, 0), {"OriginalFilename": "vcruntime140.dll",
                                                                    "CompanyName": "Microsoft Corporation"})))
        info = image.version_info()
        self.assertEqual(info["fileVersion"], "14.51.36247.0")
        self.assertEqual(info["strings"]["OriginalFilename"], "vcruntime140.dll")
        self.assertIsNone(PE.PEImage(build_pe()).version_info())

    def test_truncated_and_non_pe_input_raise_format_errors(self):
        data = build_pe(["KERNEL32.dll"])
        with self.assertRaises(PE.PEFormatError):
            PE.PEImage(data[:0x300])
        with self.assertRaises(PE.PEFormatError):
            PE.PEImage(b"not a pe file" * 100)
        broken = bytearray(data)
        struct.pack_into("<I", broken, 0x3C, 0x7FFFFFF0)
        with self.assertRaises(PE.PEFormatError):
            PE.PEImage(bytes(broken))

    def test_import_name_outside_the_image_is_rejected(self):
        data = bytearray(build_pe(["KERNEL32.dll"]))
        struct.pack_into("<I", data, 0x400 + 12, 0x9000)
        with self.assertRaisesRegex(PE.PEFormatError, "outside every section"):
            PE.PEImage(bytes(data)).imports()


class ClosureTests(unittest.TestCase):
    GRAPH = {
        "SpeakWindows.exe": (["USER32.dll", "swiftCore.dll", "MSVCP140.dll", "api-ms-win-crt-runtime-l1-1-0.dll"],
                             ["Foundation.dll"]),
        "swiftCore.dll": (["KERNEL32.dll", "VCRUNTIME140.dll", "MSVCP140.dll"], []),
        "Foundation.dll": (["swiftCore.dll", "_FoundationICU.dll", "FoundationNetworking.dll"], []),
        "FoundationNetworking.dll": (["Foundation.dll", "swiftCore.dll", "CRYPT32.dll"], []),
        "_FoundationICU.dll": (["msvcp140.dll", "kernel32.dll"], []),
        "msvcp140.dll": (["vcruntime140.dll", "api-ms-win-crt-heap-l1-1-0.dll"], []),
        "vcruntime140.dll": (["KERNEL32.dll"], []),
    }

    def setUp(self):
        self.policy = BUILD.Policy.load()

    def read(self, graph):
        def read_imports(name, category):
            self.assertIn(category, ("application", BUILD.SWIFT_RUNTIME, BUILD.MICROSOFT_RUNTIME))
            return graph[name]
        return read_imports

    def test_closure_includes_delay_and_transitive_dependencies_once(self):
        closure = BUILD.resolve_closure("SpeakWindows.exe", self.read(self.GRAPH), self.policy)
        self.assertEqual(list(closure["bundled"]), ["_foundationicu.dll", "foundation.dll", "foundationnetworking.dll",
                                                    "msvcp140.dll", "swiftcore.dll", "vcruntime140.dll"])
        self.assertEqual(closure["bundled"]["msvcp140.dll"]["name"], "msvcp140.dll")
        self.assertEqual(closure["bundled"]["foundation.dll"]["importedBy"],
                         [{"importer": "SpeakWindows.exe", "kind": "delay"},
                          {"importer": "FoundationNetworking.dll", "kind": "static"}])
        self.assertEqual({entry["source"] for entry in closure["bundled"].values()},
                         {BUILD.SWIFT_RUNTIME, BUILD.MICROSOFT_RUNTIME})
        self.assertEqual(list(closure["system"]), ["api-ms-win-crt-heap-l1-1-0.dll", "api-ms-win-crt-runtime-l1-1-0.dll",
                                                   "crypt32.dll", "kernel32.dll", "user32.dll"])
        self.assertEqual([entry["importer"] for entry in closure["system"]["kernel32.dll"]["importedBy"]],
                         ["swiftCore.dll", "vcruntime140.dll", "_FoundationICU.dll"])

    def test_unknown_non_system_module_is_refused_with_its_importer(self):
        graph = dict(self.GRAPH)
        graph["swiftCore.dll"] = (["KERNEL32.dll", "libcurl.dll"], [])
        with self.assertRaisesRegex(BUILD.BundleError, "swiftCore.dll imports libcurl.dll"):
            BUILD.resolve_closure("SpeakWindows.exe", self.read(graph), self.policy)

    def test_test_library_import_is_refused_even_transitively(self):
        graph = dict(self.GRAPH)
        graph["Foundation.dll"] = (["swiftCore.dll"], ["XCTest.dll"])
        with self.assertRaisesRegex(BUILD.BundleError, "test library XCTest.dll"):
            BUILD.resolve_closure("SpeakWindows.exe", self.read(graph), self.policy)

    def test_additional_runtime_modules_are_bundled_and_traversed(self):
        policy = BUILD.Policy(dict(self.policy.data, additionalRuntimeModules=["swiftSwiftOnoneSupport.dll"]))
        graph = dict(self.GRAPH, **{"swiftSwiftOnoneSupport.dll": (["swiftCore.dll", "swiftWinSDK.dll"], []),
                                    "swiftWinSDK.dll": (["swiftCore.dll"], [])})
        closure = BUILD.resolve_closure("SpeakWindows.exe", self.read(graph), policy)
        self.assertIn("swiftwinsdk.dll", closure["bundled"])
        self.assertEqual(closure["bundled"]["swiftswiftononesupport.dll"]["importedBy"][0]["kind"], "runtime-loaded")

    def test_policy_rejects_overlapping_categories_and_unknown_additions(self):
        with self.assertRaisesRegex(BUILD.BundleError, "more than one category"):
            BUILD.Policy(dict(self.policy.data, windowsSystemModules=["kernel32.dll", "swiftCore.dll"]))
        with self.assertRaisesRegex(BUILD.BundleError, "additionalRuntimeModules"):
            BUILD.Policy(dict(self.policy.data, additionalRuntimeModules=["kernel32.dll"]))

    def test_policy_classification_and_forbidden_patterns(self):
        policy = self.policy
        self.assertEqual(policy.classify("API-MS-WIN-CORE-SYNCH-L1-2-0.dll"), BUILD.SYSTEM_MODULE)
        self.assertEqual(policy.classify("ucrtbase.dll"), BUILD.SYSTEM_MODULE)
        self.assertEqual(policy.classify("api-ms-win-crt-private-l1-1-0.dll"), BUILD.SYSTEM_MODULE)
        self.assertEqual(policy.classify("ext-ms-win-something-l1-1-0.dll"), BUILD.UNKNOWN_MODULE)
        self.assertEqual(policy.classify("Testing.dll"), BUILD.TEST_MODULE)
        for path in ["swiftCore.lib", "usr/include/module.modulemap", "SpeakAppPackageTests.exe", "XCTest.dll",
                     "SpeakApp_SpeakWindowsPlatformTests.resources/Fixtures/tone.m4a", "plutil.exe", "app.pdb",
                     "lib/swift/windows/Foundation.swiftmodule", "rtl.msi"]:
            self.assertTrue(policy.forbids(path), path)
        for path in ["SpeakWindows.exe", "swiftCore.dll", "SpeakApp_SpeakCore.resources/Info.plist",
                     "bundle-manifest.json", "licenses/LICENSE-swift.txt"]:
            self.assertFalse(policy.forbids(path), path)


class PathSafetyTests(unittest.TestCase):
    def test_unsafe_components_are_rejected(self):
        for path in ["../x.dll", "a/../b", "/abs", "a\\b", "C:/x", "", "con", "CON.dll", "nul.txt", "com1.dll",
                     "a./b", " a", "a ", "tab\there", "a<.txt", "a>.txt", 'a".txt',
                     "a|.txt", "a?.txt", "a*.txt", "dir/bad?.txt"]:
            with self.assertRaises(BUILD.BundleError, msg=path):
                BUILD.check_bundle_path(path)
        self.assertEqual(BUILD.check_bundle_path("SpeakApp_SpeakCore.resources/Info.plist"),
                         "SpeakApp_SpeakCore.resources/Info.plist")

    def test_output_separation_rejects_equal_and_nested_paths(self):
        app, cache = pathlib.Path("/app"), pathlib.Path("/cache")
        for output in [app, cache, app / "bundle", cache / "bundle", pathlib.Path("/")]:
            with self.assertRaises(BUILD.BundleError):
                BUILD.check_output_separation(app, cache, output)
        BUILD.check_output_separation(app, cache, pathlib.Path("/bundle"))

    def test_layout_rejects_case_collisions_forbidden_files_and_file_directory_clashes(self):
        policy = BUILD.Policy.load()
        with self.assertRaisesRegex(BUILD.BundleError, "case-insensitive"):
            BUILD.check_bundle_layout(["Foundation.dll", "foundation.DLL"], policy)
        with self.assertRaisesRegex(BUILD.BundleError, "forbids"):
            BUILD.check_bundle_layout(["SpeakWindows.exe", "swiftCore.lib"], policy)
        with self.assertRaisesRegex(BUILD.BundleError, "share a name"):
            BUILD.check_bundle_layout(["licenses", "licenses/LICENSE-swift.txt"], policy)
        BUILD.check_bundle_layout(["SpeakWindows.exe", "licenses/LICENSE-swift.txt", "swiftCore.dll"], policy)


class ApplicationInputTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.app = pathlib.Path(self.directory.name)
        self.policy = BUILD.Policy.load()
        self.executable = build_pe(["KERNEL32.dll", "swiftCore.dll"])
        (self.app / "SpeakWindows.exe").write_bytes(self.executable)
        (self.app / "SpeakAppPackageTests.exe").write_bytes(build_pe(["XCTest.dll"]))
        (self.app / "SpeakApp_SpeakCore.resources").mkdir()
        (self.app / "SpeakApp_SpeakCore.resources/Info.plist").write_bytes(b"<plist/>")
        (self.app / "SpeakApp_SpeakWindowsPlatformTests.resources/Fixtures").mkdir(parents=True)
        (self.app / "SpeakApp_SpeakWindowsPlatformTests.resources/Fixtures/tone.m4a").write_bytes(b"audio")
        self.metadata = {"host": "Darwin", "target": "x86_64-unknown-windows-msvc", "configuration": "release",
                         "appBuiltForTesting": False, "sourceCommit": "abc",
                         "executables": {"SpeakWindows.exe": hashlib.sha256(self.executable).hexdigest()}}
        self.write_metadata()

    def write_metadata(self):
        (self.app / "app-build-metadata.json").write_text(json.dumps(self.metadata), encoding="utf-8")

    def test_production_executable_and_non_test_resources_are_loaded(self):
        application = BUILD.load_application(self.app, self.policy)
        self.assertEqual(application["executable"], self.executable)
        self.assertEqual(list(application["resources"]), ["SpeakApp_SpeakCore.resources/Info.plist"])

    def test_debug_or_test_enabled_metadata_is_refused(self):
        for key, value in [("configuration", "debug"), ("appBuiltForTesting", True), ("host", "Windows")]:
            metadata = dict(self.metadata)
            metadata[key] = value
            (self.app / "app-build-metadata.json").write_text(json.dumps(metadata), encoding="utf-8")
            with self.assertRaisesRegex(BUILD.BundleError, key):
                BUILD.load_application(self.app, self.policy)

    def test_hash_mismatch_and_test_imports_are_refused(self):
        (self.app / "SpeakWindows.exe").write_bytes(build_pe(["KERNEL32.dll"]))
        with self.assertRaisesRegex(BUILD.BundleError, "hash"):
            BUILD.load_application(self.app, self.policy)
        tested = build_pe(["KERNEL32.dll"], ["Testing.dll"])
        (self.app / "SpeakWindows.exe").write_bytes(tested)
        self.metadata["executables"]["SpeakWindows.exe"] = hashlib.sha256(tested).hexdigest()
        self.write_metadata()
        with self.assertRaisesRegex(BUILD.BundleError, "test-enabled"):
            BUILD.load_application(self.app, self.policy)

    def test_symlinked_resource_is_refused(self):
        target = self.app / "outside.txt"
        target.write_bytes(b"outside")
        (self.app / "SpeakApp_SpeakCore.resources/link.txt").symlink_to(target)
        with self.assertRaisesRegex(BUILD.BundleError, "symbolic link"):
            BUILD.load_application(self.app, self.policy)


class SwiftRuntimeSourceTests(unittest.TestCase):
    MANIFEST = ('<BurnManifest xmlns="http://wixtoolset.org/schemas/v4/2008/Burn">'
                '<Payload Id="a0" FilePath="rtl.msi" FileSize="450560" Hash="ABC" SourcePath="a0"/>'
                '<Payload Id="a7" FilePath="rtl.cab" FileSize="18542881" Hash="DEF" SourcePath="a7"/>'
                '<Payload Id="a6" FilePath="windows.msi" FileSize="1" Hash="123" SourcePath="a6"/></BurnManifest>')

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.cache = pathlib.Path(self.directory.name)
        (self.cache / "swift-windows").mkdir()
        (self.cache / "windows-extraction/bootstrap").mkdir(parents=True)
        (self.cache / "windows-extraction/bootstrap/0").write_text(self.MANIFEST, encoding="utf-8")
        data = build_pe(["KERNEL32.dll"], dll=True)
        (self.cache / "swift-windows/swiftCore.dll").write_bytes(data)
        (self.cache / "windows-extraction/rtl-layout.json").write_text(json.dumps(
            [{"path": "swiftCore.dll", "cabinet": "rtl.cab", "id": "filCore", "bytes": len(data)}]), encoding="utf-8")
        cross = json.loads((HERE.parent / "windows-cross/dependencies.json").read_text(encoding="utf-8"))
        installer = next(item for item in cross["downloads"] if item["name"].endswith("-windows10.exe"))
        self.lock_path = self.cache / "source-lock.json"
        self.lock_path.write_text(json.dumps({"swiftVersion": "6.2.3", "installer": installer,
            "bootstrapManifestSHA256": "fixture", "payloads": {
                "rtl.msi": {"bytes": 450560, "sha512": "abc"}, "rtl.cab": {"bytes": 18542881, "sha512": "def"}},
            "files": [{"path": "swiftCore.dll", "cabinet": "rtl.cab", "id": "filCore", "bytes": len(data),
                       "sha256": hashlib.sha256(data).hexdigest()}]}), encoding="utf-8")

    def test_runtime_package_provenance_and_modules_are_read(self):
        source = BUILD.load_swift_runtime(self.cache, self.lock_path)
        self.assertEqual(source["payloads"], {"rtl.msi": {"bytes": 450560, "sha512": "abc"},
                                              "rtl.cab": {"bytes": 18542881, "sha512": "def"}})
        self.assertEqual(source["swiftVersion"], "6.2.3")
        self.assertEqual(source["installer"]["name"], "swift-6.2.3-RELEASE-windows10.exe")
        data, provenance = BUILD.read_swift_module(source, "swiftCore.dll")
        self.assertEqual(provenance["fileKey"], "filCore")
        self.assertEqual(provenance["package"], "rtl.msi")
        with self.assertRaisesRegex(BUILD.BundleError, "does not provide"):
            BUILD.read_swift_module(source, "swiftWinSDK.dll")

    def test_missing_provenance_is_refused(self):
        self.lock_path.unlink()
        with self.assertRaisesRegex(BUILD.BundleError, "provenance"):
            BUILD.load_swift_runtime(self.cache, self.lock_path)

    def test_same_size_tamper_is_refused_even_with_changed_cache_metadata(self):
        path = self.cache / "swift-windows/swiftCore.dll"
        changed = bytearray(path.read_bytes())
        changed[-1] ^= 1
        path.write_bytes(changed)
        (self.cache / "windows-extraction/rtl-layout.json").write_text("[]", encoding="utf-8")
        (self.cache / "windows-extraction/bootstrap/0").write_text("substituted metadata", encoding="utf-8")
        source = BUILD.load_swift_runtime(self.cache, self.lock_path)
        with self.assertRaisesRegex(BUILD.BundleError, "checksum"):
            BUILD.read_swift_module(source, "swiftCore.dll")

    def test_source_lock_must_match_cross_installer_pin(self):
        lock = json.loads(self.lock_path.read_text(encoding="utf-8"))
        lock["installer"]["sha256"] = "0" * 64
        self.lock_path.write_text(json.dumps(lock), encoding="utf-8")
        with self.assertRaisesRegex(BUILD.BundleError, "installer"):
            BUILD.load_swift_runtime(self.cache, self.lock_path)


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


class AssemblyTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = pathlib.Path(self.directory.name)
        self.policy = BUILD.Policy.load()
        self.runtime = root / "runtime"
        self.runtime.mkdir()
        modules = {"swiftCore.dll": (["KERNEL32.dll", "VCRUNTIME140.dll", "MSVCP140.dll"], []),
                   "Foundation.dll": (["swiftCore.dll", "_FoundationICU.dll"], []),
                   "_FoundationICU.dll": (["msvcp140.dll", "KERNEL32.dll"], []),
                   "swiftWinSDK.dll": (["swiftCore.dll"], [])}
        layout = {}
        for name, (static, delayed) in modules.items():
            data = build_pe(static, delayed, dll=True)
            (self.runtime / name).write_bytes(data)
            layout[name] = {"path": name, "cabinet": "rtl.cab", "id": "fil" + name, "bytes": len(data),
                            "sha256": hashlib.sha256(data).hexdigest()}
        self.swift = {"directory": self.runtime, "layout": layout,
                      "payloads": {"rtl.msi": {"bytes": 1, "sha512": "a"}, "rtl.cab": {"bytes": 2, "sha512": "b"}},
                      "installer": {"name": "swift-6.2.3-RELEASE-windows10.exe", "sha256": "c", "bytes": 3, "url": "https://x"},
                      "swiftVersion": "6.2.3", "lockSHA256": "fixture", "bootstrapManifestSHA256": "fixture"}
        self.microsoft = {"modules": {}, "version": "14.51.36247.0",
                          "displayName": "Microsoft Visual C++ v14 Redistributable (x64) - 14.51.36247",
                          "productName": "Microsoft Visual C++ 2022 X64 Minimum Runtime - 14.51.36247"}
        for name, static in [("msvcp140.dll", ["vcruntime140.dll", "api-ms-win-crt-heap-l1-1-0.dll"]),
                             ("vcruntime140.dll", ["KERNEL32.dll"]), ("concrt140.dll", ["msvcp140.dll"])]:
            data = build_pe(static, dll=True, version=((14, 51, 36247, 0), {"OriginalFilename": name}))
            self.microsoft["modules"][name] = {"name": name, "bytes": data, "provenance": {"fileVersion": "14.51.36247.0", "fileKey": name + "_amd64"}}
        self.executable = build_pe(["USER32.dll", "swiftCore.dll", "MSVCP140.dll"], ["Foundation.dll"])
        self.application = {"metadata": {"sourceCommit": "0123456789abcdef", "configuration": "release",
                                         "target": "x86_64-unknown-windows-msvc", "appBuiltForTesting": False,
                                         "swiftCompiler": "swift", "nativeCompiler": "clang"},
                            "executable": self.executable,
                            "resources": {"SpeakApp_SpeakCore.resources/Info.plist": b"<plist/>"}}
        self.licenses = [{"name": "LICENSE-swift.txt", "url": "https://x/swift", "sha256": "d", "bytes": 5,
                          "license": "Apache License 2.0 with Runtime Library Exception", "covers": "Swift", "data": b"Apache"},
                         {"name": "LICENSE-icu.txt", "url": "https://x/icu", "sha256": "e", "bytes": 6,
                          "license": "Unicode License v3", "covers": "ICU 74.1 compiled into _FoundationICU.dll", "data": b"Unicode"}]
        self.lock = {"name": "VC_redist.x64.exe", "url": "https://x/vc", "sha256": "f", "bytes": 7,
                     "permalink": "https://aka.ms/x", "version": "14.51.36247.0"}
        self.messages = []

    def assemble(self, **overrides):
        arguments = dict(application=self.application, swift=self.swift, microsoft=self.microsoft,
                         licenses=self.licenses, app_license=b"MIT License\n", policy=self.policy, lock=self.lock,
                         cross_check=None, log=self.messages.append)
        arguments.update(overrides)
        return BUILD.assemble(**arguments)

    def test_bundle_contains_only_the_closure_resources_licences_and_notices(self):
        entries, manifest = self.assemble()
        self.assertEqual(sorted(entries), [
            "Foundation.dll", "README.txt", "SpeakApp_SpeakCore.resources/Info.plist", "SpeakWindows.exe",
            "THIRD-PARTY-NOTICES.txt", "_FoundationICU.dll", "licenses/LICENSE-JustSpeakToIt.txt",
            "licenses/LICENSE-icu.txt", "licenses/LICENSE-swift.txt", "licenses/NOTICE-microsoft-visual-cpp-runtime.txt",
            "msvcp140.dll", "swiftCore.dll", "vcruntime140.dll"])
        self.assertNotIn("swiftWinSDK.dll", entries)
        self.assertNotIn("concrt140.dll", entries)
        self.assertEqual([item["path"] for item in manifest["files"]], sorted(entries))
        for item in manifest["files"]:
            self.assertEqual(item["sha256"], hashlib.sha256(entries[item["path"]]).hexdigest())
            self.assertEqual(item["bytes"], len(entries[item["path"]]))
        self.assertEqual(list(manifest["dependencies"]["bundled"]),
                         ["_foundationicu.dll", "foundation.dll", "msvcp140.dll", "swiftcore.dll", "vcruntime140.dll"])
        self.assertEqual(sorted(manifest["dependencies"]["system"]), ["api-ms-win-crt-heap-l1-1-0.dll", "kernel32.dll", "user32.dll"])
        vcruntime = next(item for item in manifest["files"] if item["path"] == "vcruntime140.dll")
        self.assertEqual(vcruntime["fileVersion"], "14.51.36247.0")
        self.assertEqual(vcruntime["source"], BUILD.MICROSOFT_RUNTIME)
        self.assertIn("14.51.36247", entries["THIRD-PARTY-NOTICES.txt"].decode())
        self.assertIn("LICENSE-icu.txt", entries["THIRD-PARTY-NOTICES.txt"].decode())
        self.assertIn("0123456789abcdef", entries["README.txt"].decode())
        self.assertEqual(manifest["application"]["executableSHA256"], hashlib.sha256(self.executable).hexdigest())

    def test_pinned_licences_cover_embedded_networking_dependencies(self):
        lock = json.loads((HERE / "dependencies.json").read_text(encoding="utf-8"))
        for name in ["curl", "zlib"]:
            entry = next(item for item in lock["licenses"] if item["name"] == "LICENSE-" + name + ".txt")
            self.assertEqual(len(entry["sha256"]), 64)
            self.assertIn("FoundationNetworking.dll", entry["covers"])
            self.licenses.append(dict(entry, data=b"fixture licence"))
        entries, manifest = self.assemble()
        for name in ["curl", "zlib"]:
            self.assertIn("licenses/LICENSE-" + name + ".txt", entries)
            self.assertIn("LICENSE-" + name + ".txt", entries["THIRD-PARTY-NOTICES.txt"].decode())

    def test_assembly_is_deterministic(self):
        first, first_manifest = self.assemble()
        second, second_manifest = self.assemble()
        self.assertEqual(first, second)
        self.assertEqual(json.dumps(first_manifest, sort_keys=True), json.dumps(second_manifest, sort_keys=True))

    def test_runtime_module_missing_from_pinned_sources_is_refused(self):
        del self.microsoft["modules"]["vcruntime140.dll"]
        with self.assertRaisesRegex(BUILD.BundleError, "does not provide vcruntime140.dll"):
            self.assemble()
        self.setUp()
        (self.runtime / "Foundation.dll").unlink()
        with self.assertRaisesRegex(BUILD.BundleError, "does not provide Foundation.dll"):
            self.assemble()

    def test_runtime_file_size_drift_is_refused(self):
        self.swift["layout"]["swiftCore.dll"]["bytes"] += 1
        with self.assertRaisesRegex(BUILD.BundleError, "layout size"):
            self.assemble()

    def test_forbidden_resource_files_are_refused(self):
        self.application["resources"]["SpeakApp_SpeakCore.resources/swiftCore.lib"] = b"lib"
        with self.assertRaisesRegex(BUILD.BundleError, "forbids"):
            self.assemble()


if __name__ == "__main__":
    unittest.main()
