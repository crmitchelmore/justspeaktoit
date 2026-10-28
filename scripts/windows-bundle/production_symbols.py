"""Strip only production PE debug data, retaining source-bound diagnostic originals.

The caller supplies an authenticated absolute llvm-objcopy path. This module
never searches PATH, edits the original, patches a PE, or transforms vendor DLLs
or test executables. Native execution/package qualification remains separate.
"""
import hashlib
import os
import pathlib
import stat
import struct
import subprocess
import tempfile

import windows_pe

PRODUCTION = {"SpeakWindows.exe", "speak.exe"}


class SymbolsError(ValueError):
    """The tool, source, or transformed image violated the production contract."""


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def regular_identity(path):
    path = pathlib.Path(path)
    if not path.is_absolute():
        raise SymbolsError("an explicit absolute file path is required")
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or getattr(info, "st_file_attributes", 0) & 0x400:
        raise SymbolsError("production symbols input must be a regular non-reparse file")
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def read_stable(path):
    identity = regular_identity(path)
    data = pathlib.Path(path).read_bytes()
    if regular_identity(path) != identity or len(data) != identity[2]:
        raise SymbolsError("file identity changed while reading")
    return data, identity


def sections(data):
    """Resolve long COFF debug names; retain exact virtual and raw extents."""
    image = windows_pe.PEImage(data)
    pe = struct.unpack_from("<I", data, 60)[0]
    count = struct.unpack_from("<H", data, pe + 6)[0]
    symbols, symbol_count = struct.unpack_from("<II", data, pe + 12)
    table = pe + 24 + struct.unpack_from("<H", data, pe + 20)[0]
    strings = symbols + symbol_count * 18
    result = {}
    for index in range(count):
        at = table + index * 40
        name = data[at:at + 8].split(b"\0")[0].decode("ascii", "strict")
        if name.startswith("/"):
            if not name[1:].isascii() or not name[1:].isdigit() or strings + 4 > len(data):
                raise SymbolsError("invalid COFF section name")
            length = struct.unpack_from("<I", data, strings)[0]
            offset = int(name[1:])
            if not 4 <= offset < length or strings + length > len(data):
                raise SymbolsError("invalid COFF string table")
            end = data.find(b"\0", strings + offset, strings + length)
            if end < 0:
                raise SymbolsError("unterminated COFF section name")
            name = data[strings + offset:end].decode("ascii", "strict")
        if not name or name in result:
            raise SymbolsError("duplicate or empty PE section name")
        virtual, rva, raw, pointer = struct.unpack_from("<IIII", data, at + 8)
        flags = struct.unpack_from("<I", data, at + 36)[0]
        result[name] = {"virtualSize": virtual, "rva": rva, "rawSize": raw,
                        "pointer": pointer, "flags": flags}
    return image, result


def loader_state(data, image):
    pe = struct.unpack_from("<I", data, 60)[0]
    optional = pe + 24
    return {"architecture": image.architecture, "subsystem": image.subsystem,
            "characteristics": image.characteristics, "imageBase": image.image_base,
            "entrypoint": struct.unpack_from("<I", data, optional + 16)[0],
            "dllCharacteristics": image.dll_characteristics,
            "alignments": struct.unpack_from("<II", data, optional + 32),
            "stackAndHeap": struct.unpack_from("<QQQQ", data, optional + 72),
            "imports": image.imports(), "delayImports": image.delay_imports(),
            # The debug directory itself is checked separately below.
            "directories": [entry for index, entry in enumerate(image.directories) if index != 6]}


def header_contract(data, rows):
    """Preserve unknown header fields and independently derive the changed totals."""
    pe = struct.unpack_from("<I", data, 60)[0]
    optional = pe + 24
    optional_size = struct.unpack_from("<H", data, pe + 20)[0]
    section_count = struct.unpack_from("<H", data, pe + 6)[0]
    section_alignment, file_alignment = struct.unpack_from("<II", data, optional + 32)
    if (not 512 <= file_alignment <= 65536 or file_alignment & (file_alignment - 1)
            or section_alignment < file_alignment or section_alignment & (section_alignment - 1)):
        raise SymbolsError("invalid PE alignment")
    def rounded(value, alignment):
        return (value + alignment - 1) // alignment * alignment
    headers = rounded(optional + optional_size + section_count * 40, file_alignment)
    extent = max([headers] + [row["rva"] + max(row["virtualSize"], row["rawSize"]) for row in rows.values()])
    expected = {4: sum(row["rawSize"] for row in rows.values() if row["flags"] & 0x20),
                8: sum(row["rawSize"] for row in rows.values() if row["flags"] & 0x40),
                56: rounded(extent, section_alignment), 60: headers}
    for offset, value in expected.items():
        if struct.unpack_from("<I", data, optional + offset)[0] != value:
            raise SymbolsError("derived PE header size is invalid")
    for row in rows.values():
        if (row["rva"] % section_alignment or row["rawSize"] % file_alignment
                or (row["rawSize"] and (row["pointer"] < headers or row["pointer"] % file_alignment))):
            raise SymbolsError("section layout is invalid")
    coff = bytearray(data[pe + 4:optional])
    # Section count and COFF debug symbol file positions may change; neither is a runtime identity.
    coff[2:4] = bytes(2)
    coff[8:16] = bytes(8)
    header = bytearray(data[optional:optional + optional_size])
    for offset in (8, 56, 60):
        header[offset:offset + 4] = bytes(4)
    return bytes(data[:pe + 4]), bytes(coff), bytes(header)


