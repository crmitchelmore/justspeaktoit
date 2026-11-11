#!/usr/bin/env python3
"""Transfer Xcode test products without losing permissions or source provenance."""

import argparse
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile


PRODUCT = "SpeakiOS.xctestproducts"
METADATA = "provenance.json"


def provenance():
    revision = os.environ["GITHUB_SHA"]
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("A full checkout revision is required for iOS test products.")
    return {
        "revision": revision,
        "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
        "sdk": subprocess.check_output(
            ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"], text=True
        ).strip(),
    }


def pack(products, archive, expected):
    if not Path(products).exists():
        raise FileNotFoundError("Xcode did not export the required test products.")
    data = json.dumps(expected).encode()
    with tarfile.open(archive, "w:gz") as output:
        output.add(products, arcname=PRODUCT)
        metadata = tarfile.TarInfo(METADATA)
        metadata.size = len(data)
        output.addfile(metadata, io.BytesIO(data))


def unpack(archive, destination, expected):
    with tarfile.open(archive, "r:gz") as source:
        metadata = source.extractfile(METADATA)
        if metadata is None or json.load(metadata) != expected:
            raise ValueError("iOS test products do not match the checkout revision or Xcode/SDK.")
        source.extractall(destination, filter="data")
    if not (Path(destination) / PRODUCT).exists():
        raise FileNotFoundError("The archive did not contain the required iOS test products.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["pack", "unpack"])
    parser.add_argument("source")
    parser.add_argument("destination")
    args = parser.parse_args()
    operation = pack if args.operation == "pack" else unpack
    operation(args.source, args.destination, provenance())
