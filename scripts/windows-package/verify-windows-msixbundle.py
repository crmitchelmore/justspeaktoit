#!/usr/bin/env python3
"""Check an .msixbundle holds exactly the given .msix packages under one identity.

Run after MakeAppx bundle (``--unsigned``) and after signing (``--signed``).
The reader is independent of the Windows packaging API that produced the bundle.
"""
import argparse
import json
import pathlib
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import windows_msix  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", required=True, type=pathlib.Path)
    parser.add_argument("--package", required=True, action="append", type=pathlib.Path,
                        help="an input package; repeat for each architecture")
    state = parser.add_mutually_exclusive_group(required=True)
    state.add_argument("--signed", action="store_true")
    state.add_argument("--unsigned", action="store_true")
    parser.add_argument("--evidence", type=pathlib.Path)
    args = parser.parse_args()
    result = windows_msix.verify_msixbundle(args.bundle, args.package, args.signed)
    text = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.evidence:
        args.evidence.write_text(text, encoding="utf-8")
    print(text, end="")


if __name__ == "__main__":
    try:
        main()
    except windows_msix.PackageError as error:
        raise SystemExit("windows bundle verification: " + str(error))