def validate_transform(original, transformed, architecture):
    """Reject any unknown runtime change; classify only observed LLVM padding."""
    try:
        old, before = sections(original)
        new, after = sections(transformed)
        if old.is_dll or new.is_dll or old.architecture != architecture or new.architecture != architecture:
            raise SymbolsError("transform must retain the exact production architecture")
        if header_contract(original, before) != header_contract(transformed, after):
            raise SymbolsError("unknown COFF or optional header field changed")
        if loader_state(original, old) != loader_state(transformed, new):
            raise SymbolsError("loader metadata, imports, or runtime directories changed")
        before = {name: row for name, row in before.items() if not name.startswith(".debug_")}
        if set(before) != set(after):
            raise SymbolsError("debug sections remain or runtime sections changed")
        left, right = bytearray(original), bytearray(transformed)
        old_debug = old.directories[6] if len(old.directories) > 6 else (0, 0)
        new_debug = new.directories[6] if len(new.directories) > 6 else (0, 0)
        if old_debug != new_debug or old_debug[1] % 28:
            raise SymbolsError("debug directory identity changed")
        debug = []
        for offset in range(0, old_debug[1], 28):
            rva = old_debug[0] + offset
            first, second = old.offset(rva, 28), new.offset(rva, 28)
            a = struct.unpack_from("<IIHHIIII", left, first)
            b = struct.unpack_from("<IIHHIIII", right, second)
            # Equal numeric pointers also need validation after section file positions move.
            if a != b and (a[:-1] != b[:-1] or a[4] != 2):
                raise SymbolsError("unknown debug directory change")
            if a[4] == 2 and any(a[-3:] + b[-3:]):
                if a[:-1] != b[:-1] or not all(a[-3:]) or not all(b[-3:]):
                    raise SymbolsError("invalid CodeView debug entry")
                size, payload_rva, old_pointer, new_pointer = a[-3], a[-2], a[-1], b[-1]
                if old.offset(payload_rva, size) != old_pointer or new.offset(payload_rva, size) != new_pointer:
                    raise SymbolsError("debug payload file pointer is invalid")
                if original[old_pointer:old_pointer + size] != transformed[new_pointer:new_pointer + size]:
                    raise SymbolsError("debug payload changed")
                if old_pointer != new_pointer:
                    debug.append({"directoryRVA": rva, "payloadRVA": payload_rva, "bytes": size,
                                  "originalFilePointer": old_pointer, "transformedFilePointer": new_pointer})
                    left[first + 24:first + 28] = bytes(4)
                    right[second + 24:second + 28] = bytes(4)
        padding = []
        alignment = loader_state(original, old)["alignments"][1]
        if alignment <= 0:
            raise SymbolsError("invalid file alignment")
        for name, a in before.items():
            b = after[name]
            if {k: v for k, v in a.items() if k != "pointer"} != {k: v for k, v in b.items() if k != "pointer"}:
                raise SymbolsError("runtime section identity changed")
            size = a["rawSize"]
            first, second = a["pointer"], b["pointer"]
            content = min(size, a["virtualSize"])
            if left[first:first + content] != right[second:second + content]:
                raise SymbolsError("bytes inside declared VirtualSize changed")
            a_tail = left[first + content:first + size]
            b_tail = right[second + content:second + size]
            if a_tail != b_tail:
                rounded = (a["virtualSize"] + alignment - 1) // alignment * alignment
                if not (architecture == "arm64" and name == ".text" and a["flags"] & 0x20
                        and 0 < a["virtualSize"] < size == rounded
                        and a_tail == bytes(len(a_tail)) and b_tail == b"\xcc" * len(b_tail)):
                    raise SymbolsError("unknown raw file-alignment padding change")
                padding.append({"section": name, "offset": a["virtualSize"], "bytes": len(a_tail),
                                "originalByte": "00", "transformedByte": "cc"})
        return {"declaredSectionContentUnchanged": True, "loaderMetadataUnchanged": True,
                "codeViewFilePointerChanges": debug, "knownRawAlignmentPaddingChanges": padding}
    except (windows_pe.PEFormatError, struct.error, UnicodeError, IndexError) as error:
        raise SymbolsError("invalid transformed PE structure") from error


