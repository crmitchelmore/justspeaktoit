#!/usr/bin/env python3
"""Write the CloudKit Web Services build settings into the Windows app source.

The Windows app reaches the Mac's CloudKit container through CloudKit Web
Services, which needs the container's API token from CloudKit Console. The
token is a build setting: CI passes the ``CLOUDKIT_WEB_API_TOKEN`` secret in the
environment and this script writes it into
``Sources/SpeakWindows/CloudKitWebBuildConfiguration.swift`` in the build's
checkout only. It is never committed. Without a token the file is left as
committed and the app reports that iCloud sync is unavailable.

``CLOUDKIT_WEB_ENVIRONMENT`` may select ``development``; the default is
``production``, the environment shipped Apple builds use.

The token is never printed.
"""
from pathlib import Path
import os
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / "Sources" / "SpeakWindows" / "CloudKitWebBuildConfiguration.swift"
TOKEN_PATTERN = re.compile(r"^[A-Za-z0-9_-]{16,256}$")
ENVIRONMENTS = {"production", "development"}


def configured_source(source: str, token: str, environment: str) -> str:
    """Returns the Swift source with the token and environment filled in."""
    if not TOKEN_PATTERN.match(token):
        raise ValueError("CLOUDKIT_WEB_API_TOKEN is not a CloudKit API token (letters, digits, - and _ only).")
    if environment not in ENVIRONMENTS:
        raise ValueError("CLOUDKIT_WEB_ENVIRONMENT must be production or development.")
    token_line = "    static let apiToken: String? = nil\n"
    environment_line = '    static let environment = "production"\n'
    if source.count(token_line) != 1 or source.count(environment_line) != 1:
        raise ValueError(f"{TARGET.relative_to(ROOT)} no longer has the expected placeholders.")
    source = source.replace(token_line, f'    static let apiToken: String? = "{token}"\n')
    return source.replace(environment_line, f'    static let environment = "{environment}"\n')


def main() -> int:
    token = os.environ.get("CLOUDKIT_WEB_API_TOKEN", "").strip()
    environment = os.environ.get("CLOUDKIT_WEB_ENVIRONMENT", "production").strip() or "production"
    if not token:
        print("No CLOUDKIT_WEB_API_TOKEN: this build reports that iCloud sync is unavailable.")
        return 0
    try:
        TARGET.write_text(configured_source(TARGET.read_text(encoding="utf-8"), token, environment), encoding="utf-8")
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"Configured CloudKit Web Services for the {environment} environment.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
