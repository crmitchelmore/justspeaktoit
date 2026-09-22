#!/usr/bin/env python3
"""Check an .msix holds exactly its verified layout under a valid SHA-256 block map.

Run after MakeAppx (``--unsigned``) and after signing (``--signed`` with
``--unsigned-reference``): signing may add only AppxSignature.p7x. This reader
is independent of the Windows packaging API that produced the package.
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
    parser.add_argument("--package", required=True, type=pathlib.Path)
    parser.add_argument("--layout", required=True, type=pathlib.Path)
    state = parser.add_mutually_exclusive_group(required=True)
    state.add_argument("--signed", action="store_true")
    state.add_argument("--unsigned", action="store_true")
    parser.add_argument("--unsigned-reference", type=pathlib.Path,
                        help="the unsigned package this signed copy must equal apart from its signature")
    parser.add_argument("--evidence", type=pathlib.Path)
    args = parser.parse_args()
    if args.unsigned_reference is not None and not args.signed:
        parser.error("--unsigned-reference applies to a signed package")
    result = windows_msix.verify_package(args.package, args.layout, args.signed, args.unsigned_reference)
    text = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.evidence:
        args.evidence.write_text(text, encoding="utf-8")
    print(text, end="")


if __name__ == "__main__":
    try:
        main()
    except windows_msix.PackageError as error:
        raise SystemExit("windows package verification: " + str(error))
