"""Authenticate offline native LLM payloads without loading or executing them."""
import hashlib
import json
import pathlib
import re
import stat
import struct
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
COMMIT = "a7a98e0fffed794396b3fbad4dcdbbc184963645"
DIRECTORY = "LocalLLMRuntime"
MAX_LIBRARY = 536_870_912
LINUX_SYSTEM_LIBRARIES = frozenset({
    "libc.so.6", "libm.so.6", "libstdc++.so.6", "libgcc_s.so.1", "libpthread.so.0",
    "libdl.so.2", "librt.so.1", "ld-linux-x86-64.so.2", "ld-linux-aarch64.so.1",
})


def digest(data):
    return hashlib.sha256(data).hexdigest()


def _object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("native runtime manifest repeats a key: " + key)
        result[key] = value
    return result


def _linux_dependencies(data, architecture):
    if len(data) < 64 or data[:7] != b"\x7fELF\x02\x01\x01" or data[7] not in (0, 3):
        raise ValueError("native runtime must be a little-endian ELF64 shared object")
    kind, machine = struct.unpack_from("<HH", data, 16)
    if (kind != 3 or machine != {"x86_64": 62, "arm64": 183}[architecture]
            or struct.unpack_from("<I", data, 20)[0] != 1 or struct.unpack_from("<H", data, 52)[0] != 64):
        raise ValueError("native runtime ELF architecture or image kind differs")
    offset = struct.unpack_from("<Q", data, 32)[0]
    width, count = struct.unpack_from("<HH", data, 54)
    if width != 56 or not 1 <= count <= 256 or offset < 64 or offset + width * count > len(data):
        raise ValueError("native runtime has an invalid ELF program-header table")
    loads, dynamic = [], []
    for index in range(count):
        kind, _, start, address, _, size, _, _ = struct.unpack_from("<IIQQQQQQ", data, offset + index * width)
        if kind == 3:
            raise ValueError("native runtime shared object must not specify an ELF interpreter")
        if kind not in (1, 2):
            continue
        if start + size > len(data):
            raise ValueError("native runtime ELF segment exceeds the file")
        if kind == 1:
            loads.append((address, start, size))
        else:
            dynamic.append((start, size))
    if len(dynamic) != 1 or not 16 <= dynamic[0][1] <= 1_048_576 or dynamic[0][1] % 16:
        raise ValueError("native runtime requires one bounded ELF dynamic table")
    tags, ended = {}, False
    start, size = dynamic[0]
    for position in range(start, start + size, 16):
        tag, value = struct.unpack_from("<qQ", data, position)
        if tag == 0:
            ended = True
            break
        tags.setdefault(tag, []).append(value)
    if not ended or len(tags.get(5, [])) != 1 or len(tags.get(10, [])) != 1:
        raise ValueError("native runtime ELF string table is absent or ambiguous")
    if any(tag in tags for tag in (0x7FFFFFFF, 0x7FFFFFFD, 0x6FFFFEFC, 0x6FFFFEFB)):
        raise ValueError("native runtime ELF filters and audit libraries are not permitted")
    address, size = tags[5][0], tags[10][0]
    if not 1 <= size <= 16_777_216:
        raise ValueError("native runtime ELF string table exceeds its bound")
    locations = [start + address - base for base, start, length in loads
                 if base <= address and address + size <= base + length]
    if len(locations) != 1:
        raise ValueError("native runtime ELF string table is not uniquely file-backed")
    strings = data[locations[0]:locations[0] + size]

    def text(index):
        end = strings.find(b"\0", index)
        if not 0 <= index < len(strings) or end < index or end - index > 256:
            raise ValueError("native runtime ELF dependency string is invalid")
        try:
            return strings[index:end].decode("ascii")
        except UnicodeDecodeError as error:
            raise ValueError("native runtime ELF dependency string is not ASCII") from error

    needed = [text(index) for index in tags.get(1, [])]
    foreign_loader = "ld-linux-aarch64.so.1" if architecture == "x86_64" else "ld-linux-x86-64.so.2"
    allowed = LINUX_SYSTEM_LIBRARIES - {foreign_loader}
    if len(set(needed)) != len(needed) or any(name not in allowed for name in needed):
        raise ValueError("native runtime ELF needs an unapproved/non-system dependency: " + repr(needed))
    for tag in (15, 29):
        if len(tags.get(tag, [])) > 1 or any(text(index) != "$ORIGIN" for index in tags.get(tag, [])):
            raise ValueError("native runtime ELF search path must be absent or exactly $ORIGIN")
    if len(tags.get(14, [])) > 1 or any(text(index) != "libllama.so" for index in tags.get(14, [])):
        raise ValueError("native runtime ELF SONAME differs from libllama.so")
    return {"needed": needed, "searchPaths": [text(index) for tag in (15, 29) for index in tags.get(tag, [])]}