def transform(source, destination, tool, architecture, source_commit, *, replace_existing=False):
    """Transform an owned output copy before its producer identity is recorded."""
    source, destination, tool = map(pathlib.Path, (source, destination, tool))
    if destination.name not in PRODUCTION or source == destination:
        raise SymbolsError("only new production executable copies may be transformed")
    if tool.name.lower() not in {"llvm-objcopy", "llvm-objcopy.exe"}:
        raise SymbolsError("explicit llvm-objcopy tool required")
    previous = None
    if destination.exists() or destination.is_symlink():
        if not replace_existing:
            raise SymbolsError("production destination already exists")
        previous = read_stable(destination)
    data, source_identity = read_stable(source)
    tool_data, tool_identity = read_stable(tool)
    if os.name == "nt":
        image = windows_pe.PEImage(tool_data)
        if image.is_dll or image.architecture != architecture:
            raise SymbolsError("native tool architecture mismatch")
    original = windows_pe.PEImage(data)
    if original.is_dll or original.architecture != architecture:
        raise SymbolsError("production image architecture mismatch")
    if any(name.lower() in {"testing.dll", "xctest.dll"} for name in original.imports() + original.delay_imports()):
        raise SymbolsError("test-enabled images cannot be transformed")
    if destination.name == "speak.exe" and original.subsystem != windows_pe.IMAGE_SUBSYSTEM_WINDOWS_CUI:
        raise SymbolsError("production CLI must retain console subsystem")
    retained_directory = destination.parent / "diagnostic-symbols"
    retained_directory.mkdir(exist_ok=True)
    info = retained_directory.lstat()
    if retained_directory.is_symlink() or not stat.S_ISDIR(info.st_mode) or getattr(info, "st_file_attributes", 0) & 0x400:
        raise SymbolsError("diagnostic-symbols must be an owned regular directory")
    retained = retained_directory / (destination.name + "." + sha256(data) + ".unstripped")
    try:
        with retained.open("xb") as stream:
            stream.write(data)
    except FileExistsError:
        if read_stable(retained)[0] != data:
            raise SymbolsError("retained diagnostic original does not match its content hash")
    temporary = None
    try:
        version = subprocess.run([str(tool), "--version"], check=True, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, timeout=10)
        if not 0 < len(version.stdout) <= 8192:
            raise SymbolsError("tool version output is invalid")
        version_text = version.stdout.decode("utf-8", "strict").strip()
        with tempfile.NamedTemporaryFile(prefix=".production-symbols-", suffix=".exe",
                                         dir=destination.parent, delete=False) as stream:
            temporary = pathlib.Path(stream.name)
        subprocess.run([str(tool), "--strip-debug", str(retained), str(temporary)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
        output, _ = read_stable(temporary)
        semantic = validate_transform(data, output, architecture)
        if len(output) > len(data):
            raise SymbolsError("debug removal increased the production image size")
        if read_stable(source) != (data, source_identity) or read_stable(tool) != (tool_data, tool_identity):
            raise SymbolsError("source or tool changed during transform")
        if read_stable(retained)[0] != data:
            raise SymbolsError("retained diagnostic original changed")
        if previous is None:
            if destination.exists() or destination.is_symlink():
                raise SymbolsError("destination appeared during transform")
        elif read_stable(destination) != previous:
            raise SymbolsError("destination changed during transform")
        temporary.replace(destination)
        temporary = None
        return {"status": "optimized", "sourceCommit": source_commit, "architecture": architecture,
                "originalSHA256": sha256(data), "retainedSHA256": sha256(data),
                "retainedPath": str(retained.relative_to(destination.parent)),
                "transformedSHA256": sha256(output), "originalBytes": len(data), "transformedBytes": len(output),
                "tool": {"path": str(tool), "sha256": sha256(tool_data),
                         "version": version_text},
                "semanticValidation": semantic}
    except (OSError, subprocess.SubprocessError, UnicodeError) as error:
        raise SymbolsError("production debug transform failed") from error
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
