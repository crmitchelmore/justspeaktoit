#!/usr/bin/env python3
"""Stamp the public PostHog project key into a Windows or Linux release build.

The desktop apps send opt-in product analytics to PostHog only when the build
carries the project key, a public ``phc_`` client key, as the Mac and Android
releases do. The release workflows (Windows x64 and ARM64, Linux Flatpak) run
this before compiling, only on ``main`` and release manifest tags, with the
``POSTHOG_PROJECT_KEY`` secret in the environment. It writes the key into
``DesktopAnalyticsBuildConfiguration.swift`` in that build's checkout only; it
is never committed. Development, pull-request and local builds keep ``nil``
and send nothing, and the app ignores a stamped key in a debug build.

A missing key leaves the file as committed. A value that is not a PostHog
project key is reported and also leaves the file unchanged: analytics stays
off for that build rather than blocking the release. The key is never printed.
"""
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / "Sources" / "SpeakDesktop" / "Telemetry" / "DesktopAnalyticsBuildConfiguration.swift"
# Must match DesktopTelemetryConfiguration.validPostHogProjectKey.
KEY_PATTERN = re.compile(r"phc_[A-Za-z0-9_-]{8,128}")
PLACEHOLDER = "    public static let postHogProjectKey: String? = nil\n"


def configured_source(source: str, key: str) -> str:
    """Returns the Swift source with the key filled in."""
    if not KEY_PATTERN.fullmatch(key):
        raise ValueError("POSTHOG_PROJECT_KEY is not a PostHog project key (phc_ then letters, digits, - or _).")
    if source.count(PLACEHOLDER) != 1:
        raise LookupError(f"{TARGET.relative_to(ROOT)} no longer has the expected placeholder.")
    return source.replace(PLACEHOLDER, f'    public static let postHogProjectKey: String? = "{key}"\n')


def main(target: Path = TARGET) -> int:
    key = os.environ.get("POSTHOG_PROJECT_KEY", "").strip()
    if not key:
        print("No POSTHOG_PROJECT_KEY: this build sends no product analytics.")
        return 0
    try:
        source = configured_source(target.read_text(encoding="utf-8"), key)
    except ValueError as error:
        print(f"::warning::{error} This build sends no product analytics.")
        return 0
    except LookupError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    target.write_text(source, encoding="utf-8")
    print("Stamped the PostHog project key for opt-in product analytics.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