def _windows_dependencies(data, architecture):
    sys.path.insert(0, str(HERE.parent / "windows-bundle"))
    import windows_pe
    image = windows_pe.PEImage(data, "llama.dll")
    if image.architecture != {"x86_64": "x64", "arm64": "arm64"}[architecture] or not image.is_dll:
        raise ValueError("native runtime must be a non-hybrid DLL of the exact Windows architecture")
    policy = json.loads((HERE.parent / "windows-bundle" / "runtime-policy.json").read_text(encoding="utf-8"))
    system = {name.lower() for name in policy["windowsSystemModules"]} - {"vulkan-1.dll"}
    api_sets = [re.compile(pattern) for pattern in policy["windowsApiSetPatterns"]]
    static, delayed = image.imports(), image.delay_imports()
    if len(static) + len(delayed) > 512:
        raise ValueError("native runtime PE import count exceeds its bound")
    for name in static + delayed:
        if name.lower() not in system and not any(pattern.fullmatch(name.lower()) for pattern in api_sets):
            raise ValueError("native llama DLL requires a non-system dependency; rebuild with the static MSVC "
                             "runtime and disabled dynamic backends: " + name)
    return {"static": static, "delay": delayed}


def validate_entries(entries, system, architecture):
    if system not in ("windows", "linux") or architecture not in ("x86_64", "arm64"):
        raise ValueError("unsupported native runtime package target")
    library = "llama.dll" if system == "windows" else "libllama.so"
    if set(entries) != {library, "provisioning.json", "LICENSE.llama-cpp"}:
        raise ValueError("native runtime folder must contain exactly its library, manifest and license")
    manifest_bytes, data, license_bytes = entries["provisioning.json"], entries[library], entries["LICENSE.llama-cpp"]
    if not 1 <= len(manifest_bytes) <= 16_384 or not 1 <= len(data) <= MAX_LIBRARY:
        raise ValueError("native runtime manifest or library exceeds its size bound")
    manifest = json.loads(manifest_bytes.decode("utf-8"), object_pairs_hook=_object)
    expected = {"schemaVersion": 1, "commit": COMMIT, "platform": system, "architecture": architecture,
                "library": library, "sha256": digest(data)}
    if manifest != expected or type(manifest.get("schemaVersion")) is not int:
        raise ValueError("native runtime manifest pin/target/library/hash differs")
    license_path = ROOT / "Sources" / "CLlamaCpp" / "upstream" / "LICENSE"
    if not 1 <= len(license_bytes) <= 65_536 or license_bytes != license_path.read_bytes():
        raise ValueError("native runtime license differs from the pinned MIT license")
    dependencies = (_windows_dependencies(data, architecture) if system == "windows"
                    else _linux_dependencies(data, architecture))
    return {"entries": dict(entries), "manifest": manifest, "manifestSHA256": digest(manifest_bytes),
            "dependencies": dependencies}


def _regular(path, directory=False):
    metadata = path.lstat()
    if (metadata.st_file_attributes if hasattr(metadata, "st_file_attributes") else 0) & 0x400:
        raise ValueError("native runtime package must not contain reparse points")
    if not (stat.S_ISDIR(metadata.st_mode) if directory else stat.S_ISREG(metadata.st_mode)):
        raise ValueError("native runtime package must contain only regular files in a regular directory")
    return metadata


def read_directory(directory, system, architecture):
    directory = pathlib.Path(directory)
    _regular(directory, directory=True)
    entries = {}
    library = "llama.dll" if system == "windows" else "libllama.so"
    allowed = {library, "provisioning.json", "LICENSE.llama-cpp"}
    for path in directory.iterdir():
        if path.name not in allowed or len(entries) >= 3:
            raise ValueError("native runtime folder contains an unexpected entry")
        metadata = _regular(path)
        limit = MAX_LIBRARY if path.name in ("llama.dll", "libllama.so") else (
            16_384 if path.name == "provisioning.json" else 65_536)
        if not 1 <= metadata.st_size <= limit:
            raise ValueError("native runtime package entry exceeds its size bound")
        with path.open("rb") as stream:
            entries[path.name] = stream.read(limit + 1)
        if len(entries[path.name]) > limit:
            raise ValueError("native runtime package entry grew beyond its size bound")
    return validate_entries(entries, system, architecture)
