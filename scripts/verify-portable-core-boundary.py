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


def apple_folders(list_name, source_root):
    """The Swift files under one manifest list of Apple-only folders.

    Entries name whole folders, never single files, so adding an adapter or a
    portable file next to one never edits the manifest.
    """
    match = re.search(rf"let {list_name}: \[String\] = \[(.*?)\n\]", manifest, re.S)
    if not match:
        sys.exit(f"Missing explicit {list_name} platform boundary")
    entries = re.findall(r'"([^"\n]+)"', match.group(1))
    if len(entries) != len(set(entries)):
        sys.exit(f"Duplicate entry in {list_name}")
    for name in entries:
        relative = Path(name)
        target = source_root / relative
        if relative.is_absolute() or ".." in relative.parts or not target.is_dir() or not any(target.rglob("*.swift")):
            if name.endswith(".swift") and target.is_file():
                sys.exit(f"Apple source exclusion {name} must name an Apple-only folder, not a file")
            sys.exit(f"Invalid or stale Apple source exclusion: {name}")
    for name in entries:
        if folder := next((f for f in entries if f != name and Path(name).is_relative_to(f)), None):
            sys.exit(f"Apple source exclusion {name} is already covered by the {folder} folder")
    excluded = {path.relative_to(source_root).as_posix() for name in entries for path in (source_root / name).rglob("*.swift")}
    return entries, excluded


source_root = root / "Sources" / "SpeakCore"
excluded_folders, excluded = apple_folders("appleCoreSources", source_root)
portable = manifest.split("let portablePackage = Package(", 1)[1].split(
    "let package = portableCoreBuild", 1
)[0]
if "exclude: appleCoreSources" not in portable or re.search(r"\bsources\s*:", portable):
    sys.exit("The portable core must discover new sources by default, with explicit Apple exclusions")
sources = {path.relative_to(source_root).as_posix() for path in source_root.rglob("*.swift")}
included = sources - set(excluded)
required = {"ModelCatalog.swift", "ModelCatalogTypes.swift", "Live/StreamingTranscriptionClient.swift",
            "Live/TranscriptAccumulator.swift", "Recording/RecordingLifecycleCoordinator.swift",
            "Batch/Providers/OpenAIBatchClient.swift",
            "PaidAccess/PaidAccessModels.swift", "PaidAccess/PaidAccessRouting.swift",
            "PaidAccess/PaidAccessClient.swift", "PaidAccess/PaidAccessSessionLifecycle.swift"}
if missing := required - included:
    sys.exit("Canonical domain sources excluded from portable builds: " + ", ".join(sorted(missing)))

# SwiftUI views are Apple presentation, not shared domain code: they live in the
# Apple-only AppleUI/ folder so Core's portable surface stays free of UI.
view_declaration = re.compile(r"^\s*(?:public\s+|internal\s+|private\s+|fileprivate\s+)?struct\s+\w+\s*:\s*View\b", re.M)
for path in sorted(source_root.rglob("*.swift")):
    relative = path.relative_to(source_root).as_posix()
    if not relative.startswith("AppleUI/") and view_declaration.search(path.read_text(encoding="utf-8")):
        sys.exit(f"SwiftUI view outside Sources/SpeakCore/AppleUI: {relative}")

# Paid domain/session contracts stay shared; only the existing Apple I/O
# adapters are excluded. Keychain storage inside the shared client file is
# guarded by SPEAK_PORTABLE_CORE, also for portable builds on a macOS host.
paid_apple_adapters = {"PaidAccessHTTPClient.swift", "PaidAudioPayload.swift", "PaidStoreKitSync.swift"}
if admitted := {path for path in included if Path(path).name in paid_apple_adapters}:
    sys.exit("Apple paid adapters admitted to portable builds: " + ", ".join(sorted(admitted)))

# SpeakSync follows the same rule: portable by default, with only the native
# CloudKit adapters excluded by folder.
if "exclude: appleSyncSources" not in portable:
    sys.exit("Missing explicit appleSyncSources platform boundary")
sync_root = root / "Sources" / "SpeakSync"
_, sync_excluded = apple_folders("appleSyncSources", sync_root)
sync_sources = {path.relative_to(sync_root).as_posix() for path in sync_root.rglob("*.swift")}
sync_required = {"SyncSchema.swift", "SyncRecordCodecs.swift", "HistorySyncCoordinator.swift",
                 "CloudKitWebSyncTransports.swift", "CloudKitWebKeySync.swift"}
if missing := sync_required - (sync_sources - sync_excluded):
    sys.exit("Shared sync sources excluded from portable builds: " + ", ".join(sorted(missing)))

# The shared desktop layers stay free of any one host's native modules, so the
# Windows and Linux hosts compile the same orchestration.
native_modules = {"CWindowsSupport", "CWindowsSelfTest", "SpeakWindowsPlatform", "CLinuxSupport", "CLinuxSelfTest",
                  "SpeakLinuxPlatform", "AppKit", "UIKit", "WinSDK"}
for shared in ("SpeakDesktop", "SpeakDesktopHost"):
    for path in sorted((root / "Sources" / shared).rglob("*.swift")):
        imports = set(re.findall(r"^\s*import\s+(\w+)", path.read_text(encoding="utf-8"), re.M))
        if leaked := imports & native_modules:
            sys.exit(f"{path.relative_to(root)} imports host-native modules: {', '.join(sorted(leaked))}")
print(f"Portable boundary: {len(included)} shared Swift sources, {len(excluded)} Apple-only "
      f"in {len(excluded_folders)} folders; "
      f"sync: {len(sync_sources) - len(sync_excluded)} shared, {len(sync_excluded)} Apple-only")
