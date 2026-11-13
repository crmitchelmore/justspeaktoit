#!/usr/bin/env python3
"""Fail when a built iOS app bundle registers no App Shortcuts.

Xcode merges a static library's App Intents actions into the app but silently
drops its `autoShortcuts`, so a provider in the wrong target still builds and
ships with no Siri or Spotlight phrases (justspeaktoit-46y). This reads the
app's own `Metadata.appintents` and, given the provider source, requires every
declared `AppShortcut` to be present.

Usage: check-app-shortcuts.py <App.app | directory to search> [--source FILE]
"""
import argparse
import json
import re
import sys
from pathlib import Path

DEFAULT_SOURCE = Path(__file__).resolve().parents[2] / "SpeakiOSApp/TranscriptionShortcuts.swift"


def find_app(path):
    if path.suffix == ".app":
        return path
    # Top-level apps only: the watch app is embedded inside the iOS app.
    apps = sorted(app for app in path.rglob("*.app") if (app / "Metadata.appintents").is_dir()
                  and not any(parent.suffix == ".app" for parent in app.parents))
    if len(apps) != 1:
        raise SystemExit(f"Expected one iOS app with App Intents metadata under {path}, found {apps}")
    return apps[0]


def declared_shortcuts(source):
    return len(re.findall(r"\bAppShortcut\s*\(", source.read_text()))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=Path)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    args = parser.parse_args()
    app = find_app(args.path)
    metadata_path = app / "Metadata.appintents/extract.actionsdata"
    try:
        metadata = json.loads(metadata_path.read_text())
    except (OSError, ValueError) as error:
        raise SystemExit(f"Unreadable App Intents metadata: {metadata_path}: {error}") from error
    shortcuts = metadata.get("autoShortcuts") if isinstance(metadata, dict) else None
    if not isinstance(shortcuts, list) or not shortcuts:
        raise SystemExit(
            f"{app.name} registers no App Shortcuts ({metadata_path}). The AppShortcutsProvider must be "
            "compiled into the app target, not a static library.")
    expected = declared_shortcuts(args.source)
    if len(shortcuts) != expected:
        raise SystemExit(
            f"{app.name} registers {len(shortcuts)} App Shortcuts but {args.source.name} declares {expected}")
    print(f"{app.name}: {len(shortcuts)} App Shortcuts registered")


if __name__ == "__main__":
    sys.exit(main())
