"""Read Microsoft's official Visual C++ redistributable bundle as plain data.

The VC_redist.x64.exe download is a WiX Burn bundle: a stub executable whose
``.wixburn`` section lists two attached cabinets. The first holds the bundle
manifest and installer UI; the second holds the runtime MSI packages and their
external cabinets. This module carves those cabinets, inflates their MSZIP
blocks, reads the MSI File/Media tables from the compound-file streams and
returns the runtime DLL bytes. Nothing is executed: no installer, MSI custom
action or bootstrapper code runs, mirroring the Swift installer handling in
``scripts/windows-cross`` (whose MSI table decoding this reuses).
"""
import hashlib
import struct
import zlib

BURN_MAGIC = 0x00F14300
BURN_FORMAT_CAB = 1
CAB_FOLDER_CONTINUED = 0xFFFD
MSZIP = 1
CFB_SIGNATURE = b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1"
CFB_END_OF_CHAIN = 0xFFFFFFFE
CFB_FREE = 0xFFFFFFFF
MSI_ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._"


class ExtractionError(ValueError):
    """The redistributable's data did not match the documented layout."""


# --- Burn bundle ---------------------------------------------------------------
def pe_sections(data):
    if len(data) < 0x40 or data[:2] != b"MZ":
        raise ExtractionError("bundle is not a PE image")
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        raise ExtractionError("bundle PE signature missing")
    count = struct.unpack_from("<H", data, pe + 6)[0]
    optional_size = struct.unpack_from("<H", data, pe + 20)[0]
    table = pe + 24 + optional_size
    sections = []
    for index in range(count):
        entry = table + index * 40
        if entry + 40 > len(data):
            raise ExtractionError("bundle section table truncated")
        name, _, _, raw_size, raw_pointer = struct.unpack_from("<8sIIII", data, entry)
        sections.append((name.rstrip(b"\0").decode("ascii", "replace"), raw_pointer, raw_size))
    return sections


def burn_containers(data):
    """Return ``[(offset, size)]`` for the cabinets the ``.wixburn`` header declares."""
    section = next((entry for entry in pe_sections(data) if entry[0] == ".wixburn"), None)
    if section is None:
        raise ExtractionError("no .wixburn section: not a Burn bundle")
    _, start, raw_size = section
    if raw_size < 52 or start + raw_size > len(data):
        raise ExtractionError(".wixburn section too small")
    magic, version = struct.unpack_from("<II", data, start)
    if magic != BURN_MAGIC or version != 2:
        raise ExtractionError("unsupported Burn section version")
    stub_size, _, _, _, container_format, count = struct.unpack_from("<IIIIII", data, start + 24)
    if container_format != BURN_FORMAT_CAB or not 1 <= count <= 16 or 48 + 4 * count > raw_size:
        raise ExtractionError("unsupported Burn container layout")
    sizes = [struct.unpack_from("<I", data, start + 48 + 4 * index)[0] for index in range(count)]
    containers, position = [], stub_size
    for size in sizes:
        while True:
            offset = data.find(b"MSCF", position)
            if offset < 0 or offset + size > len(data):
                raise ExtractionError("declared Burn container not found")
            if cabinet_header_is_valid(data, offset) and struct.unpack_from("<I", data, offset + 8)[0] == size:
                break
            position = offset + 4
        containers.append((offset, size))
        position = offset + size
    return containers


# --- Cabinet (MS-CAB) -----------------------------------------------------------
def cabinet_header_is_valid(data, offset):
    if data[offset:offset + 4] != b"MSCF" or offset + 36 > len(data):
        return False
    reserved1, size, reserved2, _, reserved3, minor, major = struct.unpack_from("<IIIIIBB", data, offset + 4)
    return (reserved1, reserved2, reserved3, major, minor) == (0, 0, 0, 1, 3) and offset + size <= len(data)


