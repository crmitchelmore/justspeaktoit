"""Read Windows PE metadata without executing anything.

Only the structures the bundle needs are decoded: the COFF/optional headers,
section table, static import directory, delay-load import directory, the
load configuration's hybrid (ARM64EC/ARM64X) metadata pointer and the
VS_VERSIONINFO resource. Every read is bounds-checked; malformed input raises
``PEFormatError`` instead of producing a partial dependency list.
"""
import pathlib
import struct

IMAGE_FILE_MACHINE_I386 = 0x14C
IMAGE_FILE_MACHINE_AMD64 = 0x8664
IMAGE_FILE_MACHINE_ARM64 = 0xAA64
IMAGE_SUBSYSTEM_WINDOWS_GUI = 2
IMAGE_SUBSYSTEM_WINDOWS_CUI = 3
IMAGE_FILE_DLL = 0x2000
DIRECTORY_IMPORT = 1
DIRECTORY_RESOURCE = 2
DIRECTORY_LOAD_CONFIG = 10
DIRECTORY_DELAY_IMPORT = 13
# IMAGE_LOAD_CONFIG_DIRECTORY64.CHPEMetadataPointer. Only hybrid images set it:
# ARM64EC code behind an x64 header, or ARM64X with an ARM64 header.
LOAD_CONFIG_CHPE_METADATA_64 = 0xC8
RT_VERSION = 16
MAX_DLL_NAME = 260

# Image architectures. The x64 header of an ARM64EC image and the ARM64 header
# of an ARM64X image are told apart from plain x64 and ARM64 by that pointer.
X86, X64, ARM64, ARM64EC, ARM64X = "x86", "x64", "arm64", "arm64ec", "arm64x"
# The images each Windows process architecture loads natively. An ARM64
# process uses ARM64X's native view; ARM64EC needs an emulated x64 process and
# never runs on x64 hardware, so neither target accepts it.
NATIVE_IMAGES = {X64: frozenset({X64}), ARM64: frozenset({ARM64, ARM64X})}


class PEFormatError(ValueError):
    """The file is not a well-formed PE image for our purposes."""


