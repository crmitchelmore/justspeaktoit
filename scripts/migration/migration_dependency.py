"""Verify the immutable, licensed native migration ZIP reader source pin."""

import hashlib
import json
from pathlib import Path
import re


def license_entry(source_root):
    directory = Path(source_root) / "Sources" / "CMigrationArchive" / "miniz"
    pin = json.loads((directory / "dependency.json").read_text(encoding="utf-8"))
    expected = {
        "LICENSE", "miniz.c", "miniz.h", "miniz_common.h", "miniz_tdef.h",
        "miniz_tinfl.c", "miniz_tinfl.h", "miniz_zip.c", "miniz_zip.h",
    }
    if (pin["repository"] != "https://github.com/richgel999/miniz"
            or not re.fullmatch(r"[0-9a-f]{40}", pin["commit"])
            or pin["license"] != "MIT" or pin["hashLineEndings"] != "LF"
            or set(pin["files"]) != expected):
        raise ValueError("Invalid native migration dependency pin")
    texts = {}
    for name, expected_hash in pin["files"].items():
        text = (directory / name).read_bytes().replace(b"\r\n", b"\n")
        if hashlib.sha256(text).hexdigest() != expected_hash:
            raise ValueError("Native migration dependency differs from its pin: " + name)
        texts[name] = text
    text = texts["LICENSE"]
    return {
        "name": "LICENSE-miniz.txt", "license": "MIT",
        "url": pin["repository"] + "/blob/" + pin["commit"] + "/LICENSE",
        "covers": "miniz " + pin["version"] + ", statically compiled native migration ZIP reader",
        "data": text, "sha256": hashlib.sha256(text).hexdigest(), "bytes": len(text),
    }