def cabinet_checksum(data, seed=0):
    total, whole = seed, len(data) // 4
    for index in range(whole):
        total ^= struct.unpack_from("<I", data, index * 4)[0]
    tail, remainder = data[whole * 4:], 0
    if len(tail) == 3:
        remainder = (tail[0] << 16) | (tail[1] << 8) | tail[2]
    elif len(tail) == 2:
        remainder = (tail[0] << 8) | tail[1]
    elif len(tail) == 1:
        remainder = tail[0]
    return total ^ remainder


class Cabinet:
    """A single, non-spanning MS-CAB archive using MSZIP compression."""

    def __init__(self, data, name="<cabinet>"):
        self.data, self.name = bytes(data), name
        if not cabinet_header_is_valid(self.data, 0):
            raise ExtractionError(name + ": not a supported cabinet header")
        size, files_offset, folder_count, file_count, flags = struct.unpack_from("<I4xIxxxxxxHHH", self.data, 8)
        if size > len(self.data):
            raise ExtractionError(name + ": cabinet is truncated")
        # Signed cabinets carry an Authenticode blob after cbCabinet; it is not
        # archive content and is ignored.
        self.trailing_bytes = len(self.data) - size
        if flags & 0x3:
            raise ExtractionError(name + ": spanning cabinets are not supported")
        cursor, reserve_folder, reserve_data = 36, 0, 0
        if flags & 0x4:
            reserve_header, reserve_folder, reserve_data = struct.unpack_from("<HBB", self.data, cursor)
            cursor += 4 + reserve_header
        self.reserve_data = reserve_data
        self.folders = []
        for _ in range(folder_count):
            start, blocks, compression = struct.unpack_from("<IHH", self.data, cursor)
            cursor += 8 + reserve_folder
            self.folders.append((start, blocks, compression))
        self.files = []
        cursor = files_offset
        for _ in range(file_count):
            length, folder_offset, folder, _, _, attributes = struct.unpack_from("<IIHHHH", self.data, cursor)
            cursor += 16
            end = self.data.find(b"\0", cursor)
            if end < 0:
                raise ExtractionError(name + ": unterminated file name")
            entry_name = self.data[cursor:end].decode("utf-8" if attributes & 0x80 else "cp1252")
            cursor = end + 1
            if folder >= CAB_FOLDER_CONTINUED:
                raise ExtractionError(name + ": continued file " + entry_name + " is not supported")
            if folder >= folder_count:
                raise ExtractionError(name + ": file " + entry_name + " references a missing folder")
            self.files.append((entry_name, folder, folder_offset, length))

    def names(self):
        return [entry[0] for entry in self.files]

    def _inflate_folder(self, index):
        start, blocks, compression = self.folders[index]
        if compression & 0xF != MSZIP:
            raise ExtractionError(self.name + ": only MSZIP folders are supported")
        output, cursor = bytearray(), start
        for _ in range(blocks):
            checksum, compressed, uncompressed = struct.unpack_from("<IHH", self.data, cursor)
            cursor += 8 + self.reserve_data
            block = self.data[cursor:cursor + compressed]
            if len(block) != compressed:
                raise ExtractionError(self.name + ": truncated data block")
            cursor += compressed
            if checksum and cabinet_checksum(self.data[cursor - compressed - 8 - self.reserve_data + 4:
                                                       cursor - compressed], cabinet_checksum(block)) != checksum:
                raise ExtractionError(self.name + ": data block checksum mismatch")
            if block[:2] != b"CK":
                raise ExtractionError(self.name + ": MSZIP block signature missing")
            # Each block is a fresh deflate stream whose LZ77 history continues
            # from the previous block's output.
            history = bytes(output[-32768:])
            inflater = zlib.decompressobj(-15, zdict=history) if history else zlib.decompressobj(-15)
            plain = inflater.decompress(block[2:]) + inflater.flush()
            if len(plain) != uncompressed:
                raise ExtractionError(self.name + ": block inflated to an unexpected size")
            output += plain
        return bytes(output)

    def extract(self, wanted=None):
        """Return ``{name: bytes}`` for every file (or only ``wanted`` names)."""
        wanted = None if wanted is None else set(wanted)
        folders, result = {}, {}
        for entry_name, folder, folder_offset, length in self.files:
            if wanted is not None and entry_name not in wanted:
                continue
            if folder not in folders:
                folders[folder] = self._inflate_folder(folder)
            plain = folders[folder][folder_offset:folder_offset + length]
            if len(plain) != length:
                raise ExtractionError(self.name + ": " + entry_name + " extends past its folder")
            if entry_name in result:
                raise ExtractionError(self.name + ": duplicate entry " + entry_name)
            result[entry_name] = plain
        if wanted is not None and wanted - set(result):
            raise ExtractionError(self.name + ": missing " + ", ".join(sorted(wanted - set(result))))
        return result