class PEImage:
    def __init__(self, data, name="<memory>"):
        self.data = bytes(data)
        self.name = str(name)
        if len(self.data) < 0x40 or self.data[:2] != b"MZ":
            raise PEFormatError(self.name + ": missing MZ header")
        pe_offset = self._u32(0x3C)
        if self._bytes(pe_offset, 4) != b"PE\0\0":
            raise PEFormatError(self.name + ": missing PE signature")
        coff = pe_offset + 4
        (self.machine, section_count, self.timestamp, _, _, optional_size,
         self.characteristics) = struct.unpack_from("<HHIIIHH", self._bytes(coff, 20))
        optional = coff + 20
        self._bytes(optional, optional_size)
        self.optional_magic = self._u16(optional)
        if self.optional_magic == 0x20B:
            self.image_base = self._u64(optional + 24)
            directories_offset, count_offset = optional + 112, optional + 108
        elif self.optional_magic == 0x10B:
            self.image_base = self._u32(optional + 28)
            directories_offset, count_offset = optional + 96, optional + 92
        else:
            raise PEFormatError(self.name + ": unknown optional header magic")
        if optional_size < (count_offset - optional) + 4:
            raise PEFormatError(self.name + ": optional header too small")
        self.subsystem = self._u16(optional + 68)
        self.dll_characteristics = self._u16(optional + 70)
        directory_count = self._u32(count_offset)
        if directory_count > 16:
            raise PEFormatError(self.name + ": implausible data directory count")
        if directories_offset + directory_count * 8 > optional + optional_size:
            raise PEFormatError(self.name + ": data directories exceed optional header")
        self.directories = [struct.unpack_from("<II", self.data, directories_offset + index * 8)
                            for index in range(directory_count)]
        table = optional + optional_size
        self.sections = []
        for index in range(section_count):
            entry = self._bytes(table + index * 40, 40)
            name, virtual_size, virtual_address, raw_size, raw_pointer = struct.unpack_from("<8sIIII", entry)
            if raw_pointer + raw_size > len(self.data):
                raise PEFormatError(self.name + ": section data exceeds file size")
            self.sections.append((name.rstrip(b"\0").decode("ascii", "replace"), virtual_address,
                                  max(virtual_size, raw_size), raw_size, raw_pointer))
        self.header_size = self._u32(optional + 60)
        if not table + section_count * 40 <= self.header_size <= len(self.data):
            raise PEFormatError(self.name + ": invalid SizeOfHeaders")

    @classmethod
    def load(cls, path):
        path = pathlib.Path(path)
        return cls(path.read_bytes(), path.name)

    # --- primitive readers --------------------------------------------------
    def _bytes(self, offset, size):
        if offset < 0 or size < 0 or offset + size > len(self.data):
            raise PEFormatError(self.name + ": read outside the file at offset " + str(offset))
        return self.data[offset:offset + size]

    def _u16(self, offset):
        return struct.unpack("<H", self._bytes(offset, 2))[0]

    def _u32(self, offset):
        return struct.unpack("<I", self._bytes(offset, 4))[0]

    def _u64(self, offset):
        return struct.unpack("<Q", self._bytes(offset, 8))[0]

    @property
    def is_dll(self):
        return bool(self.characteristics & IMAGE_FILE_DLL)

    @property
    def is_x64(self):
        return self.architecture == X64

    @property
    def architecture(self):
        """``x64``, ``arm64``, ``arm64ec``, ``arm64x``, ``x86`` or ``machine-0x....``."""
        if self.optional_magic == 0x20B and self.machine == IMAGE_FILE_MACHINE_AMD64:
            return ARM64EC if self.hybrid_metadata() else X64
        if self.optional_magic == 0x20B and self.machine == IMAGE_FILE_MACHINE_ARM64:
            return ARM64X if self.hybrid_metadata() else ARM64
        if self.optional_magic == 0x10B and self.machine == IMAGE_FILE_MACHINE_I386:
            return X86
        return "machine-%#06x" % self.machine

    def runs_natively_on(self, architecture):
        """Whether a process of ``architecture`` (``x64`` or ``arm64``) loads this image natively."""
        if architecture not in NATIVE_IMAGES:
            raise ValueError("unsupported Windows architecture: %r" % (architecture,))
        return self.architecture in NATIVE_IMAGES[architecture]

    def hybrid_metadata(self):
        """The CHPE metadata address of an ARM64EC or ARM64X image; 0 for any other image."""
        rva, size = self.directory(DIRECTORY_LOAD_CONFIG)
        if (not rva and not size) or self.optional_magic != 0x20B:
            return 0
        if not rva or size < 4:
            raise PEFormatError(self.name + ": truncated load configuration directory")
        # The structure's own Size field says which trailing fields exist.
        declared = self._u32(self.offset(rva, 4))
        if declared < LOAD_CONFIG_CHPE_METADATA_64 + 8:
            return 0
        return self._u64(self.offset(rva + LOAD_CONFIG_CHPE_METADATA_64, 8))

    def section_name_of(self, rva):
        for name, address, size, _, _ in self.sections:
            if address <= rva < address + size:
                return name
        return None

    def offset(self, rva, length=1):
        """Translate an RVA into a file offset; header RVAs map directly."""
        for _, address, size, raw_size, raw_pointer in self.sections:
            if address <= rva < address + size:
                if length < 0 or rva - address + length > raw_size:
                    raise PEFormatError(self.name + ": RVA points into uninitialised section data")
                return raw_pointer + (rva - address)
        if 0 <= rva < self.header_size and 0 <= length <= self.header_size - rva:
            return rva
        raise PEFormatError(self.name + ": RVA %#x is outside every section" % rva)

    def string(self, rva, limit=MAX_DLL_NAME):
        offset = self.offset(rva)
        end = self.data.find(b"\0", offset, offset + limit + 1)
        if end < 0:
            raise PEFormatError(self.name + ": unterminated string at RVA %#x" % rva)
        self.offset(rva, end - offset + 1)
        try:
            return self.data[offset:end].decode("ascii")
        except UnicodeDecodeError as error:
            raise PEFormatError(self.name + ": non-ASCII module name") from error

    def directory(self, index):
        if index < len(self.directories):
            return self.directories[index]
        return (0, 0)

    # --- imports -------------------------------------------------------------
    def imports(self):
        """Names of statically imported modules, in table order."""
        rva, size = self.directory(DIRECTORY_IMPORT)
        if not rva and not size:
            return []
        if not rva or size < 20:
            raise PEFormatError(self.name + ": truncated import directory")
        self.offset(rva, size)
        names = []
        for index in range(min(size // 20, 4097)):
            entry = self._bytes(self.offset(rva + index * 20, 20), 20)
            original_thunk, _, _, name_rva, first_thunk = struct.unpack("<IIIII", entry)
            if not any(entry):
                return names
            if not name_rva:
                raise PEFormatError(self.name + ": import descriptor without a module name")
            names.append(self.string(name_rva))
        raise PEFormatError(self.name + ": unterminated import directory")

    def delay_imports(self):
        """Names of delay-loaded modules from IMAGE_DELAYLOAD_DESCRIPTOR entries."""
        rva, size = self.directory(DIRECTORY_DELAY_IMPORT)
        if not rva and not size:
            return []
        if not rva or size < 32:
            raise PEFormatError(self.name + ": truncated delay-load directory")
        self.offset(rva, size)
        names = []
        for index in range(min(size // 32, 4097)):
            entry = self._bytes(self.offset(rva + index * 32, 32), 32)
            attributes, name_address, module_handle, iat, int_table, _, _, _ = struct.unpack("<IIIIIIII", entry)
            if not any(entry):
                return names
            if not name_address or attributes & ~1:
                raise PEFormatError(self.name + ": invalid delay-load descriptor")
            if not attributes & 1:
                # Pre-VC2010 descriptors store virtual addresses instead of RVAs.
                if name_address < self.image_base:
                    raise PEFormatError(self.name + ": delay-load name address below the image base")
                name_address -= self.image_base
            names.append(self.string(name_address))
        raise PEFormatError(self.name + ": unterminated delay-load directory")

    # --- version resource ------------------------------------------------------
    def version_info(self):
        """Fixed file version plus StringFileInfo values, or None when absent."""
        rva, size = self.directory(DIRECTORY_RESOURCE)
        if not rva:
            return None
        base = self.offset(rva, size)
        data_entry = self._find_version_data(base, base, 0, base + size)
        if data_entry is None:
            return None
        data_rva, data_size = struct.unpack("<II", self._bytes(data_entry, 8))
        block = self._bytes(self.offset(data_rva, data_size), data_size)
        return parse_version_block(block, self.name)

    def _find_version_data(self, base, table, level, end):
        if level > 2:
            return None
        if not base <= table <= end - 16:
            raise PEFormatError(self.name + ": resource table outside directory")
        named, ids = struct.unpack("<HH", self._bytes(table + 12, 4))
        if table + 16 + (named + ids) * 8 > end:
            raise PEFormatError(self.name + ": truncated resource table")
        entry = table + 16 + named * 8
        for _ in range(ids):
            identifier, offset = struct.unpack("<II", self._bytes(entry, 8))
            entry += 8
            wanted = level != 0 or identifier == RT_VERSION
            if not wanted:
                continue
            if offset & 0x80000000:
                found = self._find_version_data(base, base + (offset & 0x7FFFFFFF), level + 1, end)
                if found is not None:
                    return found
            elif level == 2:
                if base + offset + 16 > end:
                    raise PEFormatError(self.name + ": resource data entry outside directory")
                return base + offset
        return None


def parse_version_block(block, name="<memory>"):
    """Decode VS_VERSIONINFO into a plain dictionary."""
    if len(block) < 6:
        raise PEFormatError(name + ": version resource too small")
    length, value_length, kind = struct.unpack_from("<HHH", block)
    if not 6 <= length <= len(block):
        raise PEFormatError(name + ": invalid version resource length")
    block = block[:length]
    key, cursor = _read_key(block, 6, name)
    if key != "VS_VERSION_INFO":
        raise PEFormatError(name + ": unexpected version resource root " + key)
    cursor = _align(cursor)
    result = {"fileVersion": None, "productVersion": None, "strings": {}}
    if cursor + value_length > length:
        raise PEFormatError(name + ": truncated fixed version value")
    if value_length >= 52:
        signature, _, ms, ls, pms, pls = struct.unpack_from("<IIIIII", block, cursor)
        if signature != 0xFEEF04BD:
            raise PEFormatError(name + ": VS_FIXEDFILEINFO signature mismatch")
        result["fileVersion"] = "%d.%d.%d.%d" % (ms >> 16, ms & 0xFFFF, ls >> 16, ls & 0xFFFF)
        result["productVersion"] = "%d.%d.%d.%d" % (pms >> 16, pms & 0xFFFF, pls >> 16, pls & 0xFFFF)
    cursor = _align(cursor + value_length)
    end = min(length, len(block))
    while cursor + 6 <= end:
        child_length, child_value_length, _ = struct.unpack_from("<HHH", block, cursor)
        if child_length < 6 or cursor + child_length > end:
            raise PEFormatError(name + ": zero-length version child")
        child_key, key_end = _read_key(block[:cursor + child_length], cursor + 6, name)
        if child_key == "StringFileInfo":
            _parse_string_file_info(block, _align(key_end), cursor + child_length, result["strings"], name)
        cursor = _align(cursor + child_length)
    return result


def _parse_string_file_info(block, cursor, end, strings, name):
    if end > len(block):
        raise PEFormatError(name + ": string info outside resource")
    while cursor + 6 <= end:
        table_length, _, _ = struct.unpack_from("<HHH", block, cursor)
        if table_length < 6 or cursor + table_length > end:
            raise PEFormatError(name + ": zero-length string table")
        table_end = cursor + table_length
        _, key_end = _read_key(block[:table_end], cursor + 6, name)
        entry = _align(key_end)
        while entry + 6 <= table_end:
            entry_length, value_length, kind = struct.unpack_from("<HHH", block, entry)
            if entry_length < 6 or entry + entry_length > table_end:
                raise PEFormatError(name + ": zero-length string entry")
            key, value_start = _read_key(block[:entry + entry_length], entry + 6, name)
            value_start = _align(value_start)
            if kind == 1 and value_length:
                if value_start + value_length * 2 > entry + entry_length:
                    raise PEFormatError(name + ": string value outside version entry")
                raw = block[value_start:value_start + value_length * 2]
                strings.setdefault(key, raw.decode("utf-16-le", "replace").split("\0")[0])
            entry = _align(entry + entry_length)
        cursor = _align(cursor + table_length)


def _read_key(block, cursor, name):
    end = cursor
    while True:
        if end + 2 > len(block):
            raise PEFormatError(name + ": unterminated version key")
        if block[end:end + 2] == b"\0\0":
            break
        end += 2
    return block[cursor:end].decode("utf-16-le", "replace"), end + 2


def _align(value):
    return (value + 3) & ~3


def describe(path):
    """Summary used by the bundle manifest and the dependency walk."""
    image = PEImage.load(path)
    version = image.version_info()
    return {
        "machine": image.architecture,
        "dll": image.is_dll,
        "subsystem": image.subsystem,
        "imports": image.imports(),
        "delayImports": image.delay_imports(),
        "fileVersion": version["fileVersion"] if version else None,
        "productVersion": version["productVersion"] if version else None,
        "originalFilename": (version or {}).get("strings", {}).get("OriginalFilename"),
    }
