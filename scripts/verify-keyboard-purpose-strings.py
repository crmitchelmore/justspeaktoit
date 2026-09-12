#!/usr/bin/env python3
"""Validate the archived keyboard plist in both capture configurations."""
import plistlib
import sys
from pathlib import Path


def validate(path):
    with Path(path).open("rb") as file:
        info = plistlib.load(file)
    for key in ("NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"):
        value = info.get(key)
        if not isinstance(value, str) or not value.strip():
            raise ValueError(f"Keyboard is missing a non-empty {key}")


if __name__ == "__main__":
    try:
        validate(sys.argv[1])
    except (OSError, ValueError, IndexError) as error:
        sys.exit(f"::error::{error}")
