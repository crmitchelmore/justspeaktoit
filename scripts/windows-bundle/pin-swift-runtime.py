#!/usr/bin/env python3
"""Regenerate the reviewed DLL lock from the SHA-256-pinned official installer.

Uses the private, pinned 7-Zip tool as a data extractor, never runs the installer.
Normal bundle builds need only the committed lock, not another installer copy.
"""
import argparse
import hashlib
import json
import mmap
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent


def digest(path, algorithm="sha256"):
    result = hashlib.new(algorithm)
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            result.update(chunk)
    return result.hexdigest()


def generate(installer, seven, temporary_parent):
    lock = json.loads((HERE.parent / "windows-cross/dependencies.json").read_text())
    pin = next(item for item in lock["downloads"] if item["name"].endswith("-windows10.exe"))
    if installer.stat().st_size != pin["bytes"] or digest(installer) != pin["sha256"]:
        raise ValueError("Swift installer differs from the committed SHA-256 pin")
    with tempfile.TemporaryDirectory(prefix="swift-runtime-pin-", dir=temporary_parent) as temporary:
        workspace = Path(temporary)
        with installer.open("rb") as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as source:
            # Same pinned Burn layout as windows-cross/build-foundation-proof.py.
            for name, offset, size in [("bootstrap", 1082368, 210134), ("payloads", 1302848, 890210230)]:
                if source[offset:offset + 4] != b"MSCF":
                    raise ValueError("Pinned cabinet layout changed")
                with (workspace / (name + ".cab")).open("xb") as output:
                    for start in range(offset, offset + size, 1024 * 1024):
                        output.write(source[start:min(start + 1024 * 1024, offset + size)])
        def extract(source, output, names=()):
            subprocess.run([str(seven), "x", str(source), "-o" + str(output), "-y", "-bsp0", "-bso0",
                            *names], check=True)
        extract(workspace / "bootstrap.cab", workspace / "bootstrap", ["0"])
        manifest = workspace / "bootstrap/0"
        payloads = [item for item in ET.parse(manifest).iter()
                    if item.tag.endswith("Payload") and item.get("FilePath") in {"rtl.msi", "rtl.cab"}]
        if {item.get("FilePath") for item in payloads} != {"rtl.msi", "rtl.cab"}:
            raise ValueError("Pinned installer lacks the runtime package")
        extract(workspace / "payloads.cab", workspace / "payloads", [item.get("SourcePath") for item in payloads])
        (workspace / "packages").mkdir()
        receipts = {}
        for item in payloads:
            path = workspace / "payloads" / item.get("SourcePath")
            expected = {"bytes": int(item.get("FileSize")), "sha512": item.get("Hash").lower()}
            if path.stat().st_size != expected["bytes"] or digest(path, "sha512") != expected["sha512"]:
                raise ValueError("Embedded runtime payload failed authentication")
            path.rename(workspace / "packages" / item.get("FilePath"))
            receipts[item.get("FilePath")] = expected
        # Reconstruct MSI names with the already qualified shared decoder.
        import sys
        subprocess.run([sys.executable, "-B", str(HERE.parent / "windows-cross/extract-msi.py"), "rtl",
                        "--workspace", str(workspace), "--seven", str(seven), "--output", str(workspace / "runtime")],
                       check=True)
        files = []
        for row in json.loads((workspace / "rtl-layout.json").read_text()):
            if row["path"].lower().endswith(".dll"):
                files.append(dict(row, sha256=digest(workspace / "runtime" / row["path"])))
        return {"schemaVersion": 1, "swiftVersion": lock["swiftVersion"], "installer": pin,
                "bootstrapManifestSHA256": digest(manifest), "payloads": receipts,
                "files": sorted(files, key=lambda item: item["path"])}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--installer", required=True, type=Path)
    parser.add_argument("--seven", required=True, type=Path)
    parser.add_argument("--temporary-parent", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    document = generate(args.installer, args.seven, args.temporary_parent)
    args.output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
    print("Authenticated and pinned", len(document["files"]), "runtime DLLs")