# --- Compound file (OLE2) and MSI tables ------------------------------------------
class CompoundFile:
    """Minimal read-only OLE2 compound file reader sufficient for MSI tables."""

    def __init__(self, data, name="<msi>"):
        self.data, self.name = bytes(data), name
        if self.data[:8] != CFB_SIGNATURE:
            raise ExtractionError(name + ": not a compound file")
        shift, mini_shift = struct.unpack_from("<HH", self.data, 0x1E)
        if shift not in (9, 12) or mini_shift != 6:
            raise ExtractionError(name + ": unsupported sector sizes")
        self.sector = 1 << shift
        self.mini_sector = 1 << mini_shift
        (fat_count, first_directory, _, self.cutoff, first_mini_fat, mini_fat_count,
         first_difat, difat_count) = struct.unpack_from("<IIIIIIII", self.data, 0x2C)
        difat = list(struct.unpack_from("<109I", self.data, 0x4C))
        sector = first_difat
        for _ in range(difat_count):
            block = self._sector(sector)
            entries = struct.unpack_from("<%dI" % (self.sector // 4), block)
            difat.extend(entries[:-1])
            sector = entries[-1]
        fat_sectors = [entry for entry in difat if entry != CFB_FREE][:fat_count]
        if len(fat_sectors) != fat_count:
            raise ExtractionError(name + ": FAT sector list truncated")
        self.fat = []
        for entry in fat_sectors:
            self.fat.extend(struct.unpack_from("<%dI" % (self.sector // 4), self._sector(entry)))
        self.directory = self._chain(first_directory)
        entries = [self.directory[index:index + 128] for index in range(0, len(self.directory), 128)]
        self.entries = []
        for raw in entries:
            if len(raw) < 128:
                break
            name_length, kind = struct.unpack_from("<HB", raw, 64)
            start, size = struct.unpack_from("<IQ", raw, 116)
            if shift == 9:
                size &= 0xFFFFFFFF
            title = raw[:max(0, min(name_length, 64) - 2)].decode("utf-16-le", "replace")
            self.entries.append((title, kind, start, size))
        if not self.entries or self.entries[0][1] != 5:
            raise ExtractionError(name + ": root storage entry missing")
        root_start, root_size = self.entries[0][2], self.entries[0][3]
        self.mini_stream = self._chain(root_start)[:root_size] if root_size else b""
        self.mini_fat = []
        if mini_fat_count:
            mini = self._chain(first_mini_fat)
            self.mini_fat = list(struct.unpack_from("<%dI" % (len(mini) // 4), mini))

    def _sector(self, index):
        offset = (index + 1) * self.sector
        if index >= CFB_END_OF_CHAIN - 1 or offset + self.sector > len(self.data):
            raise ExtractionError(self.name + ": sector %d is outside the file" % index)
        return self.data[offset:offset + self.sector]

    def _chain(self, start, table=None, unit=None, source=None):
        table = self.fat if table is None else table
        output, seen, current = bytearray(), set(), start
        while current != CFB_END_OF_CHAIN:
            if current in seen or current >= len(table):
                raise ExtractionError(self.name + ": corrupt sector chain")
            seen.add(current)
            if source is None:
                output += self._sector(current)
            else:
                offset = current * unit
                if offset + unit > len(source):
                    raise ExtractionError(self.name + ": mini sector outside the mini stream")
                output += source[offset:offset + unit]
            current = table[current]
        return bytes(output)

    def stream(self, kind, start, size):
        if size < self.cutoff:
            raw = self._chain(start, self.mini_fat, self.mini_sector, self.mini_stream) if size else b""
        else:
            raw = self._chain(start)
        if len(raw) < size:
            raise ExtractionError(self.name + ": stream shorter than its directory entry")
        return raw[:size]

    def streams(self):
        result = {}
        for title, kind, start, size in self.entries:
            if kind == 2:
                result[decode_msi_name(title)] = self.stream(kind, start, size)
        return result


def decode_msi_name(title):
    output = []
    for character in title:
        code = ord(character)
        if 0x3800 <= code < 0x4800:
            code -= 0x3800
            output.append(MSI_ALPHABET[code & 0x3F] + MSI_ALPHABET[code >> 6])
        elif 0x4800 <= code < 0x4840:
            output.append(MSI_ALPHABET[code - 0x4800])
        elif code == 0x4840:
            output.append("!")
        else:
            output.append(character)
    return "".join(output)


class MsiDatabase:
    """Decode column-major MSI tables the same way ``extract-msi.py`` does."""

    def __init__(self, streams, name="<msi>"):
        self.streams, self.name = streams, name
        try:
            pool, data, columns = streams["!_StringPool"], streams["!_StringData"], streams["!_Columns"]
        except KeyError as error:
            raise ExtractionError(name + ": MSI system table missing: " + str(error)) from error
        codepage, flags = struct.unpack_from("<HH", pool)
        if flags != 0:
            raise ExtractionError(name + ": only 16-bit MSI string references are supported")
        encoding = {0: "ascii", 65001: "utf-8"}.get(codepage, "cp" + str(codepage))
        self.strings, offset = [""], 0
        for index in range(4, len(pool) - 3, 4):
            length, references = struct.unpack_from("<HH", pool, index)
            if not length and references:
                raise ExtractionError(name + ": long MSI strings are not supported")
            self.strings.append(data[offset:offset + length].decode(encoding))
            offset += length
        if offset != len(data):
            raise ExtractionError(name + ": string pool and data disagree")
        count = len(columns) // 8
        self.columns = {}
        for index in range(count):
            table, order, column_name, kind = [
                struct.unpack_from("<H", columns, column * count * 2 + index * 2)[0] for column in range(4)]
            self.columns.setdefault(self._string(table), []).append((order - 32768, self._string(column_name), kind - 32768))

    def _string(self, reference):
        if reference >= len(self.strings):
            raise ExtractionError(self.name + ": string reference out of range")
        return self.strings[reference]

    def table(self, table_name):
        if table_name not in self.columns:
            raise ExtractionError(self.name + ": table missing: " + table_name)
        schema = sorted(self.columns[table_name])
        widths = [2 if kind & 0x800 else kind & 0xFF for _, _, kind in schema]
        if any(width not in (2, 4) for width in widths):
            raise ExtractionError(self.name + ": unsupported column width in " + table_name)
        raw = self.streams.get("!" + table_name, b"")
        row_size = sum(widths)
        if len(raw) % row_size:
            raise ExtractionError(self.name + ": table " + table_name + " has a partial row")
        count = len(raw) // row_size
        rows, offset = [{} for _ in range(count)], 0
        for (_, column, kind), width in zip(schema, widths):
            for index in range(count):
                value = int.from_bytes(raw[offset + index * width:offset + (index + 1) * width], "little")
                if kind & 0x800:
                    rows[index][column] = self._string(value)
                else:
                    rows[index][column] = value - (1 << (width * 8 - 1)) if value else None
            offset += count * width
        return rows


def payload_digest(data, expected):
    """Burn manifests record SHA-1, SHA-256 or SHA-512 hex digests by version."""
    algorithm = {40: "sha1", 64: "sha256", 128: "sha512"}.get(len(expected))
    if algorithm is None:
        raise ExtractionError("unrecognised Burn payload hash length")
    return hashlib.new(algorithm, data).hexdigest() == expected.lower()


def long_name(msi_file_name):
    """MSI FileName columns may be ``short|long``; return the long form."""
    return msi_file_name.split("|")[-1]
