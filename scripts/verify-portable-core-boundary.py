#!/usr/bin/env python3
"""Reject stale platform exclusions and allow-list drift in the shared core.

The portable target must discover sources by default. A new domain source then
builds on every platform automatically; only deliberate adapter exclusions need
manifest edits. Native CI proves whether the admitted sources really compile.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
manifest = (root / "Package.swift").read_text(encoding="utf-8")
match = re.search(r"let appleCoreSources: \[String\] = \[(.*?)\n\]", manifest, re.S)
if not match:
    sys.exit("Missing explicit appleCoreSources platform boundary")
excluded = re.findall(r'"([^"\n]+\.swift)"', match.group(1))
if len(excluded) != len(set(excluded)):
    sys.exit("Duplicate Apple source exclusion")
source_root = root / "Sources" / "SpeakCore"
for name in excluded:
    relative = Path(name)
    if relative.is_absolute() or ".." in relative.parts or not (source_root / relative).is_file():
        sys.exit(f"Invalid or stale Apple source exclusion: {name}")
portable = manifest.split("let portablePackage = Package(", 1)[1].split(
    "let package = portableCoreBuild", 1
)[0]
if "exclude: appleCoreSources" not in portable or re.search(r"\bsources\s*:", portable):
    sys.exit("The portable core must discover new sources by default, with explicit Apple exclusions")
sources = {path.relative_to(source_root).as_posix() for path in source_root.rglob("*.swift")}
included = sources - set(excluded)
required = {"ModelCatalog.swift", "ModelCatalogTypes.swift", "StreamingTranscriptionClient.swift",
            "TranscriptAccumulator.swift", "RecordingLifecycleCoordinator.swift", "OpenAIBatchClient.swift"}
if missing := required - included:
    sys.exit("Canonical domain sources excluded from portable builds: " + ", ".join(sorted(missing)))
print(f"Portable boundary: {len(included)} shared Swift sources, {len(excluded)} explicit platform exclusions")
