"""Synthetic inputs shared by the Windows bundle tests: the loaded tooling
modules, cabinet, MSI and Burn containers, and a pinned local Whisper runtime.

A plain module rather than a test file, so test modules can share it without
unittest collecting any test twice.
"""
import hashlib
import json
import math
import pathlib
import struct
import sys
import zlib

HERE = pathlib.Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
from pe_test_fixtures import build_pe, load_script  # noqa: E402


def load(name, file_name):
    return load_script(name, HERE / file_name)


PE = load("windows_pe", "windows_pe.py")
REDIST = load("redistributables", "redistributables.py")
BUILD = load("build_windows_bundle", "build-windows-bundle.py")
MIGRATION = load("migration_dependency", "../migration/migration_dependency.py")


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


# The import graph of a minimal Windows app: application, Swift and Microsoft runtimes.
CLOSURE_GRAPH = {
    "SpeakWindows.exe": (["USER32.dll", "swiftCore.dll", "MSVCP140.dll", "api-ms-win-crt-runtime-l1-1-0.dll"],
                         ["Foundation.dll"]),
    "swiftCore.dll": (["KERNEL32.dll", "VCRUNTIME140.dll", "MSVCP140.dll"], []),
    "Foundation.dll": (["swiftCore.dll", "_FoundationICU.dll", "FoundationNetworking.dll"], []),
    "FoundationNetworking.dll": (["Foundation.dll", "swiftCore.dll", "CRYPT32.dll"], []),
    "_FoundationICU.dll": (["msvcp140.dll", "kernel32.dll"], []),
    "msvcp140.dll": (["vcruntime140.dll", "api-ms-win-crt-heap-l1-1-0.dll"], []),
    "vcruntime140.dll": (["KERNEL32.dll"], []),
}


LOCAL_PINS = json.loads((HERE.parent / "windows-local-runtime" / "dependencies.json").read_text(encoding="utf-8"))
LOCAL_GRAPH = {
    "whisper.dll": (["ggml.dll", "ggml-base.dll", "KERNEL32.dll", "MSVCP140.dll", "VCRUNTIME140.dll"], []),
    "ggml.dll": (["ggml-base.dll", "KERNEL32.dll"], []),
    "ggml-base.dll": (["KERNEL32.dll", "msvcp140.dll", "concrt140.dll"], []),
    "ggml-vulkan.dll": (["ggml-base.dll", "vulkan-1.dll", "KERNEL32.dll"], []),
    "ggml-cpu-x64.dll": (["ggml-base.dll", "KERNEL32.dll"], []),
    "ggml-cpu-sse42.dll": (["ggml-base.dll"], []),
    "ggml-cpu-haswell.dll": (["ggml-base.dll"], []),
    "ggml-cpu-icelake.dll": (["ggml-base.dll"], []),
}
# The ARM64 build has one CPU backend and no Vulkan backend.
LOCAL_ARM64_GRAPH = {
    "whisper.dll": (["ggml.dll", "ggml-base.dll", "KERNEL32.dll", "MSVCP140.dll", "VCRUNTIME140.dll"], []),
    "ggml.dll": (["ggml-base.dll", "KERNEL32.dll"], []),
    "ggml-base.dll": (["KERNEL32.dll", "msvcp140.dll"], []),
    "ggml-cpu.dll": (["ggml-base.dll", "KERNEL32.dll"], []),
}
MACHINES = {"x64": PE.IMAGE_FILE_MACHINE_AMD64, "arm64": PE.IMAGE_FILE_MACHINE_ARM64}


def write_local_runtime(root, graph=LOCAL_GRAPH, pins=LOCAL_PINS, architecture="x64", machine=None,
                        **manifest_overrides):
    runtime = root / "runtime"
    runtime.mkdir(parents=True)
    files = []
    for name, (static, delayed) in graph.items():
        data = build_pe(static, delayed, dll=True, machine=machine or MACHINES[architecture])
        (runtime / name).write_bytes(data)
        files.append({"name": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                      "imports": static, "delayImports": delayed})
    licence = b"MIT licence fixture"
    (runtime / "LICENSE-whisper.cpp.txt").write_bytes(licence)
    pins = json.loads(json.dumps(pins))
    pins["whisperCpp"]["licenseSHA256"] = hashlib.sha256(licence).hexdigest()
    pins_path = root / "pins.json"
    pins_path.write_text(json.dumps(pins), encoding="utf-8")
    target = pins["architectures"][architecture]
    sdk = target["vulkanSdk"]
    manifest = {"schemaVersion": 2, "runtime": "whisper.cpp", "architecture": architecture,
                "version": pins["whisperCpp"]["version"],
                "commit": pins["whisperCpp"]["commit"], "repository": pins["whisperCpp"]["repository"],
                "cmakeArguments": target["cmakeArguments"], "compiler": "MSVC 19.44" if sdk else "Clang 22.1.8",
                "vulkanSdk": None if sdk is None else {key: sdk[key] for key in ("version", "sha256", "bytes")},
                "files": files, "pinsSHA256": hashlib.sha256(pins_path.read_bytes().replace(b"\r\n", b"\n")).hexdigest()}
    manifest.update(manifest_overrides)
    (root / "runtime-manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    return pins_path
