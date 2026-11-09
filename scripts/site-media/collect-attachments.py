#!/usr/bin/env python3
"""Copy named XCTest attachments (screenshots, marks/layout JSON) out of an exported result bundle."""
import json
import shutil
import sys
from pathlib import Path

source, destination = Path(sys.argv[1]), Path(sys.argv[2])
for test in json.loads((source / "manifest.json").read_text()):
    for item in test.get("attachments", []):
        name = item.get("suggestedHumanReadableName", "")
        # XCTest may append "_<index>_<uuid>" and an extension to attachment names.
        stem = name.split("_")[0].removesuffix(".json").removesuffix(".png")
        if stem.startswith(("mac-", "ios-")) or stem in ("marks", "layout"):
            target = f"{stem}.json" if stem in ("marks", "layout") else f"{stem}.png"
            shutil.copyfile(source / item["exportedFileName"], destination / target)
            print(f"{item['exportedFileName']} -> {target}")
