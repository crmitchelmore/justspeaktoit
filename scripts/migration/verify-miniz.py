#!/usr/bin/env python3
"""Validate vendored miniz source/licence hashes without fetching or executing dependencies."""

from pathlib import Path
from migration_dependency import license_entry


if __name__ == "__main__":
    entry = license_entry(Path(__file__).resolve().parents[2])
    print("Verified " + entry["covers"] + " and its MIT licence.")
