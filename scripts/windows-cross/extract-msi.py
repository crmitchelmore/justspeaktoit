#!/usr/bin/env python3
"""Extract an MSI's external cabinets without running its installer.

Only used for the verified, pinned official Swift 6.2.3 distribution. Decode
column-major MSI tables and reconstruct their original Directory/File paths.
This is not a general installer: custom actions and registry data are ignored.
"""
import argparse
import json
import pathlib
import shutil
import struct
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("name", choices=("windows", "rtl"))
parser.add_argument("--workspace", required=True, type=pathlib.Path)
parser.add_argument("--seven", required=True, type=pathlib.Path)
parser.add_argument("--output", required=True, type=pathlib.Path)
args = parser.parse_args()
BASE = args.workspace.resolve()
SEVEN = args.seven.resolve()
NAME = args.name
TABLES = BASE / (NAME + "-tables")
OUT = args.output.resolve()
TABLES.mkdir(exist_ok=True)
OUT.mkdir(exist_ok=True)
subprocess.run([str(SEVEN), "x", str(BASE / "packages" / (NAME + ".msi")),
                "-o" + str(TABLES), "-y", "-bsp0", "-bso0"], check=True)
pool = (TABLES / "!_StringPool").read_bytes()
data = (TABLES / "!_StringData").read_bytes()
codepage, flags = struct.unpack_from("<HH", pool)
assert flags == 0, "This extraction supports 16-bit string references only"
strings = [""]
offset = 0
for index in range(4, len(pool), 4):
    length, references = struct.unpack_from("<HH", pool, index)
    assert length or not references, "Long strings need explicit handling"
    strings.append(data[offset:offset + length].decode("cp" + str(codepage)))
    offset += length
assert offset == len(data)
raw = (TABLES / "!_Columns").read_bytes()
count = len(raw) // 8
columns = {}
for index in range(count):
    table, order, name, kind = [struct.unpack_from("<H", raw, column * count * 2 + index * 2)[0]
                                 for column in range(4)]
    columns.setdefault(strings[table], []).append((order - 32768, strings[name], kind - 32768))


def read_table(name):
    schema = sorted(columns[name])
    widths = [2 if kind & 0x800 else kind & 0xff for _, _, kind in schema]
    assert all(width in (2, 4) for width in widths)
    raw = (TABLES / ("!" + name)).read_bytes()
    assert len(raw) % sum(widths) == 0
    count = len(raw) // sum(widths)
    result = [{} for _ in range(count)]
    offset = 0
    for (_, column, kind), width in zip(schema, widths):
        for index in range(count):
            value = int.from_bytes(raw[offset + index * width:offset + (index + 1) * width], "little")
            result[index][column] = (strings[value] if kind & 0x800 else
                                    value - (1 << (width * 8 - 1)) if value else None)
        offset += count * width
    (TABLES / (name + ".json")).write_text(json.dumps(result, indent=2) + "\n")
    return result


directories = {row["Directory"]: row for row in read_table("Directory")}
components = {row["Component"]: row for row in read_table("Component")}
media = sorted(read_table("Media"), key=lambda row: row["LastSequence"])


def directory_path(identifier, seen=None):
    seen = set() if seen is None else seen
    assert identifier not in seen, "Cyclic Directory table"
    seen.add(identifier)
    row = directories[identifier]
    if not row["Directory_Parent"]:
        return pathlib.Path()
    parent = directory_path(row["Directory_Parent"], seen)
    name = row["DefaultDir"].split(":")[0].split("|")[-1]
    assert name not in ("..", "") and "/" not in name and "\\" not in name
    return parent if name == "." else parent / name


for row in media:
    cabinet = row["Cabinet"]
    assert cabinet and "/" not in cabinet and "\\" not in cabinet and not cabinet.startswith("#")
    target = BASE / (cabinet + "-expanded")
    target.mkdir(exist_ok=True)
    subprocess.run([str(SEVEN), "x", str(BASE / "packages" / cabinet),
                    "-o" + str(target), "-y", "-bsp0", "-bso0"], check=True)
manifest = []
for row in read_table("File"):
    cabinet = next(item["Cabinet"] for item in media if row["Sequence"] <= item["LastSequence"])
    source = BASE / (cabinet + "-expanded") / row["File"]
    assert source.stat().st_size == row["FileSize"], str(source)
    name = row["FileName"].split("|")[-1]
    assert name not in (".", "..", "") and "/" not in name and "\\" not in name
    relative = directory_path(components[row["Component_"]]["Directory_"]) / name
    destination = OUT / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        assert destination.read_bytes() == source.read_bytes(), "Conflicting MSI destination"
    else:
        shutil.copy2(source, destination)
    manifest.append({"path": str(relative), "cabinet": cabinet, "id": row["File"], "bytes": row["FileSize"]})
(BASE / (NAME + "-layout.json")).write_text(json.dumps(manifest, indent=2) + "\n")
print("Reconstructed", len(manifest), NAME, "files in", OUT)
