#!/usr/bin/env python3
"""Write the CloudKit Web Services build settings into the Linux app source.

Linux reaches the Mac's CloudKit container through the same CloudKit Web
Services API token as Windows (the ``CLOUDKIT_WEB_API_TOKEN`` CI secret) and
the same loopback sign-in callback, so one token serves both. This applies the
Windows script's checks and placeholders to
``Sources/SpeakLinux/CloudKitWebBuildConfiguration.swift`` in the build's
checkout only; the token is never committed or printed. Without a token the
file is left as committed and the app reports that iCloud sync is unavailable.
``CLOUDKIT_WEB_ENVIRONMENT`` may select ``development``.
"""
from pathlib import Path
import importlib.util
import os
import sys

ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / "Sources" / "SpeakLinux" / "CloudKitWebBuildConfiguration.swift"
WINDOWS_SCRIPT = ROOT / "scripts" / "windows-cloudkit" / "configure-cloudkit-web.py"


def windows_configurator():
    """The Windows script's validated rewrite, shared so both hosts agree."""
    spec = importlib.util.spec_from_file_location("configure_cloudkit_web", WINDOWS_SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.configured_source


def main() -> int:
    token = os.environ.get("CLOUDKIT_WEB_API_TOKEN", "").strip()
    environment = os.environ.get("CLOUDKIT_WEB_ENVIRONMENT", "production").strip() or "production"
    if not token:
        print("No CLOUDKIT_WEB_API_TOKEN: this Linux build reports that iCloud sync is unavailable.")
        return 0
    try:
        configured = windows_configurator()(TARGET.read_text(encoding="utf-8"), token, environment)
        TARGET.write_text(configured, encoding="utf-8")
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"Configured CloudKit Web Services for the {environment} environment (Linux).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
