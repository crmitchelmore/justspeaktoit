"""Synthetic PE32+ images and script loading shared by the Windows tooling tests.

A plain module rather than a test file, so other tests can build images
without executing test_windows_bundle.py for its helpers.
"""
import importlib.util
import pathlib
import struct
import sys

HERE = pathlib.Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
import windows_pe as PE  # noqa: E402


def load_script(name, path):
    """Imports a hyphenated script (or any file) as module ``name``."""
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


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
             legacy_delay=False, wixburn=None, image_base=0x140000000, hybrid_metadata=None, load_config_size=0x140,
             subsystem=PE.IMAGE_SUBSYSTEM_WINDOWS_CUI):
    """Build a minimal PE32+ image with import, delay-load, resource and optional .wixburn sections.

    ``hybrid_metadata`` adds a load configuration whose CHPE metadata pointer
    has that value, as ARM64EC and ARM64X linkers emit.
    """
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
    load_config = None
    if hybrid_metadata is not None:
        blob = bytearray(0x140)
        struct.pack_into("<I", blob, 0, load_config_size)
        struct.pack_into("<Q", blob, PE.LOAD_CONFIG_CHPE_METADATA_64, hybrid_metadata)
        load_config = (rdata_rva + add(bytes(blob)), len(blob))
    sections = [(b".rdata", rdata_rva, bytes(rdata))]
    directories = [(0, 0)] * 16
    directories[PE.DIRECTORY_IMPORT] = (rdata_rva, import_table)
    if delay_imports:
        directories[PE.DIRECTORY_DELAY_IMPORT] = (rdata_rva + delay_table_offset, delay_table)
    if load_config is not None:
        directories[PE.DIRECTORY_LOAD_CONFIG] = load_config
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
                           0x1000 * (len(sections) + 4), headers_size, 0, subsystem, 0x8160, 0x100000, 0x1000, 0x100000, 0x1000, 0, 16)
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
