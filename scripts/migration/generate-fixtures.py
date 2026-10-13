"""Generate small, synthetic v1 migration ZIP interoperability/hostile-input fixtures."""

import copy
import hashlib
import io
import json
from pathlib import Path
import struct
import warnings
import zipfile


ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "Tests" / "SpeakTestSupport" / "MigrationArchiveFixtures"
AUDIO = b"synthetic audio fixture"
IDENTITY = "00000000-0000-0000-0000-000000000001"


def archive(record=None, *, compression=zipfile.ZIP_DEFLATED, zip64=False,
            include_settings=True, duplicate_path=False, duplicate_record=False, symlink=False, invalid_item=False):
    record = copy.deepcopy(record or {
        "id": IDENTITY, "kind": "audio", "value": {"id": IDENTITY},
        "date": "1970-01-01T00:01:40Z", "file": "recordings/test.wav",
        "digest": hashlib.sha256(AUDIO).hexdigest(), "revision": "fixture",
    })
    manifest = {
        "format": "JustSpeakToIt", "version": 1, "createdAt": "1970-01-01T00:00:00Z",
        "categories": ["settings", "recordings"], "scopes": {},
    }
    records = [record]
    if duplicate_record:
        other = copy.deepcopy(record)
        other["id"] = "00000000-0000-0000-0000-000000000002"
        records.append(other)
    if invalid_item:
        records.append({"id": "invalid", "kind": "audio"})
    entries = [
        ("manifest.json", json.dumps(manifest).encode()),
        ("recordings.json", json.dumps(records).encode()),
        (record["file"], AUDIO),
    ]
    if include_settings:
        entries.append(("settings.json", json.dumps([
            {"id": "appearance", "kind": "default", "value": "dark"}
        ]).encode()))
    if duplicate_path:
        entries.append(entries[0])
    output = io.BytesIO()
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", UserWarning)
        with zipfile.ZipFile(output, "w") as writer:
            for name, value in entries:
                info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                info.compress_type = compression
                info.create_system = 3
                info.external_attr = ((0o120777 if symlink and name == record["file"] else 0o100600) << 16)
                with writer.open(info, "w", force_zip64=zip64) as target:
                    target.write(value)
    return output.getvalue()


def corrupt_crc(data, name):
    with zipfile.ZipFile(io.BytesIO(data)) as reader:
        entry = reader.getinfo(name)
        crc = entry.CRC ^ 1
    output = bytearray(data)
    struct.pack_into("<I", output, entry.header_offset + 14, crc)
    offset = 0
    while True:
        offset = output.find(b"PK\x01\x02", offset)
        if offset == -1:
            raise RuntimeError("Central directory entry missing")
        length = struct.unpack_from("<H", output, offset + 28)[0]
        if output[offset + 46:offset + 46 + length] == name.encode():
            struct.pack_into("<I", output, offset + 16, crc)
            return bytes(output)
        offset += 4


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    valid = archive()
    fixtures = {
        "deflate": valid,
        "stored": archive(compression=zipfile.ZIP_STORED),
        "zip64": archive(zip64=True),
        "duplicate-path": archive(duplicate_path=True),
        "duplicate-recording": archive(duplicate_record=True),
        "invalid-item": archive(invalid_item=True),
        "missing-category": archive(include_settings=False),
        "symlink": archive(symlink=True),
        "bad-manifest-crc": corrupt_crc(valid, "manifest.json"),
        "bad-audio-crc": corrupt_crc(valid, "recordings/test.wav"),
    }
    with zipfile.ZipFile(io.BytesIO(valid)) as reader:
        record = json.loads(reader.read("recordings.json"))[0]
    wrong_digest = dict(record, digest="0" * 64)
    fixtures["bad-digest"] = archive(wrong_digest)
    fixtures["traversal"] = archive(dict(record, file="recordings/../outside.wav"))
    fixtures["long-unicode"] = archive(dict(record, file="recordings/" + "\u00f1" * 260 + ".wav"))
    for name, value in fixtures.items():
        (OUTPUT / (name + ".zip")).write_bytes(value)
    print("Generated %d synthetic migration ZIP fixtures." % len(fixtures))


if __name__ == "__main__":
    main()
